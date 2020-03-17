#!/usr/bin/env bash

cd "$(realpath "$(dirname "$0")")"

oneTimeSetUp() {
	source ../scripts/flavor-runner.sh
}

test_positives() {
	while read -r state slug want; do
		got=$(get_script "$state" "$slug")
		assertTrue "incorrect script returned (state:$state, slug:$slug) want:$want, got:$got" "[[ $got == $want ]]"
	done <<-EOF
		deprovisioning centos_7              /home/packet/deprovision.sh
		provisioning   centos_7              /home/packet/osie.sh
		provisioning   debian_9              /home/packet/osie.sh
		provisioning   freebsd_11_1          /home/packet/frosie.sh
		provisioning   opensuse_42_3         /home/packet/osie.sh
		provisioning   rhel_7                /home/packet/osie.sh
		provisioning   scientific_6          /home/packet/osie.sh
		provisioning   suse_sles12           /home/packet/osie.sh
		provisioning   ubuntu_18_04          /home/packet/osie.sh
		provisioning   virtuozzo_7           /home/packet/vosie.sh
		provisioning   windows_2016_standard /home/packet/wosie.sh
	EOF
}

test_negatives() {
	while read -r slug; do
		got=$(get_script provisioning "$slug")
		assertFalse "did not expect a script to be returned (slug:$slug) got:$got" "[[ -z $got ]]"
	done <<-EOF
		alpine_3
		coreos_stable
		custom
		custom_ipxe
		nixos_18_03
		rancher
		vmware_esxi_6_5
	EOF
}

source ./shunit/shunit2
