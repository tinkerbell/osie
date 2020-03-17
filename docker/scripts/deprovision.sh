#!/bin/bash

source functions.sh && init
set -o nounset

# defaults
# shellcheck disable=SC2207
disks=($(lsblk -dno name -e1,7,11 | sed 's|^|/dev/|' | sort))

USAGE="Usage: $0 -M /metadata
Required Arguments:
	-M metadata  File containing instance metadata

Options:

Description: This script installs the specified OS from an image file on to one or more block devices and handles the kernel and initrd for the
underlying hardware.
"

while getopts "M:b:u:hv" OPTION; do
	echo "OPTION=$OPTION"
	case $OPTION in
	M) metadata=$OPTARG ;;
	b) BASEURL=$OPTARG ;;
	u) ;;
	h) echo "$USAGE" && exit 0 ;;
	v) set -x ;;
	*) echo "$USAGE" && exit 1 ;;
	esac
done

arch=$(uname -m)

check_required_arg "$metadata" 'metadata file' '-M'
assert_all_args_consumed "$OPTIND" "$@"

declare facility && set_from_metadata facility 'facility' <"$metadata"
declare class && set_from_metadata class 'class' <"$metadata"
declare tinkerbell && set_from_metadata tinkerbell 'phone_home_url' <"$metadata"
declare id && set_from_metadata id 'id' <"$metadata"
declare preserve_data && set_from_metadata preserve_data 'preserve_data' false <"$metadata"
declare deprovision_fast && set_from_metadata deprovision_fast 'deprovision_fast' false <"$metadata"

# shellcheck disable=SC2001
tinkerbell=$(echo "$tinkerbell" | sed 's|\(http://[^/]\+\).*|\1|')

