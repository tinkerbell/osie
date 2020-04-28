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

set -o errexit -o pipefail

# Create OSIE motd
cat <<'EOF' >/etc/motd
______          _        _                _
| ___ \        | |      | |              | |
| |_/ /_ _  ___| | _____| |_   _ __   ___| |_
|  __/ _' |/ __| |/ / _ \ __| | '_ \ / _ \ __|
| | | (_| | (__|   <  __/ |_ _| | | |  __/ |_
\_|  \__,_|\___|_|\_\___|\__(_)_| |_|\___|\__|
===============================================
#	OS Installation Environment	      #
###############################################
EOF

arch=$(uname -m)

# Pull in kopts
packet_base_url=$(sed -nr 's|.*\bpacket_base_url=(\S+).*|\1|p' /proc/cmdline)
pwhash=$(sed -nr 's|.*\bpwhash=(\S+).*|\1|p' /proc/cmdline)
kslug=$(sed -nr 's|.*\bslug=(\S+).*|\1|p' /proc/cmdline)

case $kslug in
*deprovision*) state=deprovision ;;
*) state=provision ;;
esac

ensure_time

hardware_id=$(curl -sSL --connect-timeout 60 https://metadata.packet.net/metadata | jq -r .hardware_id)
statedir=${TMPDIR:-/tmp}/osie-statedir-$hardware_id
metadata=$statedir/metadata
userdata=$statedir/userdata
mkdir -p "$statedir"

service docker start

reason='unable to fetch metadata'
echo "metadata:"
curl -sSL --connect-timeout 60 https://metadata.packet.net/metadata |
	jq -S . |
	tee "$metadata" |
	jq .

slug=$(jq -r .operating_system.slug "$metadata")
if [ "$slug" = 'custom_ipxe' ]; then
	os=${kslug%%:*}
	tag=${kslug##*:}
	osv='"distro":"'"$os"'","image_tag":"'"$tag"'","slug":"'"$os:$tag"'"'
	jq -S '. + {"operating_system":{'"$osv"'}}' <"$metadata" >"$metadata.tmp"
	mv "$metadata.tmp" "$metadata"
fi

jq -S '. + {"password_hash":"'"$pwhash"'", "state": (.state? // "'"$state"'")}' <"$metadata" >"$metadata.tmp"
mv "$metadata.tmp" "$metadata"
echo "tweaked metadata:"
jq -S . "$metadata"

reason='unable to fetch userdata'
echo "userdata:"
curl -sSL --connect-timeout 60 https://metadata.packet.net/userdata | tee "$userdata"

# Get values from metadata
facility=$(jq -r .facility "$metadata")
hardware_id=$(jq -r .hardware_id "$metadata")
id=$(jq -r .id "$metadata")
phone_home_url=$(jq -r .phone_home_url "$metadata")
slug=$(jq -r .operating_system.slug "$metadata")
state=$(jq -r .state "$metadata")
tinkerbell=$(jq -r .phone_home_url "$metadata" | sed -e 's|^http://||' -e 's|/.*||')

trap fail EXIT

# Show a summary of kopts
cat <<-EOF | grep -v '^\s*$'
	           arch: $arch
	       facility: $facility
	             id: $id
	           slug: $slug
	          state: $state
	       statedir: $statedir
	     tinkerbell: $tinkerbell
	${packet_base_url:+packet_base_url: $packet_base_url}
EOF

until docker info; do
	sleep 3
done

reason='unable to fetch/load osie image'
if ! docker images "osie:$arch" | grep osie >/dev/null; then
	curl "${packet_base_url:-http://install.$facility.packet.net/misc/osie/current}/osie-$arch.tar.gz" |
		docker load
fi

case $state:$slug in
deprovision:*)
	modprobe sg
	script=/home/packet/deprovision.sh
	;;
*freebsd*)
	modprobe fuse
	script=/home/packet/frosie.sh
	;;
*virtuozzo*)
	script=/home/packet/vosie.sh
	;;
*windows*)
	script=/home/packet/wosie.sh
	;;
*)
	script=/home/packet/osie.sh
	;;
esac

# stop mdev from messing with us once and for all
rm -f /sbin/mdev

# make sure messages show up in all consoles
# we skip first because it's already going there via stdout
other_consoles=$(
	tr ' ' '\n' </proc/cmdline |
		sed -n '/^console=/ s|.*=\(ttyS\?[0-9]\+\).*|/dev/\1|p' |
		head -n-1
)

reason='docker exited with an error'
docker run --privileged -ti \
	-h "${hardware_id}" \
	-e "container_uuid=$id" \
	-e "RLOGHOST=$tinkerbell" \
	-v /dev:/dev \
	-v /dev/console:/dev/console \
	-v /lib/firmware:/lib/firmware:ro \
	-v "/lib/modules/$(uname -r):/lib/modules/$(uname -r)" \
	-v "$metadata:/metadata:ro" \
	-v "$userdata:/userdata:ro" \
	-v "${statedir}:/statedir" \
	--net host \
	"osie:$arch" $script -M /metadata -u /userdata | (
	# shellcheck disable=SC2086
	tee $other_consoles
)

reason='cleanup.sh is not executable'
# shellcheck disable=SC2169
if [ -x "$statedir/cleanup.sh" ]; then
	reason='cleanup.sh did not finish correctly'
	cd "$statedir"
	exec ./cleanup.sh
fi
