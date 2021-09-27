#!/bin/sh

# shellcheck disable=SC2039
set -o errexit -o nounset -o pipefail -o xtrace

[[ $(uname -m) == aarch64 ]] && echo "aarch64 isn't _really_ tested/supported yet" && exit 1

build_initramfs() {
	# Asrockrack kernel module
	cat >/etc/mkinitfs/features.d/asrockrack.modules <<-EOF
		extra/asrdev.ko
	EOF

	# Eclypsium driver and supporting modules (IPMI)
	cat >/etc/mkinitfs/features.d/eclypsium.modules <<-EOF
		extra/eclypsiumdriver.ko
		kernel/drivers/char/ipmi/*.ko
	EOF

	cat >/etc/mkinitfs/features.d/network.modules <<-EOF
		kernel/drivers/net/ethernet
		kernel/net/packet/af_packet.ko
	EOF

	cat >/etc/mkinitfs/features.d/packetrepo.files <<-EOF
		/etc/apk/cache/*
		/etc/apk/repos/*
	EOF

	cat <<-EOF | sort -u >/etc/mkinitfs/features.d/virtio.modules.tmp
		$(cat /etc/mkinitfs/features.d/virtio.modules)
		kernel/drivers/char/hw_random/virtio-rng.ko
	EOF
	mv /etc/mkinitfs/features.d/virtio.modules.tmp /etc/mkinitfs/features.d/virtio.modules

	# Make initramfs with features we think are spiffy
	# shellcheck disable=SC2016
	echo 'features="asrockrack base eclypsium ext2 ext3 ext4 keymap network packetrepo squashfs virtio"' >/etc/mkinitfs/mkinitfs.conf
	kver=$(basename /lib/modules/*)
	mkinitfs -l "$kver"
	mkinitfs -o /assets/initramfs "$kver"
	chmod a+r /assets/initramfs
}

build_modloop() {
	mkdir -p modloop/
	cp -a /lib/modules/ modloop/
	cp -a /lib/firmware/ modloop/modules
	mksquashfs modloop/ /assets/modloop -b 1048576 -comp xz -Xdict-size 100% -noappend
}

build_vmlinuz() {
	cp "/boot/vmlinuz-$FLAVOR" /assets/vmlinuz
}

case $1 in
vmlinuz) build_vmlinuz ;;
initramfs) build_initramfs ;;
modloop) build_modloop ;;
*) echo "unknown argument: $1" >&2 && exit 1 ;;
esac
