#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail -o xtrace

scriptdir="$(dirname "$(realpath "$0")")"

usage() {
	cat <<EOF
Usage: $(basename "$0") {build|test} [-h] -k kernel -i initrd -m modloop -o outfile
EOF
}

check_required_arg() {
	local arg=$1 name=$2 switch=$3
	if [ -n "$arg" ]; then
		return 0
	fi
	echo "$0: No $name was provided, $switch is required." >&2
	return 1
}

check_required_arg_file() {
	check_required_arg "$@"

	local arg=$1 name=$2
	if [ -r "$arg" ]; then
		return 0
	fi
	echo "$0: No such file $arg ($name) exists." >&2
	return 1
}

setup_bridge() {
	brctl addbr hv
	ip addr add "$subnet.1/24" dev hv
	ip link set hv up
}

teardown_bridge() {
	ip link set hv down
	brctl delbr hv
}

setup_forwarding() {
	iptables-save >/tmp/saved-iptables
	iptables -t filter -A FORWARD -i hv -o dummy0 -j ACCEPT
	iptables -t filter -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
	iptables -t nat -A POSTROUTING -o dummy0 -j MASQUERADE
	iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
}

teardown_forwarding() {
	iptables-restore </tmp/saved-iptables
}

make_disk() {
	truncate -s0 "$disk"
	truncate -s50G "$disk"
}

