#!/bin/bash

source functions.sh && init
set +o errexit +o pipefail +o xtrace

# defaults
# shellcheck disable=SC2207
disks=($(lsblk -dno name -e1,7,11 | sed 's|^|/dev/|' | sort | head -n 2))
userdata='/dev/null'

USAGE="Usage: $0 -M /metadata
Required Arguments:
	-M metadata  File containing instance metadata

Options:
	-b url       Address to provisioning artifacts (advanced usage, default http://install.\$facility.packet.net/misc)
	-u userdata  File containing instance userdata
	-h           This help message
	-v           Turn on verbose messages for debugging

Description: This script installs the specified OS from an image file on to one or more block devices and handles the kernel and initrd for the
underlying hardware.
"

while getopts "M:b:u:hv" OPTION; do
	case $OPTION in
	M) metadata=$OPTARG ;;
	b) BASEURL=$OPTARG ;;
	u) userdata=$OPTARG ;;
	h) echo "$USAGE" && exit 0 ;;
	v) set -x ;;
	*) echo "$USAGE" && exit 1 ;;
	esac
done

check_required_arg "$metadata" 'metadata file' '-M'
assert_all_args_consumed "$OPTIND" "$@"

declare class && set_from_metadata class 'class' <"$metadata"
declare facility && set_from_metadata facility 'facility' <"$metadata"
declare os && set_from_metadata os 'operating_system.slug' <"$metadata"
declare pwhash && set_from_metadata pwhash 'password_hash' <"$metadata"
declare state && set_from_metadata state 'state' <"$metadata"
declare tag && set_from_metadata tag 'operating_system.image_tag' <"$metadata" || tag=""
declare tinkerbell && set_from_metadata tinkerbell 'phone_home_url' <"$metadata"
# shellcheck disable=SC2001
tinkerbell=$(echo "$tinkerbell" | sed 's|\(http://[^/]\+\).*|\1|')

if [[ $state == 'osie.internal.check-env' ]]; then
	exit 0
fi

OS=$os${tag:+:$tag}

