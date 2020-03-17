#!/bin/bash

source functions.sh && init

# defaults
# shellcheck disable=SC2207
disks=($(lsblk -dno name -e1,7,11 | sed 's|^|/dev/|' | sort))
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

arch=$(uname -m)

check_required_arg "$metadata" 'metadata file' '-M'
assert_all_args_consumed "$OPTIND" "$@"

declare class && set_from_metadata class 'class' <"$metadata"
declare facility && set_from_metadata facility 'facility' <"$metadata"
declare os && set_from_metadata os 'operating_system.slug' <"$metadata"
declare state && set_from_metadata state 'state' <"$metadata"
declare tag && set_from_metadata tag 'operating_system.image_tag' <"$metadata" || tag=""
declare tinkerbell && set_from_metadata tinkerbell 'phone_home_url' <"$metadata"
# shellcheck disable=SC2001
tinkerbell=$(echo "$tinkerbell" | sed 's|\(http://[^/]\+\).*|\1|')

if [[ $state == 'osie.internal.check-env' ]]; then
	exit 1
	lsmod | grep fuse -q && exit 0
	cat >/statedir/loop.sh <<-EOF
		#!/bin/ash
		modprobe fuse
	EOF
	chmod +x /statedir/loop.sh
	exit 0
fi

if [[ -z $tag ]]; then
	echo "$OS has NO IMAGE_TAG specified!"
	exit 1
fi
OS=$os${tag:+:$tag}

# if $BASEURL is not empty then the user specifically passed in the artifacts
# location, we should not trample it
BASEURL=${BASEURL:-http://install.$facility.packet.net/misc}

## Fetch install assets via git
assetdir=/tmp/assets
mkdir $assetdir
echo -e "${GREEN}#### Fetching image (and more) via git ${NC}"

# config hosts entry so git-lfs assets are pulled through our image cache
githost="images.packet.net"
images_ip=$(getent hosts $githost | awk '{print $1}')
cp -a /etc/hosts /etc/hosts.new
echo "$images_ip        github-cloud.s3.amazonaws.com" >>/etc/hosts.new && cp -f /etc/hosts.new /etc/hosts
echo -n "LFS pulls via github-cloud will now resolve to image cache:"
getent hosts github-cloud.s3.amazonaws.com | awk '{print $1}'

gitpath="packethost/packet-images.git"
gituri="https://${githost}/${gitpath}"

# TODO - figure how we can do SSL passthru for github-cloud to images cache
git config --global http.sslverify false

git -C $assetdir init
git -C $assetdir remote add origin "${gituri}"
git -C $assetdir fetch origin
git -C $assetdir checkout "${tag}"

## Assemble configurables
##
# Target mount point
target="/mnt/ufs"
# Image rootfs
if is_uefi; then
	image="$assetdir/$arch/latest-freebsd-uefi.raw.gz"
else
	image="$assetdir/$arch/latest-freebsd.raw.gz"
fi

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BYELLOW='\033[0;33;5;7m'
NC='\033[0m' # No Color

echo -e "${GREEN}#### Checking userdata for custom image_url...${NC}"
image_url=$(sed -nr 's|.*\bimage_url=(\S+).*|\1|p' "$userdata")
if [[ -z ${image_url} ]]; then
	echo "Using default image since no image_url provided"
else
	echo "NOTICE: Custom image url found!"
	echo "This is not supported at the moment!"
	fail "$tinkerbell" "custom image_url is not supported on freebsd"
	exit 1
fi
echo "Image: $image"
echo "Devices: ${disks[*]}"

## Begin installation
##
stimer=$(date +%s)

# make sure the disks are ok to use
assert_block_or_loop_devs "${disks[@]}"
assert_same_type_devs "${disks[@]}"

imagedev=$(echo "${disks[@]}" | tr ' ' '\n' | grep '/dev/[sv]d' | head -n 1)
rootdev="${imagedev}3"

## Execute the callback to API
phone_home "${tinkerbell}" '{"type":"provisioning.104"}'

echo -e "${GREEN}Checking disks for existing partitions...${NC}"
if fdisk -l "${disks[@]}" 2>/dev/null | grep Disklabel >/dev/null; then
	echo -e "${RED}Critical: Found pre-exsting partitions on a disk. Aborting install...${NC}"
	fdisk -l "${disks[@]}"
	exit 1
fi
echo "Disk candidates are ready for partitioning."

# Inform the API about partitioning
phone_home "${tinkerbell}" '{"type":"provisioning.105"}'

# Write rootfs to disk
echo -e "${GREEN}#### Extracting image archive and writing to first disk${NC}"
zcat "$image" | dd iflag=fullblock conv=sparse bs=32k of="${imagedev}"

## TODO: Fix stdout redirection to block device
#echo "Downloading, extracting and writing image to sda..."
#declare -a EEND
#if ! wget --no-verbose -O - "${image}" >(tar -zxf --to-stdout >/dev/sda)
#then
#    EEND=(${PIPESTATUS[@]})
#    [ ${EEND[0]} -ne 0 ] && echo "${EEND[0]}: Download of ${image} did not complete" >&2
#    [ ${EEND[1]} -ne 0 ] && echo "${EEND[1]}: Cannot expand ${image} to /dev/sda" >&2
#    exit 1
#fi

# Inform the API about OS/package installation
phone_home "${tinkerbell}" '{"type":"provisioning.106"}'

dpkg -i "/tmp/osie-fuse-ufs2_1.0-1_$arch.deb"

partprobe "${imagedev}"
mkdir -p "$target"
fuse-ufs -o rw "$rootdev" $target

echo "#### Retreived network config details"
# tinkerbell provides DNS servers to OSIE via dhcp and udhcpc writes out
# /etc/resolv.conf.   We parse resolv.conf to get those servers for inclusion within
# the target
dns_resolvers

netmeta() {
	jq -r ".network.$1" "$metadata"
}

iface0=$(netmeta 'interfaces[0].name')
iface1=$(netmeta 'interfaces[1].name')
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
ipv6pubcidr=$(netmeta 'addresses[1].cidr')
hostname=$(jq -r '.hostname' "$metadata")
echo "Public  V6: $ipv6pubaddr  Gateway: $ipv6pubgw     Netmask: $ipv6pubmask"

case "$mode" in
4) laggproto="lacp" ;;
5) laggproto="loadbalance" ;;
*) laggproto="failover" ;;
esac

