#!/bin/bash

source functions.sh && init
set -o nounset

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
declare preserve_data && set_from_metadata preserve_data 'preserve_data' false <"$metadata"
declare pwhash && set_from_metadata pwhash 'password_hash' <"$metadata"
declare state && set_from_metadata state 'state' <"$metadata"
declare tag && set_from_metadata tag 'operating_system.image_tag' <"$metadata" || tag=""
declare tinkerbell && set_from_metadata tinkerbell 'phone_home_url' <"$metadata"
declare deprovision_fast && set_from_metadata deprovision_fast 'deprovision_fast' false <"$metadata"

# shellcheck disable=SC2001
tinkerbell=$(echo "$tinkerbell" | sed 's|\(http://[^/]\+\).*|\1|')

if [[ $state == 'osie.internal.check-env' ]]; then
	exit 0
fi

verbose_logging=$(sed -nr 's|.*\bverbose_logging=(\S+).*|\1|p' "$userdata")
if [[ "${verbose_logging}" == true ]]; then
	echo -e "${GREEN}#### Enabling Verbose OSIE Logging${NC}"
	set -o xtrace
fi

# On errors, run autofail() before exiting
set_autofail_stage "OSIE startup"
function autofail() {
	# Passthrough for when the main script exits normally
	# shellcheck disable=SC2181
	(($? == 0)) && exit

	puttink "${tinkerbell}" phone-home '{"type":"failure", "reason":"'"${autofail_stage}"'"}'
	print_error_summary "${autofail_stage}"
}
trap autofail EXIT

OS=$os${tag:+:$tag}

