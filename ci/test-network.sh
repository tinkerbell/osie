#!/bin/bash

set -o errexit -o nounset -o pipefail

get_subnet() {
	# convert subnets in use into grep -E pattern
	pattern=$(ip -4 addr | awk '/inet 172/ {print $2}' | sort -h | sed 's|172.\([0-9]\+\).*|\1|' | tr '\n' '|' | sed -e 's/^/^(/' -e 's/|$/)/')
	seq 0 255 | grep -vwE "$pattern" | shuf -n1 | sed 's|.*|172.&.0|'
}

function genmeta() {
	ifaces_array=$(
		cat <<-EOF
			{ "name": "$name0", "mac": "$mac0" }, { "name": "$name1", "mac": "$mac1" }
		EOF
	)

	cat <<EOF | jq -S .
{
	"hostname": "${id%%-*}",
	"id": "$id",
	"plan": "$type",
	"network": {
		"bonding": {
			"mode": $mode
		},
		"interfaces": [$ifaces_array],
		"addresses": [{
			"address": "$pubip4",
			"address_family": 4,
			"cidr": 31,
			"gateway": "$pubgw4",
			"management": true,
			"netmask": "255.255.255.254",
			"network": "$pubnet4",
			"public": true
		}, {
			"address": "10.42.42.42",
			"address_family": 4,
			"cidr": 31,
			"gateway": "10.42.42.41",
			"management": false,
			"netmask": "255.255.255.254",
			"network": "10.42.42.41",
			"public": true
		}, {

			"address": "$pubip6",
			"address_family": 6,
			"cidr": 127,
			"gateway": "$pubgw6",
			"management": true,
			"netmask": "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe",
			"network": "$pubnet6",
			"public": true
		}, {
			"address": "$privip",
			"address_family": 4,
			"cidr": 31,
			"gateway": "$privgw",
			"management": true,
			"netmask": "255.255.255.254",
			"network": "$privnet",
			"public": false
		}]
	}
}
EOF
}

function test_do() {
	workdir=$(mktemp -dt test-osie-network-workdir-XXXXXX)
	id=$(uuidgen)

	layout="network-test-files/base/$os-$type-$maker"
	want=$(realpath "network-test-files/want/$os-$type-$maker")

	work=$workdir/$os-$type-$maker
	log=$work/log
	meta=$work/meta
	target=$work/target
	mkdir "$work" "$target"
	rsync -a "$want/" "$work/want"
	want=$work/want

	# shellcheck disable=SC2207
	dns=($(awk '/^nameserver/ {print $2}' /etc/resolv.conf))
	subnet=$(get_subnet)
	ip=$((RANDOM % 256))
	pubip4=$subnet.$ip
	pubgw4=$subnet.$((ip + 1))
	pubnet4=$subnet.$((ip - 1))
	pubip6=2604:1380:2:4242::$ip
	pubgw6=2604:1380:2:4242::$((ip + 1))
	pubnet6=2604:1380:2:4242::$((ip - 1))
	privip=10.0.0.$ip
	privgw=10.0.0.$((ip + 1))
	privnet=10.0.0.$((ip - 1))
	name0=${ports[0]}
	if ((${#ports[@]} > 1)); then
		name1=${ports[1]}
	fi
	genmeta >"$meta"

	sed_dns_2_cmd=''
	if ((${#dns[@]} >= 2)); then
		sed_dns_2_cmd="s|@DNS2@|${dns[1]}|g"
	else
		sed_dns_2_cmd='/@DNS2@/ d'
	fi
	# shellcheck disable=SC2046
	sed -i \
		-e "s|@HOSTNAME@|${id%%-*}|g" \
		-e "s|@MAC0@|$mac0|g" \
		-e "s|@MAC1@|$mac1|g" \
		-e "s|@PUBIP4@|$pubip4|g" \
		-e "s|@PUBGW4@|$pubgw4|g" \
		-e "s|@PUBNET4@|$pubnet4|g" \
		-e "s|@PUBIP6@|$pubip6|g" \
		-e "s|@PUBGW6@|$pubgw6|g" \
		-e "s|@PUBNET6@|$pubnet6|g" \
		-e "s|@PRIVIP@|$privip|g" \
		-e "s|@PRIVGW@|$privgw|g" \
		-e "s|@PRIVNET@|$privnet|g" \
		-e "s|@DNSES@|${dns[*]}|g" \
		-e "s|@DNS1@|${dns[0]}|g" \
		-e "$sed_dns_2_cmd" \
		$(find "$want" -type f)
	find "$want" -name .gitkeep -delete

	rsync -a "$layout/" "$target/"
	find "$target" -name .gitkeep -delete

	(
		version=42
		case $os in
		centos) os=CentOS ;;
		debian) os=Debian ;;
		opensuse) os=openSUSEproject ;;
		sci) os=ScientificCERNSLC ;;
		ub14) os=Ubuntu version=14.04 ;;
		ub*) os=Ubuntu ;;
		esac

		ret=0
		cd ../docker/scripts/packet-networking
		coverage run packetnetworking -M "$meta" -o "$os $version" -t "$target" &>"$log" || ret=$?
		((ret != 0)) && cat "$log" && exit "$ret"
		diff -ru "$want" "$target"
	)
}

json=network-test-files/portnames.json

function env_or_json() {
	local var=$1
	local query=$2

	jq -r "${query}" $json | (
		if [[ -n $var ]]; then
			grep -E "(${var/,/|})" || :
		else
			cat
		fi
	)

}

oct=$((RANDOM % 251)) # guranteed 4 macs won't overflow
mac0=0
mac1=0
for i in {0..3}; do
	mac="02:00:00:00:00:$(printf '%02x' $((oct + i)))"
	eval "mac$i=$mac"
	ip link add "dummy$i" type dummy
	ip link set "dummy$i" address "$mac"
done

cleanup() {
	for i in {0..3}; do
		ip link del "dummy$i"
	done
}
trap cleanup EXIT

out=$(mktemp -d)

# shellcheck disable=SC2207
oses=($(env_or_json "${OSES:-}" 'keys|.[]'))
for os in "${oses[@]}"; do
	case $os in
	rh | vz) echo "$os is not supported, skipping" && continue ;;
	esac

	# shellcheck disable=SC2207
	types=($(env_or_json "${TYPES:-}" ".$os|keys|.[]"))
	for type in "${types[@]}"; do

		# shellcheck disable=SC2207
		mode=$(env_or_json "${MODES:-}" ".$os.\"$type\".mode")

		# shellcheck disable=SC2207
		makers=($(env_or_json "${MAKERS:-}" ".$os.\"$type\"|del(.mode)|keys[]"))
		for maker in "${makers[@]}"; do

			# TODO: remove SC1087 when https://github.com/koalaman/shellcheck/issues/1212 is closed
			#shellcheck disable=SC2207,SC1087
			ports=($(jq -r ".$os.\"$type\".$maker[]" $json))
			echo "os=$os type=$type maker=$maker mode=$mode ports=${ports[*]}"
			COVERAGE_FILE=/coverage/.coverage.$os-$type-$maker-$mode test_do &>"$out/$os-$type-$maker-$mode.out" &
		done
	done
done
wait

find "$out" -type f ! -empty -print -and -exec cat {} \;

cd /coverage
coverage combine -a
