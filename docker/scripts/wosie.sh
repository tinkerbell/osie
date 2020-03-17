#!/bin/bash

source functions.sh && init

# defaults
# shellcheck disable=SC2207
disks=($(lsblk -dno name -e1,7,11 | sed 's|^|/dev/|' | grep -v nvme | sort | head -n 2))
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

declare facility && set_from_metadata facility 'facility' <"$metadata"
declare os && set_from_metadata os 'operating_system.slug' <"$metadata"
declare state && set_from_metadata state 'state' <"$metadata"
declare tag && set_from_metadata tag 'operating_system.image_tag' <"$metadata" || tag=""
declare tinkerbell && set_from_metadata tinkerbell 'phone_home_url' <"$metadata"
# Get install disk from metadata. If no disk is found, it will default to first discovered disk
declare install_disk && set_from_metadata install_disk 'storage.disks[0].device' "${disks[0]}" <"$metadata"
# shellcheck disable=SC2001
tinkerbell=$(echo "$tinkerbell" | sed 's|\(http://[^/]\+\).*|\1|')

if [[ $state == 'osie.internal.check-env' ]]; then
	exit 0
fi

OS=$os${tag:+:$tag}

# if $BASEURL is not empty then the user specifically passed in the artifacts
# location, we should not trample it
BASEURL=${BASEURL:-http://install.$facility.packet.net/misc}

if [[ ${OS} =~ : ]]; then
	echo "OS has image tag. Resetting OS $OS"
	OS=$(echo "$OS" | awk -F':' '{print $1}')
	echo "OS is now $OS"
fi

## Assemble configurables
##
# Image rootfs
image="$BASEURL/osie/images/$OS/latest-windows.tar.gz"
if is_uefi; then
	image="$BASEURL/osie/images/$OS/latest-windows-uefi.tar.gz"
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
	echo "Overriding default image location with custom image_url"
	image="$image_url"
fi
echo "Image: $image"

ensure_reachable "${image}"
if ! wget --spider "${image}"; then
	echo "$0: Image URL unavailable: $image" >&2
	exit 1
fi

echo "Devices: ${disks[*]}"

## Begin installation
##
stimer=$(date +%s)

# make sure the disks are ok to use
assert_block_or_loop_devs "${disks[@]}"
assert_same_type_devs "${disks[@]}"

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
tmpfile=/tmp/image.tar.gz
if should_stream "$image" ${tmpfile%/*}; then
	echo -e "${GREEN}#### Retrieving and extracting image archive to first disk in one shot${NC}"
	curl -sL "$image" | pv -bnti 5 | tar -zxOf- | dd bs=512k of="$install_disk"
else
	echo -e "${GREEN}#### Retrieving image archive${NC}"
	wget --quiet "$image" -O $tmpfile
	echo -e "${GREEN}#### Extracting image archive and writing to first disk${NC}"
	tar -zxf $tmpfile --to-command="dd bs=512k of=$install_disk"
fi

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
