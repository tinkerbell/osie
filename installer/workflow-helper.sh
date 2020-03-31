#!/bin/sh

docker_registry=$(sed -nr 's|.*\bdocker_registry=(\S+).*|\1|p' /proc/cmdline)
grpc_authority=$(sed -nr 's|.*\bgrpc_authority=(\S+).*|\1|p' /proc/cmdline)
grpc_cert_url=$(sed -nr 's|.*\bgrpc_cert_url=(\S+).*|\1|p' /proc/cmdline)
packet_base_url=$(sed -nr 's|.*\bpacket_base_url=(\S+).*|\1|p' /proc/cmdline)
registry_username=$(sed -nr 's|.*\bregistry_username=(\S+).*|\1|p' /proc/cmdline)
registry_password=$(sed -nr 's|.*\bregistry_password=(\S+).*|\1|p' /proc/cmdline)
elastic_search_url=$(sed -nr 's|.*\belastic_search_url=(\S+).*|\1|p' /proc/cmdline)
tinkerbell=$(sed -nr 's|.*\belastic_search_url=(\S+).*|\1|p' /proc/cmdline)
worker_id=$(sed -nr 's|.*\bworker_id=(\S+).*|\1|p' /proc/cmdline)
id=$(curl --connect-timeout 60 "$tinkerbell:50061/metadata" | jq -r .id)

# Create workflow motd
cat <<'EOF'
______          _        _                _
| ___ \        | |      | |              | |
| |_/ /_ _  ___| | _____| |_   _ __   ___| |_
|  __/ _` |/ __| |/ / _ \ __| | '_ \ / _ \ __|
| | | (_| | (__|   <  __/ |_ _| | | |  __/ |_
\_|  \__,_|\___|_|\_\___|\__(_)_| |_|\___|\__|

__            __         _     _ ___ _
\ \	     / /        | |   | '___| |
 \ \   __   / /___  _ __| | __| |__ | | ___ __      __
  \ \_/  \_/ /  _ \| '__| |/ /|  __|| |/ _ \\ \    / /
   \   /\   /| ( ) | |  |   < | |   | | (_) |\ \/\/ /
    \_/  \_/  \___/|_|  |_|\_\|_|   |_|\___/  \_/\_/


=====================================================================
Workflow environment based on Alpine Linux $(cat /etc/alpine-release)

Use "apk" package manager for additional utilities.
See docs at http://wiki.alpinelinux.org
EOF

# get docker registry certificate
wget "$packet_base_url/ca.pem"

# add registy certificate to docker daemon
mkdir -p /etc/docker/ /etc/docker/certs.d/ "/etc/docker/certs.d/$docker_registry"
cp ca.pem "/etc/docker/certs.d/$docker_registry/ca.crt"

service docker start

until docker info; do
	echo 'Waiting for docker to respond...'
	sleep 3
done

until docker login "$docker_registry" -u "$registry_username" -p "$registry_password"; do
	echo 'Waiting for docker to respond...'
	sleep 3
done

# stop mdev from messing with us once and for all
rm -f /sbin/mdev

docker run -dit --net host \
	"$docker_registry/fluent-bit:1.3" \
	/fluent-bit/bin/fluent-bit -i forward -o "es://$elastic_search_url/worker/worker"

# waiting for fluentbit
sleep 3

mkdir /worker

docker run --privileged -ti \
	-e "container_uuid=$id" \
	-e "WORKER_ID=$worker_id" \
	-e "DOCKER_REGISTRY=$docker_registry" \
	-e "ROVER_GRPC_AUTHORITY=$grpc_authority" \
	-e "ROVER_CERT_URL=$grpc_cert_url" \
	-e "REGISTRY_USERNAME=$registry_username" \
	-e "REGISTRY_PASSWORD=$registry_password" \
	-v /worker:/worker \
	-v /var/run/docker.sock:/var/run/docker.sock \
	--log-driver=fluentd -t \
	--net host \
	"$docker_registry/worker"
