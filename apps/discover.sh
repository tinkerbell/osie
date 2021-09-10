#!/bin/ash

# shellcheck shell=dash

arch=$(uname -m)
packet_base_url=$(sed -nr 's|.*\bpacket_base_url=(\S+).*|\1|p' /proc/cmdline)
facility=$(sed -nr 's|.*\bfacility=(\S+).*|\1|p' /proc/cmdline)
tinkerbell=$(sed -nr 's|.*\btinkerbell=(\S+).*|\1|p' /proc/cmdline | sed -e 's|^http://||' -e 's|/.*||')
phone_home_url="http://$tinkerbell/phone-home"

discover_url=$(sed -nr 's|.*\bdiscover_url=(\S+).*|\1|p' /proc/cmdline)
if [ -z "$discover_url" ]; then
	discover_url="http://$tinkerbell/discover-os"
fi

reason='unknown'
fail() {
	curl -H 'Content-Type: application/json' \
		-H "traceparent: ${TRACEPARENT:-}" \
		-d '{"type":"failure", "reason":"'"$reason"'"}' \
		"$phone_home_url"
}

# shellcheck disable=SC2039
set -o errexit -o pipefail -o xtrace

# Create rescue motd
cat <<'EOF' >/etc/motd
    ,------.               ,--.        ,--.                       
    |  .---' ,---. ,--.,--.`--',--,--, `--',--.  ,--.             
    |  `--, | .-. ||  ||  |,--.|      \,--. \  `'  /              
    |  `---.' '-' |'  ''  '|  ||  ||  ||  | /  /.  \              
    `------' `-|  | `----' `--'`--''--'`--''--'  '--'             
,------.  ,--. `--'                                               
|  .-.  \ `--' ,---.  ,---. ,---.,--.  ,--.,---. ,--.--.,--. ,--. 
|  |  \  :,--.(  .-' | .--'| .-. |\  `'  /| .-. :|  .--' \  '  /  
|  '--'  /|  |.-'  `)\ `--.' '-' ' \    / \   --.|  |     \   '   
`-------' `--'`----'  `---' `---'   `--'   `----'`--'   .-'  /    
                                                        `---'     
=================================================================
       Discovery environment based on Ubuntu Xenial
EOF

mkdir -p /root/.ssh

curl -X POST -vs "$phone_home_url" 2>&1 | logger -t phone_home

mdadm --assemble --scan || :

service cgroups start
service docker start

until docker info; do
	echo 'Waiting for docker to respond...'
	sleep 3
done

reason='unable to load discover container image'
if ! docker images "quay.io/packet/discover-metal" | grep discover >/dev/null; then
	curl "${packet_base_url:-http://install.$facility.packet.net/misc/osie/current}/discover-metal-$arch.tar.gz" |
		docker load |
		tee
fi

# stop mdev from messing with us once and for all
rm -f /sbin/mdev

cat <<'EOF' >/bin/discover-shell
#!/bin/sh
docker run --privileged --entrypoint bash -it quay.io/packet/discover-metal
EOF
chmod +x /bin/discover-shell

reason='docker exited with an error'
docker run --privileged -ti \
	-v /dev:/dev \
	--net host \
	quay.io/packet/discover-metal --send "$discover_url"
