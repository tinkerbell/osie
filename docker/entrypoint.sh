#!/usr/bin/env bash

set -o errexit -o pipefail -o xtrace

cmd=$1
shift

# shellcheck disable=SC2010
if ! ls | grep "$(basename "$cmd")"; then
	echo "CMD is not an osie script, exec'ing now"
	exec "$cmd" "$@"
fi

if [[ -z ${RLOGHOST:-} ]]; then
	echo "$0: No tinkerbell url was provided, RLOGHOST env var is required." >&2
	exit 1
fi

if [[ -z ${container_uuid:-} ]]; then
	echo "$0: No id was provided, container_uuid env var is required." >&2
	exit 1
fi

echo "Logging to $RLOGHOST with $container_uuid"
# we tee to fd3 so that output can go out on stdout instead stderr
exec 3>&1
exec 2> >(tee /proc/self/fd/3 | logger -n "$RLOGHOST" -P 514 -t "$container_uuid")
exec 1>&2

mount | awk '/on \/dev/ {print $3}' | sort -ru
mount | awk '/on \/dev/ {print $3}' | sort -ru | while read -r mount; do
	umount "$mount" || :
done

mount | grep -s '/dev type devtmpfs' >/dev/null || mount -t devtmpfs devtmpfs /dev -orw,nosuid,mode=755
! [[ -c /dev/console ]] && mknod /dev/console c 5 1
for d in /dev/{mqueue,pts,shm}; do
	if ! [[ -d $d ]]; then
		mkdir $d
	fi
done
# This is so bash's <(...) works.
if [[ ! -L /dev/fd ]] || [[ $(readlink /dev/fd) != '/proc/self/fd' ]]; then
	rm -rf /dev/fd
	ln -s /proc/self/fd /dev/fd
fi

mount -t mqueue mqueue /dev/mqueue -orw,nosuid,nodev,noexec,relatime
mount -t devpts devpts /dev/pts -orw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=666
mount -t tmpfs shm /dev/shm -orw,nosuid,nodev,noexec,relatime,size=65536k
[[ -d /sys/firmware/efi ]] && mount -t efivarfs efivarfs /sys/firmware/efi/efivars

udevadm trigger # doesn't really do anything I think
udevadm settle

exec "$cmd" "$@"