# if $BASEURL is not empty then the user specifically passed in the artifacts
# location, we should not trample it
BASEURL=${BASEURL:-http://install.$facility.packet.net/misc}

# if $mirror is not empty then the user specifically passed in the mirror
# location, we should not trample it
mirror=${mirror:-http://mirror.$facility.packet.net}

if [[ ${OS} =~ : ]]; then
	echo "OS has image tag. Resetting OS $OS"
	OS=$(echo "$OS" | awk -F':' '{print $1}')
	echo "OS is now $OS"
fi

## Assemble configurables
##
# Target mount point
target="/mnt/target"
# Image rootfs
image="$BASEURL/osie/images/$OS/image-rootfs.tar.gz"

# Color codes
GREEN='\033[0;32m'
BYELLOW='\033[0;33;5;7m'
NC='\033[0m' # No Color

echo -e "${GREEN}#### Checking userdata for custom image_url...${NC}"
image_url=$(sed -nr 's|.*\bimage_url=(\S+).*|\1|p' "$userdata")
if [[ -z ${image_url} ]]; then
	echo "Using default image since no image_url provided"
	early_phone=0
else
	echo "NOTICE: Custom image url found!"
	echo "Overriding default image location with custom image_url"
	image="$image_url"
	if [[ $image_url =~ .*install.*.packet.net.* ]]; then
		early_phone=0
	else
		early_phone=1
	fi
fi

cprconfig=/tmp/config.cpr
cprout=/tmp/cpr.json
echo -e "${GREEN}#### Checking userdata for custom cpr_url...${NC}"
cpr_url=$(sed -nr 's|.*\bcpr_url=(\S+).*|\1|p' "$userdata")
if [[ -z ${cpr_url} ]]; then
	echo "Using default image since no cpr_url provided"
	jq -c '.storage' "$metadata" >$cprconfig
else
	echo "NOTICE: Custom CPR url found!"
	echo "Overriding default CPR location with custom cpr_url"
	if ! curl "$cpr_url" | jq . >$cprconfig; then
		phone_home "${tinkerbell}" '{"instance_id":"'"$(jq -r .id "$metadata")"'"}'
		echo "$0: CPR URL unavailable: $cpr_url" >&2
		exit 1
	fi
fi

echo "Image: $image"
echo "Devices:${disks[*]}"
echo "CPR: $(jq . /tmp/config.cpr)"

# Phone home to tink NOW if non-packet custom image is used
if [ "$early_phone" -eq 1 ]; then
	phone_home "${tinkerbell}" '{"instance_id":"'"$(jq -r .id "$metadata")"'"}'
fi

ensure_reachable "${image}"
if ! wget --spider --quiet "${image}"; then
	echo "$0: Image URL unavailable: $image" >&2
	exit 1
fi

## Pre-prov check
echo -e "${GREEN}#### Starting pre-provisioning checks...${NC}"

echo "Number of drives found: ${#disks[*]}"
if ((${#disks[*]} != 0)); then
	echo "Disk candidate check successful"
else
	problem "$tinkerbell" '{"problem":"missing_drive"}'
	fail "$tinkerbell" 'missing_drive'
	echo "Critical: No block devices detected! Install cannot begin. Missing drives?"
	read -rsp $'Press escape to continue...\n' -d $'\e'
	exit 1
fi

## Begin installation
##
stimer=$(date +%s)

# make sure the disks are ok to use
assert_block_or_loop_devs "${disks[@]}"
assert_same_type_devs "${disks[@]}"

## Execute the callback to API
phone_home "${tinkerbell}" '{"type":"provisioning.104"}'

# Inform the API about partitioning
phone_home "${tinkerbell}" '{"type":"provisioning.105"}'

echo -e "${GREEN}#### Running CPR disk config${NC}"
./cpr.sh $cprconfig "$target" | tee $cprout

rootuuid=$(jq -r .rootuuid $cprout)
[[ -n $rootuuid ]]
bootuuid=$(blkid -s UUID -o value /dev/sda2)
[[ -n $bootuuid ]]

# Ensure critical OS dirs
mkdir -p $target/{dev,proc,sys}

echo "Binding systems dirs to container then recreate initrd with dracut"
mount --bind /dev $target/dev
mount --bind /tmp $target/tmp
mount --bind /proc $target/proc
mount --bind /sys $target/sys
## TODO - detect latest initrd file name version from before dracut call
chroot "$target" /bin/bash -c "dracut -f --filesystems='ext4 vfat' /boot/initramfs-3.10.0-327.36.1.vz7.20.18.img 3.10.0-327.36.1.vz7.20.18"

# Inform the API about OS/package installation
phone_home "${tinkerbell}" '{"type":"provisioning.106"}'

mkdir -p $target/etc/mdadm
if [[ $class != "t1.small.x86" ]]; then
	echo -e "${GREEN}#### Updating MD RAID config file ${NC}"
	mdadm --examine --scan >>$target/etc/mdadm/mdadm.conf
fi

# dump cpr provided fstab into $target
jq -r .fstab "$cprout" >$target/etc/fstab

# Install grub
echo -e "${GREEN}#### Installing GRUB2${NC}"
rm -rf $target/boot/grub/*
cp $target/boot/grub2/grub.cfg $target/boot/grub/
rm -rf $target/boot/grub2
if is_loop_dev "${disk[0]}"; then
	mkdir -p $target/boot/grub
	printf '%s\n' "${disks[@]}" |
		sed 's|/dev/loop\([0-9]\+\)|(hd\1) &\n(hd\1p1) &p1\n(hd\1p2) &p2\n(hd\1p3) &p3|' >$target/boot/grub/device.map
	cat $target/boot/grub/device.map
fi
for disk in "${disks[@]:0:2}"; do
	echo "Running grub-install on $disk"
	#grub-install --recheck --root-directory=$target "$disk"
	grub-install --recheck --boot-directory $target/boot "$disk"
done
sed -i "s/PACKET_ROOT_UUID/$rootuuid/g" $target/boot/grub/grub.cfg
sed -i "s/PACKET_BOOT_UUID/$bootuuid/g" $target/boot/grub/grub.cfg

set_root_pw "$pwhash" $target/etc/shadow

echo -e "${GREEN}#### Setting up network config${NC}"
# tinkerbell provides DNS servers to OSIE via dhcp and udhcpc writes out
# /etc/resolv.conf.   We parse resolv.conf to get those servers for inclusion within
# the target
dns_resolvers

netmeta() {
	jq -r ".network.$1" "$metadata"
}

iface0=$(netmeta 'interfaces[0].name')
iface1=$(netmeta 'interfaces[1].name')
ifaces=$(netmeta 'interfaces[].name')
echo "Interfaces: $iface0 $iface1"

mode=$(netmeta 'bonding.mode')
echo "Bonding mode: $mode"

ipv4pubaddr=$(netmeta 'addresses[0].address')
ipv4pubgw=$(netmeta 'addresses[0].gateway')
ipv4pubmask=$(netmeta 'addresses[0].netmask')
echo "Public  V4: $ipv4pubaddr          Gateway: $ipv4pubgw             Netmask: $ipv4pubmask"

ipv4priaddr=$(netmeta 'addresses[2].address')
ipv4prigw=$(netmeta 'addresses[2].gateway')
ipv4primask=$(netmeta 'addresses[2].netmask')
echo "Private V4: $ipv4priaddr          Gateway: $ipv4prigw             Netmask: $ipv4primask"

ipv6pubaddr=$(netmeta 'addresses[1].address')
ipv6pubgw=$(netmeta 'addresses[1].gateway')
ipv6pubmask=$(netmeta 'addresses[1].netmask')
hostname=$(jq -r '.hostname' "$metadata")
echo "Public  V6: $ipv6pubaddr  Gateway: $ipv6pubgw     Netmask: $ipv6pubmask"

cat <<EOF_netcfg_bonding_mod >"$target/etc/modprobe.d/bonding.conf"
alias bond0 bonding
options bond0 mode=$mode miimon=100 downdelay=200 updelay=200
EOF_netcfg_bonding_mod

cat <<EOF_netcfg_bond0 >"$target/etc/sysconfig/network-scripts/ifcfg-bond0"
DEVICE=bond0
ONBOOT=yes
USERCTL=no
BRIDGE=br0
BOOTPROTO=none
NM_CONTROLLED=no
EOF_netcfg_bond0

cat <<EOF_netcfg_br0_0 >"$target/etc/sysconfig/network-scripts/ifcfg-br0:0"
DEVICE="br0:0"
IPADDR=$ipv4priaddr
NETMASK=$ipv4primask
ONBOOT=yes
NETBOOT=yes
IPV6INIT=yes
BOOTPROTO=none
TYPE="Bridge"
DELAY="4"
STP="off"
EOF_netcfg_br0_0

cat <<EOF_netcfg_br0 >"$target/etc/sysconfig/network-scripts/ifcfg-br0"
DEVICE="br0"
IPADDR=$ipv4pubaddr
NETMASK=$ipv4pubmask
GATEWAY=$ipv4pubgw
UUID="$rootuuid"
ONBOOT=yes
NETBOOT=yes
IPV6INIT=yes
BOOTPROTO=none
TYPE="Bridge"
DELAY="2"
STP="off"
EOF_netcfg_br0

dns_redhat "$target/etc/sysconfig/network-scripts/ifcfg-br0"
dns_redhat "$target/etc/sysconfig/network-scripts/ifcfg-br0:0"

# Add backend route for private v4
echo "10.0.0.0/8 via $ipv4prigw dev bond0:0" >"$target/etc/sysconfig/network-scripts/route-bond0"

ifacecnt=0
for iface in ${ifaces[*]}; do
	echo "Writing iface config for $iface"
	ifacecnt=$((ifacecnt + 1))
	cat <<-EOF_netcfg_iface >"$target/etc/sysconfig/network-scripts/ifcfg-$iface"
		DEVICE=$iface
		USERCTL=no
		ONBOOT=yes
		NM_CONTROLLED=no
		MASTER=bond0
		SLAVE=yes
		BOOTPROTO=none
	EOF_netcfg_iface
done

# other stuff

dns_resolvconf "$target/etc/resolv.conf"

echo "Setting up hostname"
echo "$hostname" >"$target/etc/hostname"
cat <<EOF_netcfg_network >"$target/etc/sysconfig/network"
NETWORKING=yes
HOSTNAME=$hostname
EOF_netcfg_network

# blacklist ixgbe module - TODO: replace this with kopt
echo "blacklist ixgbe" >>"$target/etc/modprobe.d/blacklist.conf"

cat <<EOF_vz_hosts >"$target/etc/hosts"
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
EOF_vz_hosts

# Inform the API about target network configured
phone_home "${tinkerbell}" '{"type":"provisioning.107"}'

echo "Configuring cloud-init for Packet"

if [ -f $target/etc/cloud/cloud.cfg ]; then
	cat <<-EOF >$target/etc/cloud/cloud.cfg
		disable_root: 0
		ssh_pwauth:   0
		phone_home:
		  url: ${tinkerbell}/phone-home
		  post:
		    - instance_id
		  tries: 5
		datasource:
		  Ec2:
		    timeout: 60
		    max_wait: 120
		    metadata_urls: [ 'https://metadata.packet.net' ]
		    dsmode: net
		cloud_init_modules:
		 - DataSourceEc2
		 - migrator
		 - bootcmd
		 - write-files
		 - growpart
		 - resizefs
		 - set_hostname
		 - update_hostname
		 - update_etc_hosts
		 - rsyslog
		 - ssh
		 - phone-home
		cloud_config_modules:
		 - DataSourceEc2
		 - mounts
		 - locale
		 - set-passwords
		 - yum-add-repo
		 - package-update-upgrade-install
		 - timezone
		 - puppet
		 - chef
		 - salt-minion
		 - mcollective
		 - runcmd
		cloud_final_modules:
		 - DataSourceEc2
		 - scripts-per-once
		 - scripts-per-boot
		 - scripts-per-instance
		 - scripts-user
		 - ssh-authkey-fingerprints
		 - keys-to-console
		 - final-message
	EOF
	echo "Disabling cloud-init based network config via cloud.cfg.d include"
	echo "network: {config: disabled}" >$target/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
	echo "WARNING: Removing /var/lib/cloud/*"
	rm -rf $target/var/lib/cloud/*
else
	echo "Cloud-init post-install -  default cloud.cfg does not exist!"
fi

if [ -f $target/etc/cloud/cloud.cfg.d/90_dpkg.cfg ]; then
	cat <<EOF >$target/etc/cloud/cloud.cfg.d/90_dpkg.cfg
# to update this file, run dpkg-reconfigure cloud-init
datasource_list: [ Ec2 ]
EOF
fi

if [ -f $target/etc/init/cloud-init-nonet.conf ]; then
	sed -i 's/dowait 120/dowait 1/g' $target/etc/init/cloud-init-nonet.conf
	sed -i 's/dowait 10/dowait 1/g' $target/etc/init/cloud-init-nonet.conf
else
	echo "Cloud-init post-install - cloud-init-nonet does not exist. skipping edit"
fi

# Inform the API about cloud-init complete
phone_home "${tinkerbell}" '{"type":"provisioning.108"}'

# Setup defaul grub for packet serial console
echo -e "${GREEN}#### Adding packet serial console${NC}"
touch $target/etc/inittab
echo "s0:2345:respawn:/sbin/agetty ttyS1 115200" >>$target/etc/inittab

mkdir -p $target/etc/init
cat <<EOF_tty >$target/etc/init/ttyS1.conf
#
# This service maintains a getty on ttyS1 from the point the system is
# started until it is shut down again.
start on stopped rc or RUNLEVEL=[12345]
stop on runlevel [!12345]
respawn
exec /sbin/agetty ttyS1 115200
EOF_tty

echo "Updating grub default config for console"
cat <<EOF_defgrub >>$target/etc/default/grub

# Added for Packet serial console
GRUB_TERMINAL=serial
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=1 --word=8 --parity=no --stop=1"
EOF_defgrub

sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="console=ttyS1,115200n8 /g' $target/etc/default/grub

# Generate machine specific IDs
chroot "$target" /bin/bash -c "uuidgen -r | sed 's/-//g' | head -c 16 | cat > /etc/vstorage/host_id"
chroot "$target" /bin/bash -c "uuidgen -r | sed 's/-//g' > /etc/machine-id"

echo -e "${GREEN}#### Adding license config${NC}"
licmeta() {
	jq -r ".operating_system.$1" "$metadata"
}

# Get license from MD
vz_license=$(licmeta 'license_activation.key')
if [ -n "$vz_license" ]; then
	echo "Retrieived license ($vz_license) firom metadata..."
	echo "$vz_license" >$target/var/cache/vzlicense.key
else
	echo "Error: Could not retrieve Virtuozzo license from metadata!"
fi

# Add license service for systemd
cat <<EOF_UNIT >"$target/usr/lib/systemd/system/packet-license.service"
[Unit]
Description=Initial packet-license activation helper
Requires=network.target
Before=cloud-init.service

[Service]
Type=oneshot
ExecStart=/usr/bin/packet-license
TimeoutSec=0
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF_UNIT

cat <<'EOF_pl' >"$target/usr/bin/packet-license"
#!/bin/bash

licfile="/var/cache/vzlicense.key"

if [ -f $licfile ]; then
	licstring=$(cat $licfile)
else
	echo "Could not find license file: $licfile"
fi

# syntax: fail 1.2.3.4 'reason'
function fail() {
	local tink_host=$1
	shift

	puttink "${tink_host}" phone-home '{"type":"failure","reason":"'"$1"'"}'
}

# syntax: puttink 1.2.3.4 phone-home '{"this": "data"}'
function puttink() {
	local tink_host=$1
	local endpoint=$2
	local post_data=$3

	curl \
		-f \
		-vvvvv \
		-X PUT \
		-H "Content-Type: application/json" \
		-d "${post_data}" \
		"${tink_host}/${endpoint}"
}

function license_vz () {
	local license=$1
	local command="vzlicload -p $license"
	local retries=10
	local wait_retry=5
	local act_status=0

	for i in $(seq 1 $retries); do
		echo "$command"
		$command
		ret_value=$?
		if [ $ret_value -eq 0 ]; then
			act_status=1 ; break
		fi
		echo "> failed with $ret_value, waiting to retry..."
		sleep $wait_retry
	done
	if [ $act_status -ne 1 ]; then
		echo "Activation retries $retries/$retries failed."
		fail "$tinkerbell" 'vz_license_activation_failed'
	else
		vzlicstatus=$(vzlicview)
		if [[ $vzlicstatus =~ .*status=\"ACTIVE\"* ]]; then
			echo "License activation was successful!"
		else
			echo "Licese activation could not be verified. Status: $(echo "$vzlicstatus")"
			fail "$tinkerbell" 'vz_license_status_not_verified'
		fi
	fi
	rm -f $licfile
}

license_vz "$licstring"
EOF_pl
chmod +x $target/usr/bin/packet-license

# Enable license service
ln -s /usr/lib/systemd/system/packet-license.service "$target/etc/systemd/system/packet-license.service"
ln -s /usr/lib/systemd/system/packet-license.service "$target/etc/systemd/system/multi-user.target.wants/packet-license.service"

# Inform the API about installation complete
phone_home "${tinkerbell}" '{"type":"provisioning.109"}'
echo "Done."

## End installation
#
etimer=$(date +%s)
echo -e "${BYELLOW}Install time: $((etimer - stimer))${NC}"

cat >/statedir/cleanup.sh <<EOF
#!/bin/sh
reboot
EOF
chmod +x /statedir/cleanup.sh
