#!/usr/bin/env bash

cd "$(realpath "$(dirname "$0")")"

oneTimeSetUp() {
	source ../scripts/functions.sh
}

declare -g test_set_from_metadata_var
test_set_from_metadata() {
	i=$RANDOM$RANDOM
	j='{"t":true,"f":false,"n":null,"i":'"$i"',"s":"this_is_a_test"}'
	while read -r key want; do
		set_from_metadata test_set_from_metadata_var "$key" <<<"$j"
		assertEquals "unexpected response" "$want" "$test_set_from_metadata_var"
	done <<-EOF
		t true
		f false
		i $i
		s this_is_a_test
	EOF

	unset test_set_from_metadata_var
	assertNull 'unset test_set_from_metadata_var' "$test_set_from_metadata_var"
	set_from_metadata test_set_from_metadata_var t <<<"$j"
	assertEquals 'verify test_set_from_metadata_var is not unglobaled' true "$test_set_from_metadata_var"
	unset test_set_from_metadata_var
	assertNull 'unset test_set_from_metadata_var' "$test_set_from_metadata_var"
	set_from_metadata test_set_from_metadata_var should_not_exist true <<<"$j"
	assertEquals 'verify test_set_from_metadata_var is defaulted' true "$test_set_from_metadata_var"

	unset test_set_from_metadata_var
	while read -r key; do
		set_from_metadata test_set_from_metadata_var "$key" <<<"$j" 2>/dev/null || :
		assertNull "unexpected response for $key, got:$test_set_from_metadata_var" "$test_set_from_metadata_var"
	done <<-EOF
		n
		non_existent_key_$RANDOM
	EOF
}

test_gethost() {
	while read -r want url; do
		assertEquals "$want" "$want" "$(gethost "$url")"
	done <<-EOF
		images.packet.net https://images.packet.net/packethost/packet-images.git
		google.com https://google.com:443/something
		g[oo]gle.com https://g[oo]gle.com:443/something
		127.0.0.1 https://127.0.0.1:443/something
		[::1] https://[::1]:443/something
	EOF
	while read -r url; do
		got=$(gethost "$url" 2>/dev/null)
		assertNull "unexpected result for $url: $got" "$got"
	done <<-EOF
		/tmp/assets/x86_64/latest-freebsd.raw.gz
		https://g[oo]gle::1.com:443/something
	EOF
}

test_is_reachable() {
	host=localhost
	assertTrue "$host should be pingable" "is_reachable $host"

	host=not-localhost-$RANDOM$RANDOM.lan
	assertFalse "$host should *not* be pingable" "is_reachable $host"
}

copy_function() {
	test -n "$(declare -f "$1" | tail -n +2)" || return
	eval "$2 () $_"
}

test_ensure_reachable() {
	local dev ip
	ip=$(getent ahosts gstatic.com |
		awk '/STREAM/ {print $1}' |
		grep -v : |
		shuf -n1)
	assertNotNull "$ip"
	dev=$(ip route get "$ip" | awk '/dev/ {print $5}')
	gw=$(ip route | awk '/default/ {print $3}')

	copy_function reacquire_dhcp reacquire_dhcp_orig
	reacquire_dhcp() {
		ip link set "$dev" up
		ip route add default via "$gw"
	}

	assertTrue 'gstatic should have been pingable' "is_reachable gstatic.com"
	ip link set "$dev" down
	assertFalse 'gstatic should *not* have been pingable' "is_reachable gstatic.com"

	ensure_reachable gstatic.com &>/dev/null
	assertTrue 'ensure_reachable failed' $?
	assertTrue 'gstatic should have gone back to pingable' "is_reachable gstatic.com"

	copy_function reacquire_dhcp_orig reacquire_dhcp
}

test_filter_bad_devs() {
	local devs
	devs=$(
		curl -sf https://raw.githubusercontent.com/torvalds/linux/master/Documentation/admin-guide/devices.txt |
			grep -E 'block\s*(Loopback devices|SCSI disk)' |
			awk '{print $1}'
		echo -e '251\n253\n259' # virtio disks seen in tests
	)

	local baddevs
	for dev in $devs; do
		baddevs=$(echo "$dev:0" | filter_bad_devs)
		assertNull 'unexpected baddev' "$baddevs"
	done
	for dev in $devs; do
		dev=$((dev + 100))
		baddevs=$(echo "$dev:0" | filter_bad_devs)
		assertNotNull 'expected baddevs' "$baddevs"
		[[ -n $baddevs ]] && assertEquals 'wrong baddev' $dev:0 $baddevs
	done

}

source ./shunit/shunit2