# if $BASEURL is not empty then the user specifically passed in the artifacts
# location, we should not trample it
BASEURL=${BASEURL:-http://install.$facility.packet.net/misc}

# Pre-deprov check
echo "Number of drives found: ${#disks[*]}"
if ! assert_num_disks "$class" "${#disks[@]}"; then
	echo "critical: unexpected number of block devices! Missing drives?"
	: problem "$tinkerbell" '{"problem":"missing_drive"}'
	: read -rsp $'Press escape to continue...\n' -d $'\e'
	: exit 1
fi

if ! assert_storage_size "$class" "${disks[@]}"; then
	echo "critical: unexpected amount of available storage space! missing drives?"
	: problem "$tinkerbell" '{"problem":"missing_drive"}'
	: read -rsp $'Press escape to continue...\n' -d $'\e'
	: exit 1
fi

assert_block_or_loop_devs "${disks[@]}"
assert_same_type_devs "${disks[@]}"

stimer=$(date +%s)

if [[ $preserve_data == false ]]; then
	echo "Not preserving data."

	# Look for active MD arrays
	# shellcheck disable=SC2207
	mdarrays=($(awk '/md/ {print $4}' /proc/partitions))
	if ((${#mdarrays[*]} != 0)); then
		for mdarray in "${mdarrays[@]}"; do
			echo "MD array: $mdarray"
			mdadm --stop "/dev/$mdarray"
			# sometimes --remove fails, according to manpages seems we
			# don't need it / are doing it wrong
			mdadm --remove "/dev/$mdarray" || :
		done
	else
		echo "No MD arrays found. Skipping RAID md shutdown"
	fi

	# Reset nvme namespaces
	# shellcheck disable=SC2207
	nvme_drives=($(find /dev -regex ".*/nvme[0-9]+" | sort -h))
	echo "Found ${#nvme_drives[@]} nvme drives"
	nvme list
	if ((${#nvme_drives[@]} > 0)); then
		for drive in "${nvme_drives[@]}"; do
			nvme id-ctrl "$drive"
			caps=$(nvme id-ctrl "$drive" -o json | jq -r '.oacs')
			if (((caps & 0x8) == 0)); then
				echo "Nvme drive $drive has no management capabilities, skipping..."
				continue
			fi

			max_bytes=$(nvme id-ctrl "$drive" -o json | jq -r '.tnvmcap')
			# shellcheck disable=SC2207
			namespaces=($(nvme list-ns "$drive" -a | cut -d : -f 2))
			echo "Found ${#namespaces[@]} namespaces on $drive"
			if ((${#namespaces[@]} > 0)); then
				for ns in "${namespaces[@]}"; do
					echo "Deleting namespace $ns from $drive"
					nvme delete-ns "$drive" -n "$ns"
				done
			fi

			# flbas 0 uses 512 byte sector sizes
			sectors=$((max_bytes / 512))
			echo "Creating a single namespace with $sectors sectors on $drive"
			nsid=$(nvme create-ns "$drive" --nsze=$sectors --ncap=$sectors --flbas 0 --dps=0 | cut -d : -f 3)
			ctrl=$(nvme id-ctrl "$drive" | grep cntlid | cut -d : -f 2)

			echo "Attaching namespace $nsid to ctrl $ctrl on $drive"
			nvme attach-ns "$drive" -n "$nsid" -c "$ctrl"
			sleep 2

			echo "Resetting controller $drive"
			nvme reset "$drive"
			sleep 2

			echo "Rescanning namespaces on $drive"
			nvme ns-rescan "$drive"
		done
		sleep 2
		nvme list
		# Resetting namespaces could've removed some previously detected disks
		# defaults
		# shellcheck disable=SC2207
		disks=($(lsblk -dno name -e1,7,11 | sed 's|^|/dev/|' | sort))
	fi

	# LSI MegaRAID and Dell PERC series 9
	# do not do grep -q, it doesn't play well with pipefail when lots of pci devices exist
	if lspci -nn | grep -v 'SAS3008' | grep LSI >/dev/null && [[ $arch == x86_64 ]]; then
		if perccli64 show | grep -E 'PERCH710PMini|PERCH730P|PERCH740PMini' >/dev/null; then
			perc_reset "${disks[@]}"
		else
			megaraid_reset "${disks[@]}"
			# in case there were any disks not present at the beginning of the
			# script due to foreign config or being in raid mode
			# shellcheck disable=SC2207
			[[ -z ${DISKS:-} ]] && disks=($(lsblk -dno name -e1,7,11 | sed 's|^|/dev/|' | sort))
		fi
	fi

	# Marvell (Dell) BOSS-S1
	if lspci -nn | grep '88SE9230' | grep Marvell >/dev/null && [[ $arch == x86_64 ]]; then
		if [[ $class == n2.xlarge.x86 ]]; then
			echo "Skipping RAID destroy for this $class hardware..."
		else
			marvell_reset
			# in case there were any disks not present at the beginning of the
			# script due to foreign config or being in raid mode
			# shellcheck disable=SC2207
			[[ -z ${DISKS:-} ]] && disks=($(lsblk -dno name -e1,7,11 | sed 's|^|/dev/|' | sort))
		fi
	fi
else
	echo "Skipped array reset due to preserve_data: true"
fi

if [[ $deprovision_fast == false ]] && [[ $preserve_data == false ]]; then
	echo "Wiping disks"
	# Wipe the filesystem and clear block on each block device
	for bd in "${disks[@]}"; do
		(
			wipe "$bd"
			# seen some 2As with backup gpt partition still available
			sgdisk -Z "$bd"
		) &
	done

	for bd in "${disks[@]}"; do
		wait -n
	done

	echo "Disk wipe finished."
	phone_home "${tinkerbell}" '{"type":"deprovisioning.306.01","body":"Disks wiped","private":true}'
else
	echo "Disk wipe skipped."
	phone_home "${tinkerbell}" '{"type":"deprovisioning.306.01","body":"Disk wipe skipped","private":true}'
fi

if [[ -d /sys/firmware/efi ]]; then
	for bootnum in $(efibootmgr | sed -n '/^Boot[0-9A-F]/ s|Boot\([0-9A-F]\{4\}\).*|\1|p'); do
		efibootmgr -Bb "$bootnum"
	done
fi

# Call firmware script to update components and firmware
case "$class" in
baremetal_2a2 | baremetal_2a4 | baremetal_2a5 | baremetal_hua)
	echo "skipping hardware update for oddball aarch64s"
	;;
*)
	./hardware/inventory.py --verbose --tinkerbell "${tinkerbell}/hardware-components"
	./hardware/update.py --verbose --facility "${facility}"
	;;
esac

# Run eclypsium
if [[ $arch == x86_64 ]]; then
	case "$facility" in
	ssg-* | att-*)
		echo "skipping eclypsium in unsupported facility"
		;;
	*)
		case "$class" in
		disabled.plan.here)
			echo "skipping eclypsium on unsuppported plan"
			;;
		*)
			https_proxy="http://eclypsium-proxy-${facility}.packet.net:8888/" /usr/bin/EclypsiumApp \
				-s1 prod-0918.eclypsium.net placeholder \
				-disable-progress-bar \
				-medium \
				-log stderr \
				-request-timeout 30 \
				-custom-id "${id}" || echo 'EclypsiumApp Failed!'
			;;
		esac
		;;
	esac
fi

phone_home "${tinkerbell}" '{"type":"deprovisioning.306.02","body":"Deprovision finished, rebooting server","private":true}'
phone_home "${tinkerbell}" '{"instance_id": "'"$id"'"}'

## End installation
etimer=$(date +%s)
echo -e "${BYELLOW}Clean time: $((etimer - stimer))${NC}"

cat >/statedir/cleanup.sh <<EOF
#!/bin/sh
poweroff
EOF
chmod +x /statedir/cleanup.sh