# if $BASEURL is not empty then the user specifically passed in the artifacts
# location, we should not trample it
BASEURL=${BASEURL:-http://install.$facility.packet.net/misc/osie/current}

# if $mirror is not empty then the user specifically passed in the mirror
# location, we should not trample it
mirror=${mirror:-http://mirror.$facility.packet.net}

## Tell the API we're connected to the magic install system
phone_home "${tinkerbell}" '{"type":"provisioning.104"}'

echo -e "${GREEN}### OSIE Version ${OSIE_VERSION} (${OSIE_BRANCH})${NC}"

## Pre-prov check
echo -e "${GREEN}#### Starting pre-provisioning checks...${NC}"

set_autofail_stage "install drive detection"
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

custom_image=false
set_autofail_stage "custom image check"
echo -e "${GREEN}#### Checking userdata for custom image...${NC}"
image_repo=$(sed -nr 's|.*\bimage_repo=(\S+).*|\1|p' "$userdata")
image_tag=$(sed -nr 's|.*\bimage_tag=(\S+).*|\1|p' "$userdata")
if [[ -z ${image_repo} ]]; then
	echo "Using default image since no image_repo provided"
	early_phone=0
else
	echo "NOTICE: Custom image repo found!"
	echo "Overriding default image location with custom image_repo"
	if [[ -z ${image_tag} ]]; then
		echo "ERROR: custom image_repo passed but no custom image_tag provided"
		exit 1
	fi
	early_phone=1
	custom_image=true
fi

# Phone home to tink NOW if non-packet custom image is used. We don't do this
# later in case the custom OS image or url is bad, to ensure instance will be
# preserved for the user to troubleshoot.
if [ "$early_phone" -eq 1 ]; then
	# Re-DHCP so we obtain an IP that will last beyond the early phone_home
	set_autofail_stage "reacquire_dhcp (early_phone)"
	reacquire_dhcp "$(ip_choose_if)"
	phone_home "${tinkerbell}" '{"instance_id":"'"$(jq -r .id "$metadata")"'"}'
fi

target="/mnt/target"
cprconfig=/tmp/config.cpr
cprout=/statedir/cpr.json
set_autofail_stage "custom cpr_url check"
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

## Begin installation
##
stimer=$(date +%s)

if ! [[ -f /statedir/disks-partioned-image-extracted ]]; then
	## Fetch install assets via git
	assetdir=/tmp/assets
	mkdir $assetdir
	set_autofail_stage "OS image fetch"
	echo -e "${GREEN}#### Fetching image (and more) via git ${NC}"

	# config hosts entry so git-lfs assets from github and our github-mirror are
	# pulled through our image cache
	images_ip=$(getent hosts images.packet.net | awk '{print $1}')
	cp -a /etc/hosts /etc/hosts.new
	{
		echo "$images_ip        github-cloud.s3.amazonaws.com"
		echo "$images_ip        github.com"
		echo "$images_ip        github-mirror.packet.net"
	} >>/etc/hosts.new
	# Note: using mv here fails (415 Unsupported Media Type) because docker sets
	# this up as a bind mount and we can't replace it.
	cp -f /etc/hosts.new /etc/hosts
	echo -n "LFS pulls via github-cloud will now resolve to image cache:"
	getent hosts github-cloud.s3.amazonaws.com | awk '{print $1}'

	if [[ ${OS} =~ : && $custom_image == false ]]; then
		image_tag=$(echo "$OS" | awk -F':' '{print $2}')

		githost="github-mirror.packet.net"
		# Prefer our local github-mirror, falling back to github.com
		if ! github_mirror_check; then
			echo -e "${YELLOW}###### github-mirror health check failed, falling back to using github.com${NC}"
			githost="github.com"
		fi

		gitpath="packethost/packet-images.git"
		gituri="https://${githost}/${gitpath}"

		# Increase LFS max retries to prevent intermittent LFS smudge failures
		git config --global lfs.transfer.maxtretries 10
		# TODO - figure how we can do SSL passthru for github-cloud to images cache
		git config --global http.sslverify false
	elif [[ $custom_image == true ]]; then
		if [[ ${image_repo} =~ github ]]; then
			git config --global http.sslverify false
		fi

		gituri="${image_repo}"
	fi
	# Silence verbose notice about deatched HEAD state
	git config --global advice.detachedHead false

	echo -e "${YELLOW}###### GIT DEBUGGING: git config:${NC}"
	git config -l

	git -C $assetdir init
	echo -e "${GREEN}#### Adding git remote uri: ${gituri}${NC}"
	GIT_TRACE=1 git -C $assetdir remote add origin "${gituri}"
	echo -e "${GREEN}#### Performing a shallow git fetch for: ${image_tag}${NC}"
	GIT_TRACE=1 git -C $assetdir fetch --depth 1 origin "${image_tag}"
	echo -e "${GREEN}###### Performing a checkout of FETCH_HEAD${NC}"
	GIT_TRACE=1 git -C $assetdir checkout FETCH_HEAD

	# Tell the API that the OS image has been retrieved
	phone_home "${tinkerbell}" '{"type":"provisioning.104.50"}'

	OS=${OS%%:*}

	## Assemble configurables
	##
	# Kernel to throw on the target
	kernel="$assetdir/kernel.tar.gz"
	# Initrd to throw on the target
	initrd="$assetdir/initrd.tar.gz"
	# Modules to throw on the target
	modules="$assetdir/modules.tar.gz"
	# Image rootfs
	image="$assetdir/image.tar.gz"
	# Grub config
	grub="$BASEURL/grub/${OS//_(arm|image)//}/$class/grub.template"

	echo -e "${WHITE}Image: $image${NC}"
	echo -e "${WHITE}Modules: $modules${NC}"
	echo -e "${WHITE}Kernel: $kernel${NC}"
	echo -e "${WHITE}Initrd: $initrd${NC}"
	echo -e "${WHITE}Devices:${disks[*]}${NC}"
	echo -e "${WHITE}CPR: ${NC}"
	jq . $cprconfig

	# make sure the disks are ok to use
	set_autofail_stage "sanity check of disks/partitions"
	assert_block_or_loop_devs "${disks[@]}"
	assert_same_type_devs "${disks[@]}"

	is_uefi && uefi=true || uefi=false

	if [[ $deprovision_fast == false ]] && [[ $preserve_data == false ]]; then
		echo -e "${GREEN}Checking disks for existing partitions...${NC}"
		if fdisk -l "${disks[@]}" 2>/dev/null | grep Disklabel >/dev/null; then
			echo -e "${RED}Critical: Found pre-exsting partitions on a disk. Aborting install...${NC}"
			fdisk -l "${disks[@]}"
			exit 1
		fi
	fi

	echo "Disk candidates are ready for partitioning."

	# Tell the API that partitioning is complete
	phone_home "${tinkerbell}" '{"type":"provisioning.105"}'

	set_autofail_stage "CPR disk config"
	echo -e "${GREEN}#### Running CPR disk config${NC}"
	UEFI=$uefi ./cpr.sh $cprconfig "$target" "$preserve_data" "$deprovision_fast" | tee $cprout

	mount | grep $target

	# Extract the image rootfs
	set_autofail_stage "extraction of image rootfs"
	echo -e "${GREEN}#### Retrieving image archive and installing to target $target ${NC}"
	tar --xattrs --acls --selinux --numeric-owner --same-owner --warning=no-timestamp -zxpf "$image" -C $target

	# dump cpr provided fstab into $target
	jq -r .fstab "$cprout" >$target/etc/fstab

	# Ensure critical OS dirs
	mkdir -p $target/{dev,proc,sys}

	# Tell the API that OS packages have been installed
	phone_home "${tinkerbell}" '{"type":"provisioning.106"}'

	mkdir -p $target/etc/mdadm
	if [[ $class != "t1.small.x86" ]]; then
		echo -e "${GREEN}#### Updating MD RAID config file ${NC}"
		mdadm --examine --scan >>$target/etc/mdadm/mdadm.conf
	fi

	# ensure unique dbus/systemd machine-id
	set_autofail_stage "machine-id setup"
	echo -e "${GREEN}#### Setting machine-id${NC}"
	rm -f $target/etc/machine-id $target/var/lib/dbus/machine-id
	systemd-machine-id-setup --root=$target
	cat $target/etc/machine-id
	[[ -d $target/var/lib/dbus ]] && ln -nsf /etc/machine-id $target/var/lib/dbus/machine-id

	# Install kernel and initrd
	set_autofail_stage "install of kernel/modules/initrd to target"
	echo -e "${GREEN}#### Copying kernel, modules, and initrd to target $target ${NC}"
	tar --warning=no-timestamp -zxf "$kernel" -C $target/boot
	kversion=$(vmlinuz_version $target/boot/vmlinuz)
	if [[ -z $kversion ]]; then
		echo 'unable to extract kernel version' >&2
		exit 1
	fi

	kernelname="vmlinuz-$kversion"
	if [[ ${OS} =~ ^centos ]] || [[ ${OS} =~ ^rhel ]]; then
		initrdname=initramfs-$kversion.img
		modulesdest=usr
	else
		initrdname=initrd.img-$kversion
		modulesdest=
	fi

	mv $target/boot/vmlinuz "$target/boot/$kernelname" && ln -nsf "$kernelname" $target/boot/vmlinuz
	tar --warning=no-timestamp -zxf "$initrd" && mv initrd "$target/boot/$initrdname" && ln -nsf "$initrdname" $target/boot/initrd
	tar --warning=no-timestamp -zxf "$modules" -C "$target/$modulesdest"
	cp "$target/boot/$kernelname" /statedir/kernel
	cp "$target/boot/$initrdname" /statedir/initrd

	# Install grub
	set_autofail_stage "install of grub"
	echo -e "${GREEN}#### Installing GRUB2${NC}"

	wget "$grub" -O /tmp/grub.template
	wget "${grub}.default" -O /tmp/grub.default

	./grub-installer.sh -v -p "$class" -t "$target" -C "$cprout" -D /tmp/grub.default -T /tmp/grub.template

	rootuuid=$(jq -r .rootuuid $cprout)
	[[ -n $rootuuid ]]
	cmdline=$(sed -nr 's|GRUB_CMDLINE_LINUX='\''(.*)'\''|\1|p' /tmp/grub.default)

	cat <<EOF >/statedir/cleanup.sh
#!/bin/sh

set -euxo pipefail
echo "kexecing into installed os"
kexec -l ./kernel --initrd=./initrd --command-line="BOOT_IMAGE=/boot/vmlinuz root=UUID=$rootuuid ro $cmdline" || reboot
kexec -e || reboot
EOF

	echo -e "${GREEN}#### Clearing init overrides to enable TTY${NC}"
	rm -rf $target/etc/init/*.override

	if [[ $custom_image == false ]]; then
		set_autofail_stage "package repo setup"
		echo -e "${GREEN}#### Setting up package repos${NC}"
		./repos.sh -a "$arch" -t $target -f "$facility" -M "$metadata"
	fi

	set_autofail_stage "cloud-init configuration"
	echo -e "${GREEN}#### Configuring cloud-init for Packet${NC}"
	if [ -f $target/etc/cloud/cloud.cfg ]; then
		case ${OS} in
		centos* | rhel* | scientific*) repo_module=yum-add-repo ;;
		debian* | ubuntu*) repo_module=apt-configure ;;
		esac

		cat <<-EOF >$target/etc/cloud/cloud.cfg
			apt:
			  preserve_sources_list: true
			datasource_list: [Ec2]
			datasource:
			  Ec2:
			    timeout: 60
			    max_wait: 120
			    metadata_urls: [ 'https://metadata.packet.net' ]
			    dsmode: net
			disable_root: 0
			package_reboot_if_required: false
			package_update: false
			package_upgrade: false
			phone_home:
			  url: ${tinkerbell}/phone-home
			  post:
			    - instance_id
			  tries: 5
			ssh_genkeytypes: ['rsa', 'dsa', 'ecdsa', 'ed25519']
			ssh_pwauth:   0
			cloud_init_modules:
			 - migrator
			 - bootcmd
			 - write-files
			 - growpart
			 - resizefs
			 - update_hostname
			 - update_etc_hosts
			 - users-groups
			 - rsyslog
			 - ssh
			cloud_config_modules:
			 - mounts
			 - locale
			 - set-passwords
			 ${repo_module:+- $repo_module}
			 - package-update-upgrade-install
			 - timezone
			 - puppet
			 - chef
			 - salt-minion
			 - mcollective
			 - runcmd
			cloud_final_modules:
			 - phone-home
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

	# Tell the API that cloud-init packages have been installed and configured
	phone_home "${tinkerbell}" '{"type":"provisioning.108"}'

	# Adjust failsafe delays for first boot delay
	if [[ -f $target/etc/init/failsafe.conf ]]; then
		sed -i 's/sleep 59/sleep 10/g' $target/etc/init/failsafe.conf
		sed -i 's/Waiting up to 60/Waiting up to 10/g' $target/etc/init/failsafe.conf
	fi

	set_autofail_stage "misc post-install tasks"
	echo -e "${GREEN}#### Run misc post-install tasks${NC}"
	install -m755 -o root -g root /home/packet/packet-block-storage-* $target/usr/bin
	if [ -f $target/usr/sbin/policy-rc.d ]; then
		echo "Removing policy-rc.d from target OS."
		rm -f $target/usr/sbin/policy-rc.d
	fi

	echo -e "${GREEN}#### Adding network perf tuning${NC}"
	cat >>$target/etc/sysctl.conf <<EOF
# set default and maximum socket buffer sizes to 12MB
net.core.rmem_default=$((12 * 1024 * 1024))
net.core.wmem_default=$((12 * 1024 * 1024))
net.core.rmem_max=$((12 * 1024 * 1024))
net.core.wmem_max=$((12 * 1024 * 1024))

# set minimum, default, and maximum tcp buffer sizes (10k, 87.38k (linux default), 12M resp)
net.ipv4.tcp_rmem=$((10 * 1024)) 87380 $((12 * 1024 * 1024))
net.ipv4.tcp_wmem=$((10 * 1024)) 87380 $((12 * 1024 * 1024))

# Enable TCP westwood for kernels greater than or equal to 2.6.13
net.ipv4.tcp_congestion_control=westwood
EOF

	# Disable GSSAPIAuthentication to speed up SSH logins
	sed -i 's/GSSAPIAuthentication yes/GSSAPIAuthentication no/g' $target/etc/ssh/sshd_config

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

	# Backup phone-home

	# Add phone-home to OS
	nonsystemdoses=(ubuntu_14_04 ubuntu_14_04_image scientific_6)

	if [[ ${nonsystemdoses[*]} =~ ${OS} ]]; then
		cp -a $target/etc/rc.local $target/etc/rc.local.orig
		echo "/bin/phone-home.sh" >$target/etc/rc.local
		chmod 755 $target/etc/rc.local
	else
		if [ -d "$target/usr/lib/systemd/system" ]; then
			systemdloc="usr/lib/systemd/system"
		else
			systemdloc="lib/systemd/system"
		fi

		cat <<-EOF_UNIT >$target/$systemdloc/phone-home.service
			[Unit]
			Description=Tell the API that this device is active.
			After=multi-user.target
			[Service]
			Type=oneshot
			ExecStart=/bin/phone-home.sh
			[Install]
			WantedBy=multi-user.target
		EOF_UNIT

		ln -s $target/$systemdloc/phone-home.service $target/etc/systemd/system/multi-user.target.wants/phone-home.service
	fi

	cat <<EOF_ET >$target/bin/phone-home.sh
#!/bin/bash
logger -s -t phone_home "Making a call to tell the packet API is online."
# doesn't hurt to log as much as we can in case it fails.
n=1
until [ \$n -ge 6 ] || [ "\${PIPESTATUS[0]}" -eq 0 ]; do
	curl -X PUT -H "Content-Type: application/json" -vs -d '{"instance_id": "$(jq -r .id "$metadata")"}' "$tinkerbell/phone-home" 2>&1 | logger -s -t phone_home

	if [ "\${PIPESTATUS[0]}" -eq 0 ]; then
		logger -s -t phone_home "This device has been announced to the packet API."
		break
	else
		logger -s -t phone_home "phone-home command execution (retry \$n / 5) failed."
	fi
	n=\$((n + 1))
	sleep 30
done

if [ -f /etc/rc.local.orig ]; then
	mv -f /etc/rc.local.orig /etc/rc.local
fi

if [ -f /lib/systemd/system/phone-home.service ] ; then
	rm -f /lib/systemd/system/phone-home.service
	rm -f /etc/systemd/system/multi-user.target.wants/phone-home.service
	systemctl daemon-reload
fi

rm /bin/phone-home.sh
EOF_ET

	chmod 700 $target/bin/phone-home.sh

	# CentOS/Redhat specific config
	if [[ ${OS} =~ ^centos ]] || [[ ${OS} =~ ^rhel ]]; then
		set_autofail_stage "CentOS/RHEL extra config"
		echo -e "${GREEN}#### Running CentOS/RHEL extra config${NC}"
		./centos.sh -t $target -k "$tinkerbell" -a "$arch" -M "$metadata"
	fi

	# SUSE specific config
	if [[ ${OS} =~ ^suse ]] || [[ ${OS} =~ ^opensuse ]]; then
		set_autofail_stage "SUSE/openSUSE extra config"
		echo -e "${GREEN}#### Running SUSE/openSUSE extra config${NC}"
		./suse.sh -t $target -k "$tinkerbell" -a "$arch" -M "$metadata"
	fi

	touch /statedir/disks-partioned-image-extracted
else
	set_autofail_stage "cpr.sh"
	./cpr.sh $cprconfig "$target" "$preserve_data" "$deprovision_fast" mount $cprout
	phone_home "${tinkerbell}" '{"type":"provisioning.104"}'
	phone_home "${tinkerbell}" '{"type":"provisioning.104.50"}'
	phone_home "${tinkerbell}" '{"type":"provisioning.105"}'
	phone_home "${tinkerbell}" '{"type":"provisioning.106"}'
	phone_home "${tinkerbell}" '{"type":"provisioning.108"}'
fi

if [[ $pwhash == "preinstall" ]]; then
	exit 0
fi

set_autofail_stage "root password setup"
echo -e "${GREEN}#### Setting password${NC}"
pwuser="root"
if [[ ${OS} =~ vmware_nsx_3_0_0 ]]; then
	pwuser="admin"
fi
set_pw "$pwuser" "$pwhash" $target/etc/shadow

# ensure unique dbus/systemd machine-id, will be based off of container_uuid aka instance_id
set_autofail_stage "machine-id setup (second version)"
echo -e "${GREEN}#### Setting machine-id${NC}"
rm -f $target/etc/machine-id $target/var/lib/dbus/machine-id
systemd-machine-id-setup --root=$target
cat $target/etc/machine-id
[[ -d $target/var/lib/dbus ]] && ln -nsf /etc/machine-id $target/var/lib/dbus/machine-id

set_autofail_stage "network config (packet-networking)"
echo -e "${GREEN}#### Setting up network config${NC}"
packet-networking -t $target -M "$metadata" -o "$(detect_os $target)" -vvv
set_autofail_stage "OSIE final stage"

# Tell the API that the server networking interfaces have been configured
phone_home "${tinkerbell}" '{"type":"provisioning.107"}'

# Tell the API that installation is complete and the server is being rebooted
phone_home "${tinkerbell}" '{"type":"provisioning.109"}'
echo -e "${GREEN}#### Done${NC}"

## End installation
etimer=$(date +%s)
echo -e "${BYELLOW}Install time: $((etimer - stimer))${NC}"

# Bypass kexec for certain OS plan combos
case ${os}:${class} in
centos_8:t1.small.x86) reboot=true ;;
ubuntu_18_04:t1.small.x86) reboot=true ;;
ubuntu_20_04:t1.small.x86) reboot=true ;;
ubuntu_16_04:c3.medium.x86) reboot=true ;;
ubuntu_16_04:t3.small.x86) reboot=true ;;
*:c2.medium.x86) reboot=true ;;
esac

if ${reboot:-false}; then
	cat <<EOF >/statedir/cleanup.sh
#!/bin/sh

set -euxo pipefail
echo "rebooting into installed os"
reboot
EOF
fi

chmod +x /statedir/cleanup.sh
