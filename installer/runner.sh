#!/bin/ash

# shellcheck shell=dash

reason='unknown'
fail() {
	curl -H 'Content-Type: application/json' \
		-d '{"type":"failure", "reason":"'"$reason"'"}' \
		"$phone_home_url"
}

# ensure_time fetches metadata via http and compares the time the server says it
# is versus what the hwclock says. If the time differs by more than 12 hours it
# sets the time to what metadata server has. This assumes that the metadata
# service has a better chance of having its time synced. This is a hack until
# we have ntp in each facility.
ensure_time() {
	local d hwdate mddate month
	local months='jan feb mar apr may jun jul aug sep oct nov dec'
	d=$(curl -sI http://metadata.packet.net/metadata | sed -n '/^Date:/ s|Date: ||p')
	# shellcheck disable=SC2018 disable=SC2019
	month=$(echo "$d" | awk '{print $3}' | tr 'A-Z' 'a-z')
	local i=1
	for m in $months; do
		# shellcheck disable=SC2169
		[[ $month == "$m" ]] && break
		i=$((i + 1))
	done
	# shellcheck disable=SC2169
	[[ $i -gt 12 ]] && echo "could not parse month from http header" >&2 && return

	hwdate=$(date -u +%s)
	d=$(echo "$d" | awk '{printf "%d.%02d.%02d-%s\n", $4, '"$i"', $2, $5}')
	mddate=$(date +%s -d "$d")
	local diff=$((mddate - hwdate))
	# shellcheck disable=SC2169
	if [[ $diff -gt $((60 * 60 * 12)) ]] || [[ $diff -lt $((-60 * 60 * 12)) ]]; then
		echo "hwclock differs from metadata by more than 12h"
		date -u -s "$d"
		# because we don't have rtc drivers in qemu-aarch64... sigh
		hwclock -uw || :
	fi
}

set -o errexit -o nounset -o pipefail -o xtrace

# Create OSIE motd
cat <<'EOF' >/etc/motd
______          _        _                _
| ___ \        | |      | |              | |
| |_/ /_ _  ___| | _____| |_   _ __   ___| |_
|  __/ _' |/ __| |/ / _ \ __| | '_ \ / _ \ __|
| | | (_| | (__|   <  __/ |_ _| | | |  __/ |_
\_|  \__,_|\___|_|\_\___|\__(_)_| |_|\___|\__|
===============================================
##          Task Runner Environment          ##
EOF

# stop mdev from messing with us once and for all
rm -f /sbin/mdev

ensure_time

hardware_id=$(curl -sSL --connect-timeout 60 https://metadata.packet.net/metadata | jq -r .hardware_id)
statedir=${TMPDIR:-/tmp}/osie-statedir-$hardware_id
metadata=$statedir/metadata
mkdir -p "$statedir"

echo "metadata:"
curl -sSL --connect-timeout 60 https://metadata.packet.net/metadata |
	jq -S . |
	tee "$metadata" |
	jq .

arch=$(uname -m)
packet_base_url=$(sed -nr 's|.*\bpacket_base_url=(\S+).*|\1|p' /proc/cmdline)
packet_bootdev_mac=$(sed -nr 's|.*\bpacket_bootdev_mac=(\S+).*|\1|p' /proc/cmdline)
facility=$(jq -r .facility "$metadata")
phone_home_url=$(jq -r .phone_home_url "$metadata")

trap fail EXIT

service docker start
until docker info; do
	sleep 3
done

reason='unable to fetch/load osie-runner image'
if ! docker images "osie-runner:$arch" | grep osie >/dev/null; then
	curl "${packet_base_url:-http://install.$facility.packet.net/misc/osie/current}/osie-runner-$arch.tar.gz" |
		docker load |
		tee
fi

reason='unable to fetch/load osie image'
if ! docker images "osie:$arch" | grep osie >/dev/null; then
	curl "${packet_base_url:-http://install.$facility.packet.net/misc/osie/current}/osie-$arch.tar.gz" |
		docker load |
		tee
fi

# make sure messages show up in all consoles
# we skip first because it's already going there via stdout
other_consoles=$(
	tr ' ' '\n' </proc/cmdline |
		sed -n '/^console=/ s|.*=\(ttyS\?[0-9]\+\).*|/dev/\1|p' |
		head -n-1
)

while true; do
	reason='docker exited with an error'
	docker run -ti \
		-e "PACKET_BASE_URL=$packet_base_url" \
		-e "PACKET_BOOTDEV_MAC=${packet_bootdev_mac:-}" \
		-e "STATEDIR_HOST=$statedir" \
		-v "$statedir:/statedir" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		"osie-runner:$arch" | (
		# shellcheck disable=SC2086
		tee $other_consoles
	)

	if [ -x "$statedir/cleanup.sh" ]; then
		reason='cleanup.sh did not finish correctly'
		cd "$statedir"
		exec ./cleanup.sh
	fi
	if [ -x "$statedir/loop.sh" ]; then
		reason='loop.sh did not finish correctly'
		cd "$statedir"
		./loop.sh
		rm -f loop.sh
	fi
done
