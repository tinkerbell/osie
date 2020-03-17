#!/bin/bash

LOG() {
	logger -s -t packet-post-install "$@"
}

efi_device() {
	findmnt -n --target /boot/efi "$@"
}

find_uuid_boot_id() {
	efibootmgr -v | grep "$1" | sed 's/^Boot\([0-9a-f]\{4\}\).*/\1/gI;t;d'
}

efi_boot_ids() {
	efibootmgr | sed 's/^Boot\([0-9a-f]\{4\}\).*/\1/gI;t;d'
}

efi_boot_order() {
	efibootmgr | sed 's/^BootOrder:\s\+\(\([0-9a-f]\{4\},\?\)\+\)$/\1/gI;t;d'
}

efi_boot_order_has_id() {
	efi_boot_order | grep "$1" >/dev/null
}

efi_first_boot_id_is() {
	efi_boot_order | grep "^$1" >/dev/null
}

cleanup() {
	unlink /etc/systemd/system/multi-user.target.wants/packet-post-install.service
	rm /etc/systemd/system/packet-post-install.service
	rm /bin/packet-post-install.sh
}

fix_boot_order() {
	LOG "Fixing efi boot order"
	efi_uuid="$(efi_device -o partuuid)"
	[ -z "$efi_uuid" ] && {
		LOG "No partition found for /boot/efi. Skipping efi boot fix."
		return
	}
	LOG "Found efi partition '$efi_uuid'"
	boot_id="$(find_uuid_boot_id "$efi_uuid")"
	[ -z "$boot_id" ] && {
		LOG "Unable to locate efi partition uuid in efibootmgr output"
		return 1
	}
	LOG "Found efi boot id '$boot_id'"
	boot_order=""
	if efi_boot_order_has_id "$boot_id"; then
		LOG "Boot id '$boot_id' already in boot order '$(efi_boot_order)'"
		if ! efi_first_boot_id_is "$boot_id"; then
			LOG "Boot id '$boot_id' is not the first boot option. Reordering..."
			boot_order="$boot_id,$(efi_boot_order | sed "s/,\?$boot_id//")"
		fi
	else
		LOG "Boot id '$boot_id' not in current boot order, adding..."
		boot_order="$boot_id,$(efi_boot_order)"
	fi
	if [ -n "$boot_order" ]; then
		LOG "Updating boot order to '$boot_order'"
		efibootmgr -o "$boot_order"
	else
		LOG "No changes needed to be made to efi boot order"
	fi
}

main() {
	fix_boot_order || LOG "Failed to correct EFI boot order"
	cleanup
}

main
