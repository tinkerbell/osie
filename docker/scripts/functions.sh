#!/usr/bin/env bash

function init() {
	# Color codes
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[0;33m'
	BLUE='\033[0;34m'
	MAGENTA='\033[0;35m'
	CYAN='\033[0;36m'
	WHITE='\033[0;37m'
	BYELLOW='\033[0;33;5;7m'
	NC='\033[0m' # No Color

	set -o errexit -o pipefail -o xtrace
}

function rainbow() {
	echo -e "$RED:RED"
	echo -e "$GREEN:GREEN"
	echo -e "$YELLOW:YELLOW"
	echo -e "$BLUE:BLUE"
	echo -e "$MAGENTA:MAGENTA"
	echo -e "$CYAN:CYAN"
	echo -e "$WHITE:WHITE"
	echo -e "$BYELLOW:BYELLOW"
	echo -e "$NC:NC"
}

# user-friendly display of OSIE errors
function print_error_summary() {
	set +x
	local stage=$1

	echo -e "\n************ OSIE ERROR SUMMARY ************"
	echo -e "Reason: Error during ${stage}"
	echo -e "OSIE Version: ${OSIE_VERSION} (${OSIE_BRANCH})"
	echo -e "Drone Build: ${DRONE_BUILD}"
	echo -e "********************************************\n"
}

function set_autofail_stage() {
	local stage=$1

	# shellcheck disable=SC2034
	autofail_stage="$stage"
	echo "${stage}" >/statedir/autofail_stage
}

# syntax: phone_home 1.2.3.4 '{"this": "data"}'
function phone_home() {
	local tink_host=$1
	shift

	puttink "${tink_host}" phone-home "$@"
}

# syntax: problem 1.2.3.4 '{"problem":"something is wrong"}'
function problem() {
	local tink_host=$1
	shift

	puttink "${tink_host}" problem "$@"
}

# syntax: fail 1.2.3.4 "reason"
function fail() {
	local tink_host=$1
	shift

	puttink "${tink_host}" phone-home '{"type":"failure", "reason":"'"$1"'"}'
}

# syntax: tink POST 1.2.3.4 phone-home '{"this": "data"}'
function tink() {
	local method=$1 tink_host=$2 endpoint=$3 post_data=$4

	curl \
		-vvvvv \
		--data "${post_data}" \
		--fail \
		--header "Content-Type: application/json" \
		--request "${method}" \
		--retry 3 \
		"${tink_host}/${endpoint}"
}

# syntax: puttink 1.2.3.4 phone-home '{"this": "data"}'
function puttink() {
	local tink_host=$1 endpoint=$2 post_data=$3

	tink "PUT" "${tink_host}" "${endpoint}" "${post_data}"
}

# syntax: posttink 1.2.3.4 phone-home '{"this": "data"}'
function posttink() {
	local tink_host=$1 endpoint=$2 post_data=$3

	tink "POST" "${tink_host}" "${endpoint}" "${post_data}"
}

# configures /etc/hosts so that git and git-lfs assets from GitHub and our local
# mirror are pulled through our image cache (IPN).
function configure_image_cache_dns() {
	images_ip=$(getent hosts images.packet.net | awk '{print $1}')
	cp -a /etc/hosts /etc/hosts.new
	{
		echo "$images_ip        github.com"
		echo "$images_ip        github-cloud.githubusercontent.com"
		echo "$images_ip        github-cloud.s3.amazonaws.com"
		echo "$images_ip        github-mirror.packet.net"
	} >>/etc/hosts.new
	# Note: using mv here fails (415 Unsupported Media Type) because docker sets
	# this up as a bind mount and we can't replace it.
	cp -f /etc/hosts.new /etc/hosts
	echo -n "LFS pulls via github-cloud will now resolve to image cache:"
	getent hosts github-cloud.githubusercontent.com | awk '{print $1}'
}

# returns a string of the BIOS vendor: "dell", "supermicro", or "unknown"
function detect_bios_vendor() {
	local vendor=unknown

	# Check for Dell
	if /opt/dell/srvadmin/bin/idracadm7 get BIOS.SysInformation &>/dev/null; then
		vendor="Dell"
	else
		# Check for Supermicro
		if /opt/supermicro/sum/sum -c GetDmiInfo >/dev/null; then
			vendor="Supermicro"
		fi
	fi

	echo "${vendor}"
}

# usage: detect_bios_version $vendor
# returns a string of the BIOS version or "unknown" if it can't be determined.
function detect_bios_version() {
	local vendor=$1
	local version=unknown

	if [[ ${vendor} == "Dell" ]]; then
		version=$(/opt/dell/srvadmin/bin/idracadm7 get BIOS.SysInformation 2>&1 | awk -F "=" '/^#SystemBiosVersion/ {print $2}')
	fi
	if [[ ${vendor} == "Supermicro" ]]; then
		version=$(/opt/supermicro/sum/sum -c GetDmiInfo | grep --after-context 2 "^\[BIOS Information\]" | awk -F '"' '/^Version/ {print $2}')
	fi

	echo "${version}"
}

# Downloads our latest BIOS configurations
function download_bios_configs() {
	# downloads are pulled through our image cache
	configure_image_cache_dns

	echo "Downloading latest BIOS configurations"
	curl \
		--fail \
		--retry 3 \
		https://bios-configs.platformequinix.net/bios-configs-latest.tar.gz --output bios-configs-latest.tar.gz
	curl \
		--fail \
		--retry 3 \
		https://bios-configs.platformequinix.net/bios-configs-latest.tar.gz.sha256 --output bios-configs-latest.tar.gz.sha256

	echo "Verifying BIOS configurations tarball"
	sha256sum --check bios-configs-latest.tar.gz.sha256

	echo "Extracting BIOS configurations tarball"
	tar -zxf bios-configs-latest.tar.gz
}

# usage: lookup_bios_config $plan $vendor
# returns a string of the bios configuration filename from the firmware repo
function lookup_bios_config() {
	local plan=$1
	local vendor=$2
	local configfile

	# search through the bios config manifest to extract the config filename
	if [[ ! -f "bios-configs-latest/manifest.txt" ]]; then
		echo "Error: missing BIOS config manifest file"
		return 1
	fi
	configfile=$(grep "^${plan} \+${vendor}" bios-configs-latest/manifest.txt | awk '{print $3}' || true)
	echo "${configfile}"
}

# usage: lookup_bios_config_enforcement $plan $vendor
# returns a string of the enforcement status for this BIOS config: ["enforce"|"testing"|""]
function lookup_bios_config_enforcement() {
	local plan=$1
	local vendor=$2
	local status

	# search through the bios config manifest to extract the enforcement status for this config
	if [[ ! -f "bios-configs-latest/manifest.txt" ]]; then
		echo "Error: missing BIOS config manifest file"
		return 1
	fi
	status=$(grep "^${plan} \+${vendor}" bios-configs-latest/manifest.txt | awk '{print $4}' || true)
	echo "${status}"
}

# usage: retrieve_current_bios_config $vendor
# saves the current bios config to a file named current_bios.txt
function retrieve_current_bios_config() {
	local vendor=$1

	if [[ ${vendor} == "Dell" ]]; then
		set_autofail_stage "running Dell's racadm to save current BIOS settings"
		if ! /opt/dell/srvadmin/bin/idracadm7 get -t json -f current_bios.txt >/dev/null; then
			echo "Warning: racadm command to save current BIOS config failed"
			return 1
		fi
	elif [[ ${vendor} == "Supermicro" ]]; then
		set_autofail_stage "running Supermicro's sum to save current BIOS settings"
		if ! /opt/supermicro/sum/sum -c GetCurrentBiosCfg --file current_bios.txt >/dev/null; then
			echo "Warning: sum command to save current BIOS config failed"
			return 1
		fi
	fi

	# Save a copy of the original BIOS config to /statedir in case we need to obtain
	# it for troubleshooting issues.
	if [[ -f current_bios.txt ]]; then
		cp current_bios.txt /statedir/
	fi
}

# usage: normalize_dell_bios_config_file $config_filename
# strips out irrelevant config sections to prevent meaningless diffs
function normalize_dell_bios_config_file() {
	local config_file=$1
	local config_file_normalized="${config_file}.normalized"

	if [[ ! -f ${config_file} ]]; then
		echo "Error: missing BIOS config file [${config_file}] to normalize"
		return 1
	fi

	# Delete irrelevant sections from the JSON config to normalize for diff'ing
	jq 'del(.SystemConfiguration.Comments) |
			del(.SystemConfiguration.ServiceTag) |
			del(.SystemConfiguration.TimeStamp) |
			del(.SystemConfiguration.Components[] | select(.FQDD=="NIC.Slot.3-1-1")) |
			del(.SystemConfiguration.Components[] | select(.FQDD=="NIC.Slot.3-2-1")) |
			del(.SystemConfiguration.Components[] | select(.FQDD=="BIOS.Setup.1-1").Attributes[] | select(.Name=="SetBootOrderEn")) |
			del(.SystemConfiguration.Components[] | select(.FQDD=="BIOS.Setup.1-1").Attributes[] | select(.Name=="BiosBootSeq")) |
			del(.SystemConfiguration.Components[] | select(.FQDD=="System.Embedded.1")) |
			del(.SystemConfiguration.Components[] | select(.FQDD=="LifecycleController.Embedded.1")) |
			del(.SystemConfiguration.Components[] | select(.FQDD=="iDRAC.Embedded.1"))' \
		"${config_file}" >"${config_file_normalized}"
}

# usage: normalize_supermicro_bios_config_file $config_filename
# strips out irrelevant config sections to prevent meaningless diffs
function normalize_supermicro_bios_config_file() {
	local config_file=$1
	local config_file_normalized="${config_file}.normalized"

	if [[ ! -f ${config_file} ]]; then
		echo "Error: missing BIOS config file [${config_file}] to normalize"
		return 1
	fi

	cp "${config_file}" "${config_file_normalized}"

	# File generation timestamp
	sed --in-place '/File generated at/d' "${config_file_normalized}"
	# ME firmware status
	sed --in-place '/ME Firmware Status/d' "${config_file_normalized}"
	# RAM Topology
	sed --in-place '/P[1|2] DIMM[[:alpha:]][[:digit:]]/d' "${config_file_normalized}"
	# Manufacturer specific details
	sed --in-place '/Manufacturer/d' "${config_file_normalized}"
	# Menu names are often based on removable hardware details
	sed --in-place '/Menu name/d' "${config_file_normalized}"
	# Various versions
	sed --in-place '/BIOS Version/d' "${config_file_normalized}"
	sed --in-place '/Build Date/d' "${config_file_normalized}"
	sed --in-place '/Microcode Revision/d' "${config_file_normalized}"
	sed --in-place '/Memory RC Version/d' "${config_file_normalized}"
	sed --in-place '/PCIe Code Version/d' "${config_file_normalized}"
	sed --in-place '/Firmware Version/d' "${config_file_normalized}"
	# Password-related
	sed --in-place '/Password/d' "${config_file_normalized}"
	# Hard drive model info, names and serial numbers
	sed --in-place '/sSATA/d' "${config_file_normalized}"
	sed --in-place '/HDD Name/d' "${config_file_normalized}"
	sed --in-place '/HDD Serial Number/d' "${config_file_normalized}"
	sed --in-place '/Micron/d' "${config_file_normalized}"
	sed --in-place '/Toshiba/d' "${config_file_normalized}"
	# Security erase estimated time
	sed --in-place '/Estimated Time/d' "${config_file_normalized}"
	# IBA GE Slots
	sed --in-place '/IBA GE Slot/d' "${config_file_normalized}"
	# PXE boot wait time
	sed --in-place '/PXE boot wait time/d' "${config_file_normalized}"
	# FlexBoot version differences
	sed --in-place '/FlexBoot/d' "${config_file_normalized}"
	# Boot mode select
	sed --in-place '/Option ValidIf.*Boot mode select/d' "${config_file_normalized}"
	# Boot option ordering
	sed --in-place '/Boot Option.*selectedOption/d' "${config_file_normalized}"
}

# usage: compare_bios_config_files $config_file $plan
function compare_bios_config_files() {
	local config_file=$1
	local config_file_normalized="${config_file}.normalized"
	local current_config="current_bios.txt"
	local current_config_normalized="${current_config}.normalized"
	local plan=$2

	if [[ ! -f ${config_file_normalized} || ! -f ${current_config_normalized} ]]; then
		echo "Error: missing normalized BIOS config files to perform drift detection"
		return 1
	fi

	diff --ignore-all-space --ignore-blank-lines "${config_file_normalized}" \
		"${current_config_normalized}" >bios_config_drift.diff || true

	if [[ ! -s bios_config_drift.diff ]]; then
		echo "No BIOS config drift detected (Based on plan: ${plan})"
	else
		echo "Warning: BIOS config drift detected (Based on plan: ${plan})"
		echo "*** Begin BIOS config drift report ***"
		cat bios_config_drift.diff
		echo "*** End BIOS config drift report ***"
	fi
}

# usage: apply_bios_config $vendor $config_file
function apply_bios_config() {
	local vendor=$1
	local config_file=$2

	if [[ ! -s bios_config_drift.diff ]]; then
		echo "No BIOS config drift detected, not applying new config"
		return 0
	fi

	if [[ ${vendor} == "Dell" ]]; then
		echo "Applying Dell BIOS configuration ${config_file}..."
		/opt/dell/srvadmin/bin/idracadm7 set -b Forced -f "${config_file}" -t JSON
	elif [[ ${vendor} == "Supermicro" ]]; then
		echo "Applying Supermicro BIOS configuration ${config_file}..."
		/opt/supermicro/sum/sum -c ChangeBiosCfg --skip_unknown --file "${config_file}"
	fi
}

# usage: validate_bios_config $plan $vendor
function validate_bios_config() {
	local plan=$1
	local vendor=$2
	local config_file
	local enforcement_status

	# Check for a BIOS config for this plan
	config_file=$(lookup_bios_config "${plan}" "${vendor}")

	if [[ -z $config_file ]]; then
		echo "Unable to find a bios config file for ${plan} (${vendor}) in the manifest, skipping BIOS validation"
		return 0
	fi

	if [[ ! -f "bios-configs-latest/${config_file}" ]]; then
		echo "A config file named [${config_file}] does not exist in BIOS configs tarball, skipping BIOS validation"
		return 0
	fi

	# Save current BIOS config to a local file
	if ! retrieve_current_bios_config "${vendor}"; then
		echo "Unable to retrieve the current BIOS config, skipping BIOS validation"
		return 0
	fi

	# Normalize the BIOS config files to eliminate meaningless diffs
	if [[ ${vendor} == "Dell" ]]; then
		set_autofail_stage "normalizing Dell BIOS configs for validation"
		normalize_dell_bios_config_file "bios-configs-latest/${config_file}"
		normalize_dell_bios_config_file "current_bios.txt"
	elif [[ ${vendor} == "Supermicro" ]]; then
		set_autofail_stage "normalizing Supermicro BIOS configs for validation"
		normalize_supermicro_bios_config_file "bios-configs-latest/${config_file}"
		normalize_supermicro_bios_config_file "current_bios.txt"
	fi

	# Compare config_file with local file, reporting drift if found
	set_autofail_stage "comparing current BIOS config with expected values"
	compare_bios_config_files "bios-configs-latest/${config_file}" "${plan}"

	enforcement_status=$(lookup_bios_config_enforcement "${plan}" "${vendor}")
	if [[ $enforcement_status == "enforce" ]]; then
		set_autofail_stage "applying BIOS config"
		apply_bios_config "${vendor}" "bios-configs-latest/${config_file}"
	else
		echo "BIOS config enforcment status is ${enforcement_status} for plan ${plan}, not applying config"
		return 0
	fi
}

function dns_resolvers() {
	declare -ga resolvers

	# shellcheck disable=SC2207
	resolvers=($(awk '/^nameserver/ {print $2}' /etc/resolv.conf))
	if [ ${#resolvers[@]} -eq 0 ]; then
		resolvers=("147.75.207.207" "147.75.207.208")
	fi
}

function dns_redhat() {
	local filename=$1
	shift

	for ((i = 0; i <= $((${#resolvers[*]} - 1)); i++)); do
		echo "DNS$((i + 1))=${resolvers[i]}" >>"${filename}"
	done
}

function dns_resolvconf() {
	local filename=$1
	shift

	printf 'nameserver %s\n' "${resolvers[@]}" >"${filename}"
}

function filter_bad_devs() {
	# 7 = loopback devices (can go away)
	# 251, 253, 259 = virtio disk (for qemu tests)
	# others = SCSI block disks
	grep -vE '^(7|8|6[5-9]|7[01]|12[89]|13[0-5]|25[139]):'
}

# args: device,...
# exits if args are not block or loop devices
function assert_block_or_loop_devs() {
	local baddevs
	if baddevs=$(lsblk -dnro 'MAJ:MIN' "$@" | filter_bad_devs) && [[ -n $baddevs ]]; then
		echo "$0: All devices may only be block or loop devices" >&2
		echo "$baddevs" >&2
		exit 1
	fi
}

# args: device,...
# exits if args are not of same device type
function assert_same_type_devs() {
	# shellcheck disable=SC2207
	local majors=($(lsblk -dnro 'MAJ:MIN' "$@" | awk -F: '{print $1}' | sort -u))
	if [[ ${majors[*]} =~ 7 ]] && ((${#majors[*]} > 1)); then
		echo "$0: loop back devices can't be mixed with physical devices"
		exit 1
	fi
}

# syntax: is_/loop_dev device,...
# returns 0 if true, 1 if false
function is_loop_dev() {
	loopdev=1
	if [[ $(lsblk -dnro 'MAJ:MIN' "$@") == 7:* ]]; then
		loopdev=0
	fi
	return $loopdev
}

# syntax: is_uefi,...
# returns 0 if true, 1 if false
function is_uefi() {
	[[ -d /sys/firmware/efi ]]
}

# syntax: name key
# expects metadata in stdin
# safely sets $name=$metadata[$key]
# accepts a default value as third param
function set_from_metadata() {
	local var=$1 key=$2
	local val
	val=$(jq -r "select(.$key != null) | .$key")
	if [[ -z $val ]]; then
		echo "$key is missing, empty or null" >&2
		if [[ -z $3 ]]; then
			return 1
		else
			echo "using default value $val for $key" >&2
			val=$3
		fi
	fi

	declare -g "$var=$val"
}

# syntax: argvalue name switch
# returns 0 if argvalue is not empty, 1 otherwise after printing to stderr
# the message printed to stderr will be "$0: No $name was provided, $switch is required"
function check_required_arg() {
	arg=$1
	name=$2
	switch=$3
	if [[ -n $arg ]]; then
		return 0
	fi
	echo "$0: No $name was provided, $switch is required." >&2
	return 1
}

# usage: assert_all_args_consumed OPTIND $@
# asserts that the caller did not pass in any extra arguments that are not
# handled by getopts
function assert_all_args_consumed() {
	local index=$1
	shift
	if ((index != $# + 1)); then
		echo "unexpected positional argument: OPTIND:$index args:$*" >&2
		exit 1
	fi
}

# usage: assert_num_disks hwtype num_disks
function assert_num_disks() {
	local hwtype=$1 ndisks=$2
	local -A type2disks=(
		[baremetal_0]=1
		[baremetal_1]=2
		[baremetal_1e]=1
		[baremetal_2]=6
		[baremetal_2a]=1
		[baremetal_2a2]=1
		[baremetal_2a4]=1
		[baremetal_2a5]=1
		[baremetal_2a6]=1
		[baremetal_3]=3
		[baremetal_hua]=1
		[baremetal_s]=14
	)

	((ndisks >= type2disks[hwtype]))
}

# usage: assert_storage_size hwtype blockdev...
function assert_storage_size() {
	# TODO: remove when https://github.com/shellcheck/issues/1213 is closed
	# shellcheck disable=SC2034
	local hwtype=$1
	shift
	local gig=$((1024 * 1024 * 1024))
	local -A type2storage=(
		[baremetal_0]=$((80 * gig))
		[baremetal_1]=$((2 * 120 * gig))
		[baremetal_1e]=$((240 * gig))
		[baremetal_2]=$((6 * 480 * gig))
		[baremetal_2a]=$((340 * gig))
		[baremetal_2a2]=1
		[baremetal_2a4]=1
		[baremetal_2a5]=1
		[baremetal_2a6]=1
		[baremetal_3]=$(((2 * 120 + 1600) * gig))
		[baremetal_hua]=1
		[baremetal_s]=$(((12 * 2048 + 2 * 480) * gig))
	)

	local got=0 sz=0
	for disk; do
		sz=$(blockdev --getsize64 "$disk")
		got=$((got + sz))
	done
	((got >= type2storage[hwtype]))
}

# usage: should_stream $image_url
# returns 0 if image size is unknown or larger than available space in destination
# returns 1 otherwise
function should_stream() {
	local image=$1
	local dest=$2

	available=$(BLOCKSIZE=1 df --output=avail "$dest" | grep -v Avail)
	img_size=$(curl -s -I "$image" | tr -d '\r' | awk 'tolower($0) ~ /content-length/ { print $2 }')
	max_size=$((available - (1024 * 1024 * 1024))) # be safe and allow 1G of leeway

	# img_size == 0 is if server can't stat the file, for example some
	# backend is dynamically generating the file for whatever reason
	if ((img_size == 0)) || ((img_size >= max_size)); then
		return 0
	else
		return 1
	fi
}

# rand31s returns a stream of non-negative random 31-bit integers as uint32s
rand31s() {
	od -An -td4 -w4 </dev/urandom | grep -v '^\s*-' | sed 's|^\s\+||'
}

# rand31 returns a non-negative random 31-bit integer as an uint32
rand31() {
	rand31s | head -n1
}

# rand63s returns a stream of non-negative random 63-bit integers as uint64s
rand63s() {
	od -An -td8 -w8 </dev/urandom | grep -v '^\s*-' | sed 's|^\s\+||'
}

# rand63 returns a non-negative random 63-bit integer as an uint64
rand63() {
	rand63s | head -n1
}

function get_disk_block_size_and_count() {
	local blockdevout
	blockdevout="$(blockdev --getpbsz --getsize64 "$1" | tr '\n' ' ')"
	# shellcheck disable=SC2086
	set -- $blockdevout
	local bs=$1 size=$2
	echo "$bs $((size / bs))"
}

# wipe_check_prep writes a random pattern randomly throughout the disk. It
# returns a string representation of its actions which is meant to be passed
# verbatim to wipe_check_verify
function wipe_check_prep() {
	local dev=$1

	local ret
	ret=$(get_disk_block_size_and_count "$bd")
	# shellcheck disable=SC2086
	set -- $ret
	local bs=$(($1 + 0)) blocks=$(($2 + 0)) sha0
	local lastblock=$((blocks - 1))
	sha0=$(dd if=/dev/zero bs=$bs count=1 status=none | sha1sum | awk '{print $1}')

	local -A hindexes=()
	while ((${#hindexes[@]} < 10)); do
		read -r rand
		index=$((rand % lastblock))
		hindexes[$index]=true
	done < <(rand63s)

	local indexes
	# shellcheck disable=SC2207
	indexes=($(echo "${!hindexes[@]}" | tr ' ' '\n' | sort -n))

	for i in "${indexes[@]}"; do
		base64 -w0 </dev/urandom | head -c $bs | dd of="$dev" seek="$i" bs=$bs status=none conv=notrunc
	done
	echo "$dev $bs $sha0 ${indexes[*]}"
}

# wipe_check_verify verifies that a disk was successfully wiped
function wipe_check_verify() {
	local dev=$1
	local bs=$2
	local sha0=$3
	shift 3
	for index; do
		if ! dd if="$dev" skip="$index" bs="$bs" count=1 status=none |
			sha1sum --status -c <(echo "$sha0  -"); then
			return 1
		fi
	done
}

# slow_wipe is the slowest and least preffered method to wipe a disk, it is
# meant as a fallback for when both blkdiscard and sg_unmap fail.
function slow_wipe() {
	local bd=$1

	# Clear MD superblocks
	# doesn't matter if not part of md devices, mdadm just ignores it
	# "$bd"* expands to full disk and any partitions, yay
	echo "$bd: clear any MD device info"
	mdadm --zero-superblock "$bd"*

	echo "$bd: wipefs"
	wipefs -a "$bd"

	echo "$bd: zap all partition information"
	# sgdisk will complain if corrupt partition table but still zaps everything
	sgdisk -Z "$bd" || :

	echo "$bd: create a single full disk partition"
	sgdisk -o -n 1:0:0 "$bd"

	echo "$bd: re-zapping all partition information"
	sgdisk -Z "$bd"

	local ret
	ret=$(get_disk_block_size_and_count "$bd")
	# shellcheck disable=SC2086
	set -- $ret
	local bs=$(($1 + 0)) blocks=$(($2 + 0))

	echo "$bd: slow wipe using dd"
	# ensure main partition table is wiped
	dd if=/dev/zero of="$bd" bs=$bs count=4096 conv=notrunc status=none
	# now the backup
	dd if=/dev/zero of="$bd" bs=$bs count=4096 seek=$((blocks - 4096)) conv=notrunc status=none

	local slice slices=64
	local chunksize=$((blocks / slices))
	local count=$((256 * 1024 * 1024 / bs)) # delete 256MB of data per chunk
	for slice in $(seq $slices); do
		echo "$slice/$slices"
		dd if=/dev/zero of="$bd" bs=$bs count=$count seek=$(((slice - 1) * chunksize)) status=none
	done
}

# wipe will try it's hardest to wipe a disk of data, successively trying
# `blkdiscard`, `sg_unmap`, and `slow_wipe`. It verifies that random data in
# random locations were zeroed by `blkdiscard` or `sg_unmap`.
function wipe() {
	local disk=$1

	local wipe_check_state
	wipe_check_state=$(wipe_check_prep "$disk")
	# shellcheck disable=SC2086
	blkdiscard "$disk" && wipe_check_verify $wipe_check_state && return
	echo "$disk: blkdiscard failed, trying sg_unmap"

	local last_lba
	last_lba=$(sg_readcap "$disk" |
		awk '/Last logical block address/ {split($4, b, "="); print b[2]}' || :)

	# shellcheck disable=SC2086
	sg_unmap --lba=0 --num="$last_lba" "$disk" && wipe_check_verify $wipe_check_state && return

	echo "$disk: sg_unmap failed, wiping using separate tools"
	slow_wipe "$disk"
}

# fast_wipe will 'clear' data in the fastest possible manner
# This is not a secure wipe and should not be used when data security is required
function fast_wipe() {
	local disk=$1
	{
		blkdiscard "$disk" || :          # I think can sometimes fails
		sgdisk -Z "$disk"                # should never fail
		mdadm --zero-superblock "$disk"* # doesn't fail even if non found
	} >&2
}

# marvell_reset uses mvcli to reset the raid card to JBODs
# usage: megaraid_reset disk...
function marvell_reset() {
	# dmidecode prints error messages on stdout!!!!
	systemmfg=$(dmidecode -s system-manufacturer | head -1)
	echo "Marvell hardware raid device is present on system mfg: $systemmfg"

	echo "Marvell-MVCLI - Deleting all VDs"
	vds=$(mvcli info -o vd | awk '/id:/ {print $2}')
	for vd in $vds; do
		echo "Marvell-MVCLI - Deleting VD id:$vd"
		echo y | mvcli delete -f -o vd -i "$vd"
	done
}

# perc_reset uses perccli to reset the raid card to JBODs
# usage: perc_reset disk...
function perc_reset() {
	# dmidecode prints error messages on stdout!!!!
	systemmfg=$(dmidecode -s system-manufacturer | head -1)
	percmodel=$(perccli64 show all | grep PERC | awk '{print $2}')
	echo "Dell PERC hardware raid device is present on system mfg: $systemmfg"

	#Query controller for drive state smart alert info
	#NOTE: disks in JBOD do not appear as Online or GOOD. Show all slot info for err state
	if perccli64 /call/eall/sall show all | grep "S.M.A.R.T alert flagged by drive" | grep No >/dev/null; then
		echo "PERCCLI - Controller drive state - OK"
	else
		echo "PERCCLI - Controller drive state has problem with SMART data alert! FAIL"
		exit 1
	fi

	#Check/set personality
	if perccli64 /c0 show personality | grep "Current Personality" | grep "HBA-Mode" >/dev/null; then
		echo "PERCCLI - Controller in HBA-Mode - OK"
	elif [[ $percmodel == 'PERCH710PMini' || $percmodel == 'PERCH740PMini' ]]; then
		echo "PERCCLI - Skipping set HBA-Mode. This $percmodel does not support HBA mode"
	else
		echo "PERCCLI - Setting personality to HBA-Mode"
		perccli64 /c0 set personality=HBA
	fi

	#Check/delete all VDs!
	if perccli64 /c0 /vall show | grep "No VDs" >/dev/null; then
		echo "PERCCLI - No VDs configured - OK"
	else
		echo "PERCCLI - Deleting all VDs"
		#This also resets all other configs as well per Dell
		perccli64 /c0 /vall delete force
	fi

	#Check for jbod and enable if needed
	if perccli64 /c0 show jbod | grep "JBOD      ON" >/dev/null; then
		echo "PERCCLI - JBOD is on - OK"
	elif [[ $percmodel == 'PERCH710PMini' || $percmodel == 'PERCH740PMini' ]]; then
		echo "PERCCLI - Skipping set JBOD since $percmodel does not support it"
	else
		echo "PERCCLI - Enable JBOD"
		perccli64 /c0 set jbod=on force
	fi

	if [[ $percmodel == 'PERCH710PMini' || $percmodel == 'PERCH740PMini' ]]; then
		percdisk=$(perccli64 /call/eall/sall show all | grep "[0-9]:[0-9]" | awk '{print $1}' | head -1)
		echo "PERCCLI - Creating RAID0 HW RAID on $percmodel"
		perccli64 /c0 add vd r0 name=RAID0 drives="$percdisk"
		sleep 5
	fi
}

function smartarray_reset() {
	systemmfg=$(dmidecode -s system-manufacturer | head -1)
	echo "Adaptec hardware RAID device is present on system mfg: $systemmfg"

	slots=$(ssacli ctrl all show detail | awk '/^   Slot: / {print $2}')

	echo "Adaptec smart storage array, clearing logical drives"
	for slot in $slots; do
		if ssacli controller slot="$slot" logicaldrive all show status >/dev/null; then
			echo "Clearing logical drives for slot $slot"
			ssacli controller slot="$slot" logicaldrive all delete forced
		else
			echo "Controller slot $slot has no logical drives, skipping"
		fi
	done
}

# megaraid_reset uses MegaCli64 to reset the raid card to JBODs
# usage: megaraid_reset disk...
function megaraid_reset() {
	# dmidecode prints error messages on stdout!!!!
	systemmfg=$(dmidecode -s system-manufacturer | head -1)
	echo "LSI hardware raid device is present on system mfg: $systemmfg"

	enc=$(MegaCli64 -EncInfo -a0 | awk '/Device ID/ {print $4}')
	slots=$(MegaCli64 -PDList -a0 | awk '/^Slot Number/ {print $3}')

	echo "LSI-MegaCLI - Disabling battery warning at boot"
	MegaCli64 -AdpSetProp BatWarnDsbl 1 -a0

	echo "LSI-MegaCLI - Marking physical devices on adapter 0 as 'Good'"
	for slot in $slots; do
		info=$(MegaCli64 -PDInfo -PhysDrv "[$enc:$slot]" -a0 | sed -n '/^Firmware state: / s|Firmware state: ||p')
		! [[ $info =~ bad ]] && continue
		MegaCli64 -PDMakeGood -PhysDrv "[$enc:$slot]" -Force -a0
	done

	echo "LSI-MegaCLI - Clearing controller of any foreign configs"
	MegaCli64 -CfgForeign -Clear -a0

	echo "LSI-MegaCLI - Clearing controller config to defaults"
	MegaCli64 -CfgClr -a0

	echo "LSI-MegaCLI - Deleting all LDs"
	MegaCli64 -CfgLdDel -LALL -a0

	echo "LSI-MegaCLI - Configuring controller as JBOD"
	MegaCli64 -AdpSetProp -EnableJBOD -0 -a0
	MegaCli64 -AdpSetProp -EnableJBOD -1 -a0
	for slot in $slots; do
		info=$(MegaCli64 -PDInfo -PhysDrv "[$enc:$slot]" -a0 | sed -n '/^Firmware state: / s|Firmware state: ||p')
		[[ $info =~ JBOD ]] && continue
		MegaCli64 -PDMakeJBOD -PhysDrv "[$enc:$slot]" -a0
	done

	if ! [[ $systemmfg =~ Dell ]]; then
		MegaCli64 -AdpSetProp -EnableJBOD -0 -a0
		echo "Creating pseudo JBOD config on the controller"
		echo "LSI-MegaCLI - Creating JBOD with single disk raid0 arrays"
		MegaCli64 -CfgEachDskRaid0 WT RA Direct NoCachedBadBBU -a0
	fi

	sleep 5
	udevadm settle
}

# detect_os detects the target os by first calling `lsb_release` in the rootdir
# via `chroot`, falling back to using the patched lsb_release bash script
# embedded in osie.
# usage: detect_os $rootdir
# returns 2 strings: os version
function detect_os() {
	local rootdir os version
	rootdir=$1

	os=$(chroot "$rootdir" lsb_release -si | sed 's/ //g' || :)
	version=$(chroot "$rootdir" lsb_release -sr || :)
	[[ -n $os ]] && [[ -n $version ]] && echo "$os $version" && return

	os=$(ROOTDIR=$rootdir ./packet_lsb_release -si)
	version=$(ROOTDIR=$rootdir ./packet_lsb_release -sr)
	echo "$os $version"
}

# use xmlstarlet to find the value of a specific matched element (or attribute)
function xml_ev() {
	local _xml="${1}" _match="${2}" _value="${3}"

	(echo "${_xml}" | xmlstarlet sel -t -m "${_match}" -v "${_value}") || echo ""
}

# use xmlstarlet to select a specific XML element and all elements contained within
function xml_elem() {
	local _xml="${1}" _match="${2}"

	echo "${_xml}" | xmlstarlet sel -t -c "${_match}"
}

# convert a bash associative array to json
function bash_aa_to_json() {
	local _json=""
	eval "local -A _f_array=""${1#*=}"

	# shellcheck disable=SC2154
	for k in "${!_f_array[@]}"; do
		if [ "${_json}" = "" ]; then
			_json="\"${k}\": \"${_f_array[k]}\""
		else
			_json="${_json}, \"${k}\": \"${_f_array[k]}\""
		fi
	done

	_json="{ ${_json} }"
	echo -n "${_json}"
}

function set_pw() {
	# TODO
	# FIXME: make sure we don't log pwhash whenever osie logging to kibana happens
	# TODO
	echo -e "${GREEN}#### Setting password${NC}"
	sed -i "s|^$1:[^:]*|$1:$2|" "$3"
	grep "^$1" "$3"
}

function vmlinuz_version() {
	local kernel=$1

	set +o pipefail
	type=$(file -b "$kernel")
	case "$type" in
	*MS-DOS*)
		echo 'kernel is type MS-DOS' >&2 # huawei devs mostly
		strings <"$kernel" | sed -n 's|^Linux version \(\S\+\).*|\1|p'
		;;
	*gzip*)
		echo 'kernel is type gzip' >&2 # 2a
		gunzip <"$kernel" | strings | sed -n 's|^Linux version \(\S\+\).*|\1|p'
		;;
	*bzImage*)
		echo 'kernel is type bzImage' >&2 # x86_64
		# shellcheck disable=SC2001
		echo "$type" | sed 's|.*, version \(\S\+\) .*|\1|'
		;;
	esac
	set -o pipefail
}

function gethost() {
	python3 -c "import urllib3;host=urllib3.util.parse_url('$1').host;assert host;print(host)" || :
}

function is_reachable() {
	local host
	host=$(gethost "$1" | sed 's|^\[\(.*\)]$||')

	if [[ $host =~ ^[.*]$ ]]; then
		echo "host is an ipv6 address, thats not supported" >&2 && exit 1
	fi

	ping -c1 -W1 "$host" &>/dev/null
}

function reacquire_dhcp() {
	dhclient -1 "$1"
}

function ensure_reachable() {
	local url=$1

	echo -e "${YELLOW}###### Checking connectivity to \"$url\"...${NC}"
	if ! is_reachable "$url"; then
		echo -e "${YELLOW}###### Failed${NC}"
		echo -e "${YELLOW}###### Reacquiring dhcp for publicly routable ip...${NC}"
		reacquire_dhcp "$(ip_choose_if)"
		echo -e "${YELLOW}###### OK${NC}"
	fi
	echo -e "${YELLOW}###### Verifying connectivity to custom url host...${NC}"
	is_reachable "$url"
	echo -e "${YELLOW}###### OK${NC}"
}

# Check that our git-lfs mirror server is working
function github_mirror_check() {
	echo -e "${YELLOW}###### Checking the health of github-mirror.packet.net...${NC}"

	# Clone the repo, and checkout an LFS branch.
	local timeout=60 # seconds
	local lfs_testing_uri="https://github-mirror.packet.net/packethost/lfs-testing.git"
	local lfs_testing_branch="remotes/origin/images-tiny"
	if ! timeout --preserve-status $timeout git clone -q $lfs_testing_uri; then
		echo -e "${YELLOW}###### Timeout when cloning the lfs-testing repo${NC}"
		echo -e "${YELLOW}###### Reacquiring dhcp for publicly routable ip...${NC}"
		reacquire_dhcp "$(ip_choose_if)"
		echo -e "${YELLOW}###### Re-checking the health of github-mirror.packet.net...${NC}"
		if ! timeout --preserve-status $timeout git clone -q $lfs_testing_uri; then
			echo -e "${YELLOW}###### Timeout when cloning the lfs-testing repo${NC}"
			return 1
		fi
		echo -e "${GREEN}###### Second clone attempt of lfs-testing successful${NC}"
	fi
	cd lfs-testing
	if ! timeout --preserve-status $timeout git checkout -q $lfs_testing_branch; then
		cd .. && rm -rf lfs-testing
		echo -e "${YELLOW}###### Timeout when checking out git-lfs data from lfs-testing${NC}"
		return 1
	fi
	checksum=$(sha256sum tiny/tiny.img | awk '{ print $1 }')
	cd .. && rm -rf lfs-testing

	local valid_checksum="7b331c02e313c7599d5a90212e17e6d3cb729bd2e1c9b873c302a63c95a2f9bf"
	if [[ $checksum != "$valid_checksum" ]]; then
		echo -e "${YELLOW}###### Test git-lfs checkout from github-mirror had a bad checksum${NC}"
		return 1
	fi
}

# determine the default interface to use if ip=dhcp is set
# uses "PACKET_BOOTDEV_MAC" kopt value if it exists
# if none, will use the first "eth" interface that has a carrier link
# falls back to the first "eth" interface alphabetically
# keep sync'ed with installer/alpine/init-*64
# shellcheck disable=SC2019
# shellcheck disable=SC2018
ip_choose_if() {
	local mac
	mac=$(echo "${PACKET_BOOTDEV_MAC:-}" | tr 'A-Z' 'a-z')
	if [ -n "$mac" ]; then
		for x in /sys/class/net/eth*; do
			[ -e "$x" ] && grep -q "$mac" "$x/address" && echo "${x##*/}" && return
		done
	fi

	for x in /sys/class/net/eth*; do
		[ -e "$x" ] && ip link set "${x##*/}" up
	done

	sleep 1

	for x in /sys/class/net/eth*; do
		[ -e "$x/carrier" ] && grep -q 1 "$x/carrier" && echo "${x##*/}" && return
		[ -e "$x" ] && grep -q 1 "$x" && echo "${x##*/}" && return
	done

	for x in /sys/class/net/eth*; do
		[ -e "$x" ] && echo "${x##*/}" && return
	done
}