cat <<EOF_netcfg_freebsd >$target/etc/rc.conf
hostname="${hostname}"
cloned_interfaces="lagg0"
ifconfig_${iface0}="up"
ifconfig_${iface1}="up"
ifconfig_lagg0="laggproto ${laggproto} laggport ${iface0} laggport ${iface1}"
ifconfig_lagg0_alias0="inet ${ipv4pubaddr} netmask ${ipv4pubmask}"
ifconfig_lagg0_alias1="inet ${ipv4priaddr} netmask ${ipv4primask}"
ifconfig_lagg0_ipv6="inet6 ${ipv6pubaddr} prefixlen ${ipv6pubcidr}"
defaultrouter="${ipv4pubgw}"
ipv6_defaultrouter="${ipv6pubgw}"
static_routes="private"
route_private="-net 10.0.0.0/8 ${ipv4prigw}"
sshd_enable="YES"
sendmail_enable="NONE"
inetd_enable="NO"
growfs_enable="YES"
cloudinit_enable="YES"
EOF_netcfg_freebsd

if [[ $class == "c1.large.arm" ]]; then
	mkdir -p $target/etc/iov

	cat <<EOF_iov_vnicpf_conf >$target/etc/iov/vnicpf0.conf
PF {
	device: "vnicpf0";
	num_vfs: 2;
}
EOF_iov_vnicpf_conf

	echo 'iovctl_files="/etc/iov/vnicpf0.conf"' >>$target/etc/rc.conf
fi

# tinkerbell provides DNS servers to OSIE via dhcp and udhcpc writes out
# /etc/resolv.conf.   We parse resolv.conf to get those servers for inclusion within
# the target
dns_resolvconf $target/etc/resolv.conf

if [ -d /sys/firmware/efi ]; then
	cat <<EOF_loaderconf >$target/boot/loader.conf
autoboot_delay="3"
beastie_disable="YES"
console="efi"
EOF_loaderconf
else
	cat <<EOF_loaderconf >$target/boot/loader.conf
autoboot_delay="3"
beastie_disable="YES"
boot_serial="YES"
comconsole_port="0x2F8"
comconsole_speed="115200"
console="comconsole vidconsole"
EOF_loaderconf
fi

cat <<EOF_rclocal >$target/etc/rc.local
#!/bin/sh
/usr/local/bin/curl -v \
-X POST \
-H "Content-Type: application/json" \
-d '{"instance_id": "$(jq -r .id "$metadata")"}' \
"$tinkerbell/phone-home"

rm -f /etc/rc.local
EOF_rclocal

chmod 755 "$target/etc/rc.local"

if [ -f "$target/usr/local/etc/cloud/cloud.cfg" ]; then
	cat <<-EOF >"$target/usr/local/etc/cloud/cloud.cfg"
		syslog_fix_perms: root:wheel
		disable_root: false
		preserve_hostname: false
		ssh_deletekeys: false
		datasource_list: ['Ec2']
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
		 - migrator
		 - ssh
		cloud_final_modules:
		 - phone-home
		 - scripts-user
		 - ssh-authkey-fingerprints
		 - keys-to-console
		 - final-message
		system_info:
		  distro: freebsd
	EOF
	echo "Disabling cloud-init based network config via cloud.cfg.d include"
	echo "network: {config: disabled}" >"$target/usr/local/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
	echo "WARNING: Removing /var/lib/cloud/*"
	rm -rf "$target/var/lib/cloud/*"
else
	echo "Cloud-init post-install -  default cloud.cfg does not exist!"
fi

if lspci | grep LSI; then
	echo 'hw.mfi.mrsas_enable=1' >>$target/boot/loader.conf
fi

for iface in $iface{0..1}; do
	if [[ $iface =~ ^mlxen[0-9]+$ ]]; then
		# shellcheck disable=SC2034
		module_load_mlx4en='YES'
	elif [[ $iface =~ ^mce[0-9]+$ ]]; then
		# shellcheck disable=SC2034
		module_load_mlx5en='YES'
	fi
done

for module in 'mlx4en' 'mlx5en'; do
	var="module_load_${module}"
	if [[ -n ${!var} ]]; then
		echo "${module}_load=\"${!var}\"" >>$target/boot/loader.conf
	fi
done

umount $target

# Inform the API about target network configured
phone_home "${tinkerbell}" '{"type":"provisioning.107"}'

# Inform the API about cloud-init complete
phone_home "${tinkerbell}" '{"type":"provisioning.108"}'

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
