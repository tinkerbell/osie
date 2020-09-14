#!/bin/ash

# shellcheck shell=dash

docker_registry=$(sed -nr 's|.*\bdocker_registry=(\S+).*|\1|p' /proc/cmdline)
grpc_authority=$(sed -nr 's|.*\bgrpc_authority=(\S+).*|\1|p' /proc/cmdline)
grpc_cert_url=$(sed -nr 's|.*\bgrpc_cert_url=(\S+).*|\1|p' /proc/cmdline)
packet_base_url=$(sed -nr 's|.*\bpacket_base_url=(\S+).*|\1|p' /proc/cmdline)
registry_username=$(sed -nr 's|.*\bregistry_username=(\S+).*|\1|p' /proc/cmdline)
registry_password=$(sed -nr 's|.*\bregistry_password=(\S+).*|\1|p' /proc/cmdline)
tinkerbell=$(sed -nr 's|.*\btinkerbell=(\S+).*|\1|p' /proc/cmdline)
worker_id=$(sed -nr 's|.*\bworker_id=(\S+).*|\1|p' /proc/cmdline)
id=$(curl --connect-timeout 60 "$tinkerbell:50061/metadata" | jq -r .id)
log_driver=$(sed -nr 's|.*\blog_driver=(\S+).*|\1|p' /proc/cmdline)
log_opt_tag=$(sed -nr 's|.*\blog_opt_tag=(\S+).*|\1|p' /proc/cmdline)
log_opt_server_address=$(sed -nr 's|.*\blog_opt_server_address=(\S+).*|\1|p' /proc/cmdline)

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
i=0
# shellcheck disable=SC2169
until docker info >/dev/null || [[ $i -gt 5 ]]; do
	echo "Sleeping to wait for docker to start up"
	sleep 3
	i=$((i + 1))
done
docker info

until docker login "$docker_registry" -u "$registry_username" -p "$registry_password"; do
	echo 'Waiting for docker to respond...'
	sleep 3
done

# stop mdev from messing with us once and for all
rm -f /sbin/mdev

mkdir /worker

docker run --privileged -t --name "tink-worker" \
	-e "container_uuid=$id" \
	-e "WORKER_ID=$worker_id" \
	-e "DOCKER_REGISTRY=$docker_registry" \
	-e "TINKERBELL_GRPC_AUTHORITY=$grpc_authority" \
	-e "TINKERBELL_CERT_URL=$grpc_cert_url" \
	-e "REGISTRY_USERNAME=$registry_username" \
	-e "REGISTRY_PASSWORD=$registry_password" \
	-e "LOG_DRIVER=$log_driver" \
	-e "LOG_OPT_SERVER_ADDRESS=$log_opt_server_address" \
	-e "LOG_OPT_TAG=$log_opt_tag" \
	-v /worker:/worker \
	-v /var/run/docker.sock:/var/run/docker.sock \
	-t \
	--net host \
	--log-driver "$log_driver" \
	--log-opt "$log_driver-address=$log_opt_server_address" \
	--log-opt "tag=$log_opt_tag" \
	"$docker_registry/tink-worker:latest"
