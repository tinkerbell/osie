#!/bin/bash

case $(uname -m) in
aarch64) grub_efi_arch=arm64 ;;
x86_64) grub_efi_arch=amd64 ;;
*) echo "unknown arch" && exit 1 ;;
esac

# pin grub to last known (but buggy!) versions
cat >/etc/apt/preferences <<-EOF
	Package: grub2
	Pin: version 2.02~beta2-36ubuntu3.27
	Pin-Priority: 999

	Package: grub2-common
	Pin: version 2.02~beta2-36ubuntu3.27
	Pin-Priority: 999

	Package: grub-common
	Pin: version 2.02~beta2-36ubuntu3.27
	Pin-Priority: 999

	Package: grub-efi-$grub_efi_arch
	Pin: version 2.02~beta2-36ubuntu3.27
	Pin-Priority: 999

	Package: grub-efi-$grub_efi_arch-bin
	Pin: version 2.02~beta2-36ubuntu3.27
	Pin-Priority: 999

	Package: grub-pc-bin
	Pin: version 2.02~beta2-36ubuntu3.27
	Pin-Priority: 999
EOF

# shellcheck disable=SC2206
packages=(
	binutils
	curl
	dmidecode
	dosfstools
	efibootmgr
	ethtool
	file
	gdisk
	git
	grub-efi-$grub_efi_arch-bin
	grub2-common
	hdparm
	inetutils-ping
	ipmitool
	iproute2
	jq
	mdadm
	parted
	pciutils
	pv
	python3
	sg3-utils
	s3cmd
	unzip
	vim
	wget
	xmlstarlet
)
echo "${packages[@]}"

[[ $(uname -m) == 'x86_64' ]] && echo 'grub-pc-bin'
