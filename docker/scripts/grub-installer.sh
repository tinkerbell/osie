#!/bin/bash

# shellcheck disable=SC1091
source functions.sh && init
set -u

USAGE="Usage: $0 -t /mnt/target -C /path/to/cprout.json
Required Arguments:
	-p class     Server class (ex: t1.small.x86)
	-t target    Target mount point to write configs to
	-C path      Path to file containing cpr.sh output json
	-D path      Path to grub.default template
	-T path      Path to grub.cfg template

Options:
	-h           This help message
	-v           Turn on verbose messages for debugging

Description: This script will configure grub for the target distro
"
while getopts "p:t:C:D:T:hv" OPTION; do
	case $OPTION in
	p) class=$OPTARG ;;
	t) target="$OPTARG" ;;
	C) cprout=$OPTARG ;;
	D) default_path=$OPTARG ;;
	T) template_path=$OPTARG ;;
	h) echo "$USAGE" && exit 0 ;;
	v) set -x ;;
	*) echo "$USAGE" && exit 1 ;;
	esac
done

assert_all_args_consumed "$OPTIND" "$@"

# Make sure target provided is mounted
if grep -qs "$target" /proc/mounts; then
	echo "Target is mounted... good."
else
	echo "Error: Target $target is not mounted"
	exit 1
fi

rm -rf "$target/boot/grub"
[[ -d $target/boot/grub2 ]] || mkdir -p "$target/boot/grub2"
ln -nsfT grub2 "$target/boot/grub"

rootuuid=$(jq -r .rootuuid "$cprout")
[[ -n $rootuuid ]]
sed "s/PACKET_ROOT_UUID/$rootuuid/g" "$template_path" >"$target/boot/grub2/grub.cfg"

cmdline=$(sed -nr 's|GRUB_CMDLINE_LINUX='\''(.*)'\''|\1|p' "$default_path")
echo -e "${BYELLOW}Detected cmdline: ${cmdline}${NC}"
(
	sed -i 's|^|export |' "$default_path"
	# shellcheck disable=SC1090
	# shellcheck disable=SC1091
	source "$default_path"
	GRUB_DISTRIBUTOR=$(detect_os "$target" | awk '{print $1}') envsubst <"$default_path" >"$target/etc/default/grub"
)

is_uefi && uefi=true || uefi=false
arch=$(uname -m)
os_ver=$(detect_os "$target")

# shellcheck disable=SC2086
set -- $os_ver
DOS=$1
DVER=$2
echo "#### Detected OS on mounted target $target"
echo "OS: $DOS  ARCH: $arch VER: $DVER"

install_grub_chroot() {
	local disk=$1 target=$2 uefi=$3 arch=$4 class=$5 os=$6

	echo "Attempting to install Grub on $disk"
	for d in dev etc/resolv.conf proc sys tmp; do
		mount --bind /$d "$target/$d"
	done

	didmount=false
	if "$uefi"; then
		if ! mountpoint -q "$target/sys/firmware/efi/efivars"; then
			didmount=true
			mount -t efivarfs efivarfs "$target/sys/firmware/efi/efivars"
		fi
		if [[ $arch == aarch64 ]]; then
			#TODO(mmlb) add comment about why, get info from git commit and/or jira
			#gist: some of our aarch64 firmwares will fail to boot if efivars is updated
			# we can't unmount because then grub and/or efibootmgr complains and errors
			# but we can mount ro and efibootmgr will complain about ro but not error exit
			mount -o remount,ro "$target/sys/firmware/efi/efivars"
		fi
	fi

	install -Dm700 target-files/bin/packet-post-install.sh "$target/bin/packet-post-install.sh"

	chroot "$target" /bin/bash <<-EOF
		$(declare -f install_grub)
		set -euxo pipefail
		mount
		install_grub "$disk" "$uefi" "$arch" "$class" "$os"

	EOF
	if $didmount; then
		umount /sys/firmware/efi/efivars
	fi
	umount "$target"/{dev,tmp,proc}
	#umount "$target/sys"
}

install_grub() (
	#shellcheck disable=SC2030
	local disk=$1 uefi=$2 arch=$3 class=$4 os=$5

	if which grub2-install &>/dev/null; then
		grub=grub2
	elif which grub-install &>/dev/null; then
		grub=grub
	else
		echo 'grub-install or grub2-install are not installed on target os'
		exit 1
	fi

	echo "Running grub-install on $disk"
	if ! $uefi; then
		# target=/
		#$grub-install --recheck --root-directory="$target" "$disk"
		$grub-install --recheck "$disk"
		return
	fi

	echo "os=$os"
	sudo dnf reinstall -y shim-* grub2-*
	efibootmgr --create --disk /dev/vda --part 1 --loader /EFI/centos/grubia32.efi --label CentOS Boot Loader --verbose

	# target=/
	#$grub-install --recheck --bootloader-id=ubuntu --root-directory="$target" --efi-directory="$target/boot/efi"
	#$grub-install --recheck --target=x86_64-efi --bootloader-id=centos --efi-directory=/boot/efi

	grubefi=$(find /boot/efi -name 'grub*.efi' -print -quit)
	if [[ -z ${grubefi:-} ]]; then
		echo "error: couldn't find a suitable grub EFI file"
		exit 1
	fi
	install -Dm755 "$grubefi" /boot/efi/EFI/BOOT/BOOTX64.EFI

	$grub-mkconfig -o /boot/efi/EFI/centos/grub.cfg

	if [[ $arch == aarch64 ]]; then
		echo "Renaming $grubefi to default BOOT binary"
		install -Dm755 "$grubefi" /boot/efi/EFI/BOOT/BOOTAA64.EFI
		install -Dm755 "$grubefi" /boot/efi/EFI/GRUB2/GRUBAA64.EFI
	fi

	ID=$os
	if [[ -f /etc/os-release ]]; then
		source /etc/os-release
	fi
	# grub-install doesn't error if efibootmgr can't actually set the boot entries/order so lets check it
	efibootmgr | tee /dev/stderr | grep -iq "$ID"

	if [[ $class == "c3.medium.x86" ]] && [[ $os == "CentOS" ]]; then
		cat >"/etc/systemd/system/packet-post-install.service" <<-EOF
			[Unit]
			Description=Packet post install setup
			After=multi-user.target
			[Service]
			Type=oneshot
			ExecStart=/bin/packet-post-install.sh
			[Install]
			WantedBy=multi-user.target
		EOF
		ln -s /etc/systemd/system/packet-post-install.service /etc/systemd/system/multi-user.target.wants/packet-post-install.service

		efi_uuid=$(findmnt -n --target /boot/efi -o partuuid)
		efi_id=$(efibootmgr -v | grep "$efi_uuid" | sed 's/^Boot\([0-9a-f]\{4\}\).*/\1/gI;t;d')

		echo "Forcing next boot to be target os"
		efibootmgr -n "$efi_id"
	else
		rm -f /bin/packet-post-install.sh
	fi
)

# shellcheck disable=SC2207
bootdevs=$(jq -r '.bootdevs[]' "$cprout")
[[ -n $bootdevs ]]
for disk in $bootdevs; do
	#shellcheck disable=SC2031
	install_grub_chroot "$disk" "$target" "$uefi" "$arch" "$class" "$DOS"
done