gen_metadata() {
	local class=$1 slug=$2 tag=$3 id=$4

	local cprcmd
	cprcmd=(cat)
	if [[ $UEFI == true ]] && [[ $arch != aarch64 ]]; then
		cprcmd=(jq -S '.filesystems += [{"mount":{"create":{"options": ["32", "-n", "EFI"]},"device":"/dev/sda1","format":"vfat","point":"/boot/efi"}}]')
	fi

	local distro=${slug%%_*} version=${slug#*_}
	version=${version//_/.}
	local hardware_id
	hardware_id=$(uuidgen)

	cat <<-EOF | sed '/\bsd[a-z]\+[0-9]*\b/ s|\bs\(d[a-z]\+[0-9]*\)\b|v\1|' | jq -S . | tee metadata
		{
		  "class": "$class",
		  "facility": "$facility",
		  "hardware_id": "$hardware_id",
		  "hostname": "dut",
		  "id": "$id",
		  "network": {
		    "addresses": [
		      {
		        "address": "$pubip4",
		        "address_family": 4,
		        "cidr": 31,
		        "gateway": "$subnet.1",
		        "management": true,
		        "netmask": "255.255.255.254",
		        "network": "$subnet.3",
		        "public": true
		      },
		      {
		        "address": "2604:1380:2:4200::5",
		        "address_family": 6,
		        "cidr": 127,
		        "gateway": "2604:1380:2:4200::4",
		        "management": true,
		        "netmask": "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe",
		        "network": "2604:1380:2:4200::4",
		        "public": true
		      },
		      {
		        "address": "10.0.0.2",
		        "address_family": 4,
		        "cidr": 31,
		        "gateway": "10.0.0.1",
		        "management": true,
		        "netmask": "255.255.255.254",
		        "network": "10.0.0.1",
		        "public": false
		      }
		    ],
		    "bonding": {
		      "link_aggregation": "individual"
		    },
		    "interfaces": [
		      {
		        "mac": "${macs[0]}",
		        "name": "dummy0"
		      },
		      {
		        "mac": "${macs[1]}",
		        "name": "dummy1"
		      }
		    ]
		  },
		  "operating_system": {
		    "distro": "$distro",
		    "image_tag": "$tag",
		    "license_activation": {
		      "state": "unlicensed"
		    },
		    "slug": "$slug",
		    "version": "$version"
		  },
		  "phone_home_url": "http://tinkerbell.$facility.packet.net",
		  "preserve_data": false,
		  "storage": $("${cprcmd[@]}"),
		  "wipe_disks": true
		}
	EOF
}

do_symlink_ro_rw() {
	local d
	d=$(mktemp -dt osie-test-rw-XXXXXX)

	cp -as "$PWD"/* "$d/"
	cd "$d"
}

start_dhcp() {
	dnsmasq --bind-interfaces --interface=hv \
		--domain-needed \
		--interface-name="install.$facility.packet.net,hv" \
		--interface-name="tinkerbell.$facility.packet.net,hv" \
		--interface-name=metadata.packet.net,hv \
		--dhcp-range "$subnet.100,$subnet.200" \
		"$@"
}

stop_dhcp() {
	killall dnsmasq
}

start_web() {
	local repo_dest
	repo_dest=$(cat "repo-$arch")

	FACILITY=$facility sh /tls/gencerts.sh

	cat >Caddyfile <<-EOF
		install.$facility.packet.net:80 {
		    browse
		    log stderr
		    tls off

		    proxy /misc/osie/current/repo-$arch install.ewr1.packet.net/alpine/$repo_dest/
		    rewrite /misc/osie/current {
		        regexp (.*)
		        to {1}
		    }
		    proxy /repo-$arch/ install.ewr1.packet.net/alpine/$repo_dest/ {
		        without /repo-$arch/
		    }
		    proxy /misc/osie install.ewr1.packet.net
		    proxy /alpine/ install.ewr1.packet.net
		}

		tinkerbell.$facility.packet.net:80 {
		    log stderr
		    tls off
		    upload / {
		        to "uploads"
		        random_suffix_len 5
		        yes_without_tls
		    }
		}

		metadata.packet.net:80 {
		    log stderr
		}

		metadata.packet.net:443 {
		    log stderr
		    tls server.pem server-key.pem
		}
	EOF

	mkdir uploads
	proxy &>proxy.log &
}

stop_web() {
	killall proxy
}

start_log_rx() {
	socat -u UDP-RECV:514 create:rx-syslog.log &
}

stop_log_rx() {
	killall socat || :
}

setup() {
	setup_bridge
	setup_forwarding

	do_symlink_ro_rw
	make_disk

	trap teardown EXIT
}

teardown() {
	set +o errexit
	stop_dhcp
	stop_web
	stop_log_rx
	teardown_bridge
	teardown_forwarding

}

# This function exec's the last binary run, this seems weird but actually works out ok.
# Bash ends up running this function in subprocesses so the exec replace run_vm's process not ci/vm.sh's
# This is needed so that run_vm callers will get qemu's pid and can kill it (otherwise bash won't forward the SIGTERM received by the function)
run_vm() {
	local cpu='' machine=''

	case $(uname -m)-$arch in
	'aarch64-aarch64') machine=virt cpu=host ;;
	'aarch64-x86_64') machine=virt cpu=qemu64 ;;
	'x86_64-aarch64') machine=virt cpu=cortex-a57 ;;
	'x86_64-x86_64') machine=pc cpu=host ;;
	*) echo 'unknown host-virt architecture combination' && exit 1 ;;
	esac

	local bios=()
	if [[ $UEFI != 'true' ]]; then
		bios=('-bios' '/usr/share/qemu/bios.bin')
	else
		if ! [[ -f "$disk.vars" ]]; then
			cp /usr/share/OVMF/OVMF_VARS.fd "$disk.vars"
		fi
		if [[ $arch == x86_64 ]]; then
			bios=(
				-drive 'if=pflash,format=raw,file=/usr/share/OVMF/OVMF_CODE.fd,readonly'
				-drive "if=pflash,format=raw,file=$disk.vars"
			)
		else
			bios=()
		fi
	fi

	local scripts=("$scriptdir/ifup.sh" "$scriptdir/ifup.sh" /bin/true /bin/true)
	local serials=()
	case $console in
	*ttyAMA0*) serials=() ;;
	*ttyS0*) serials=(-serial stdio) ;;
	*ttyS1*) serials=(-serial pty -serial stdio) ;;
	*) echo "unknown console setting" >&2 && exit 1 ;;
	esac

	# shellcheck disable=SC2068
	exec "qemu-system-$arch" \
		"$@" \
		-monitor unix:monitor.sock,server=on,wait=off \
		-nographic \
		"${serials[@]}" \
		-machine $machine,accel=kvm:tcg -cpu $cpu -smp 2 -m 8192 \
		-drive if=virtio,file="$disk",format=raw,discard=unmap \
		-object rng-random,filename=/dev/urandom,id=rng0 \
		-device virtio-rng-pci,rng=rng0 \
		${bios[@]} \
		-netdev tap,id=net0,script="${scripts[0]}",downscript=/bin/true -device "virtio-net,netdev=net0,mac=${macs[0]}" \
		-netdev tap,id=net1,script="${scripts[1]}",downscript=/bin/true -device "virtio-net,netdev=net1,mac=${macs[1]}" \
		-netdev tap,id=net2,script="${scripts[2]}",downscript=/bin/true -device "virtio-net,netdev=net2,mac=${macs[2]}" \
		-netdev tap,id=net3,script="${scripts[3]}",downscript=/bin/true -device "virtio-net,netdev=net3,mac=${macs[3]}" \
		;
}

do_test() {
	setup
	v=$(basename "$(readlink "$(readlink "repo-$arch")")")
	rm "repo-$arch"
	echo "$v" >"repo-$arch"
	start_web
	start_log_rx

	class=t1.small.x86
	if [ "$arch" = 'aarch64' ]; then
		class=c1.large.arm
	fi

	local slug=${OS%:*}
	local tag=${OS#*:}
	if [[ -z $tag ]] || [[ $OS == "$tag" ]]; then
		tag=$slug-$class
	fi

	configure_nics

	id=$(uuidgen)
	# rename disk from scsi names to virtio names, e.g. sda1 -> vda1
	gen_metadata "$class" "$slug" "$tag" "$id" <"$scriptdir/cpr/$class.cpr.json"

	start_dhcp \
		--dhcp-host="${macs[0]},$pubip4" \
		--dhcp-host="${macs[1]},ignore" \
		--dhcp-host="${macs[2]},ignore" \
		--dhcp-host="${macs[3]},ignore" \
		;

	# benign edits
	# 1. do not verify https cert for metadata.packet.net since we dont want to add real cert here
	# 2. poweroff instead of reboot after install
	sed -i \
		-e '/curl.*https:\/\/metadata.packet.net/ s|curl|curl --cacert /tmp/caddy-cert.pem|' \
		-e '/^hardware_id=/ s|^|curl http://metadata.packet.net/bundle.pem >/tmp/caddy-cert.pem\n|' \
		-e '/^\s*reboot$/ s|reboot|poweroff|' \
		-e 's|\./cleanup.sh.*|poweroff|' \
		-e 's|docker load|& -q|' \
		osie-installer.sh runner.sh

	case $arch in
	'aarch64') console=ttyAMA0,115200 ;;
	'x86_64') console=ttyS1,115200 ;;
	esac

	color=33
	colorize $color "== Running Provision Test =="
	test_provision |& stdbuf -i 0 sed "s/^/$(colorize $color 'test_provision│')/"
	rm -f uploads/*

	color=34
	colorize $color "== Running Boot & Phone-Home Test =="
	test_boot_and_phone_home |& stdbuf -i 0 sed "s/^/$(colorize $color 'test_boot_and_phone_home│')/" &&
		echo "this test is expected to fail" >&2 &&
		exit 1
	rm -f uploads/*

	color=35
	colorize $color "== Running Deprovision Test =="
	test_deprovision |& stdbuf -i 0 sed "s/^/$(colorize $color 'test_deprovision│')/"
	rm -f uploads/*
}

configure_nics() {
	# macs[0] == dhcpmac
	mapfile -t macs < <(
		shuf <<-EOF
			52:54:00:BA:DD:00
			52:54:00:BA:DD:01
			52:54:00:BA:DD:02
			52:54:00:BA:DD:03
		EOF
	)
	mapfile -t scripts < <(
		shuf <<-EOF
			$scriptdir/ifup.sh
			$scriptdir/ifup.sh
			/bin/true/bin/true)
		EOF
	)
}

function colorize() {
	local color=$1
	shift
	printf "$(tput sgr0)$(tput setaf "$color")%s$(tput sgr0)" "$*"
}

test_provision() {
	local cmdline=''
	cmdline="$cmdline console=$console"
	cmdline="$cmdline facility=$facility"
	cmdline="$cmdline ip=dhcp"
	cmdline="$cmdline modloop=http://install.$facility.packet.net/misc/osie/current/$modloop"
	cmdline="$cmdline modules=loop,squashfs,sd-mod,usb-storage"
	cmdline="$cmdline rw"
	cmdline="$cmdline tinkerbell=http://tinkerbell.$facility.packet.net"
	cmdline="$cmdline packet_action=install packet_bootdev_mac=${macs[0]} slug=$slug:$tag pwhash=$(echo 5up | mkpasswd)"
	run_vm -kernel "$kernel" -initrd "$initramfs" -append "$cmdline"

	# check for provision success code
	local eventid=provisioning.109
	grep -qr "$eventid" uploads
	local got
	got=$(grep -hr "$eventid" uploads)
	#shellcheck disable=SC2089
	local want='{"type":"provisioning.109"}'
	diff -u <(jq -cS . <<<"$want") <(jq -cS . <<<"$got")
}

test_boot_and_phone_home() {
	run_vm &
	local vmpid=$!

	local i=0
	until grep -qr instance_id uploads; do
		# timeout after 2min
		if ((i++ == 12)); then
			break
		fi
		sleep 10
	done
	echo 'system_powerdown' | socat unix-connect:monitor.sock -

	i=0
	local qpid
	# wait 2min for the vm to shutdown
	until ((i++ == 12)); do
		qpid=$(pgrep qemu || :)
		if [[ -z ${qpid:-} ]] || ((qpid != vmpid)); then
			break
		fi
		sleep 10
	done
	if ((i >= 12)); then
		kill -KILL $vmpid
		sleep 1
	fi

	# check for phone-home
	local eventid=instance_id
	grep -qr "$eventid" uploads
	local got
	got=$(grep -hr "$eventid" uploads)
	local want='{"instance_id":"'"$id"'"}'
	diff -u <(jq -cS . <<<"$want") <(jq -cS . <<<"$got")
}

test_deprovision() {
	local cmdline=''
	cmdline="$cmdline console=$console"
	cmdline="$cmdline facility=$facility"
	cmdline="$cmdline ip=dhcp"
	cmdline="$cmdline modloop=http://install.$facility.packet.net/misc/osie/current/$modloop"
	cmdline="$cmdline modules=loop,squashfs,sd-mod,usb-storage"
	cmdline="$cmdline rw"
	cmdline="$cmdline tinkerbell=http://tinkerbell.$facility.packet.net"
	cmdline="$cmdline packet_action=install packet_state=deprovisioning packet_bootdev_mac=${macs[0]} slug=deprovision"
	run_vm -kernel "$kernel" -initrd "$initramfs" -append "$cmdline"

	# check for deprovisioning finished message
	local eventid=deprovisioning.306.02
	grep -qr "$eventid" uploads
	local got
	got=$(grep -hr "$eventid" uploads)
	#shellcheck disable=SC2089
	local want='{"type":"deprovisioning.306.02","body":"Deprovision finished, rebooting server","private":true}'
	diff -u <(jq -cS . <<<"$want") <(jq -cS . <<<"$got")

	echo "Checking if disks were wiped"
	if fdisk -l "$disk" 2>/dev/null | grep Disklabel >/dev/null; then
		echo "disks were not wiped correctly!"
		fdisk -l "$disk"
		exit 2
	fi
}

get_subnet() {
	# convert subnets in use into grep -E pattern
	local pattern
	pattern=$(ip -4 addr | awk '/inet 172/ {print $2}' | sort -h | sed 's|172.\([0-9]\+\).*|\1|' | tr '\n' '|' | sed -e 's/^/^(/' -e 's/|$/)/')
	seq 0 255 | grep -vwE "$pattern" | shuf -n1 | sed 's|.*|172.&.0|'
}

n=$RANDOM
facility=test$n
disk=/tmp/test$n.img
subnet=$(get_subnet)
pubip4=$subnet.2

cmd=$1
shift

check_required_arg "$cmd" 'command' 'it'

while getopts "a:C:i:k:m:h" OPTION; do
	case $OPTION in
	a) arch=$OPTARG ;;
	C) cd "$OPTARG" ;;
	i) initramfs=$OPTARG ;;
	k) kernel=$OPTARG ;;
	m) modloop=$OPTARG ;;
	h) usage && exit 0 ;;
	*) usage && exit 1 ;;
	esac
done

case "$cmd" in
test | tests)
	check_required_arg "$arch" 'architecture' '-a'
	check_required_arg_file "$initramfs" 'initramfs' '-i'
	check_required_arg_file "$kernel" 'kernel' '-k'
	check_required_arg_file "$modloop" 'modloop' '-m'
	;;
*) echo "unknown command $cmd" >&2 && exit 1 ;;
esac

if [[ $cmd == tests ]]; then
	case $arch in
	'aarch64') OSES=${OSES:-centos_7 ubuntu_16_04 ubuntu_17_04} ;;
	'x86_64') OSES=${OSES:-centos_7 debian_8 ubuntu_14_04 ubuntu_16_04 ubuntu_17_04 scientific_6} ;;
	*) echo 'unknown arch' && exit 1 ;;
	esac
	# shellcheck disable=SC2206
	OSES=($OSES)
	cd -
	for OS in "${OSES[@]}"; do
		UEFI=${UEFI:-} OS=$OS $0 test "$@"
	done
	exit
fi

do_test "$@"
