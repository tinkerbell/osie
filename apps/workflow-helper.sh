#!/bin/ash

# shellcheck shell=dash

docker_registry=$(sed -nr 's|.*\bdocker_registry=(\S+).*|\1|p' /proc/cmdline)
grpc_authority=$(sed -nr 's|.*\bgrpc_authority=(\S+).*|\1|p' /proc/cmdline)
grpc_cert_url=$(sed -nr 's|.*\bgrpc_cert_url=(\S+).*|\1|p' /proc/cmdline)
packet_base_url=$(sed -nr 's|.*\bpacket_base_url=(\S+).*|\1|p' /proc/cmdline)
registry_username=$(sed -nr 's|.*\bregistry_username=(\S+).*|\1|p' /proc/cmdline)
registry_password=$(sed -nr 's|.*\bregistry_password=(\S+).*|\1|p' /proc/cmdline)
tinkerbell=$(sed -nr 's|.*\btinkerbell=(\S+).*|\1|p' /proc/cmdline)
instance_id=$(sed -nr 's|.*\binstance_id=(\S+).*|\1|p' /proc/cmdline)
worker_id=$(sed -nr 's|.*\bworker_id=(\S+).*|\1|p' /proc/cmdline)

# Create workflow motd
cat <<'EOF'
                                                  
,------.               ,--.        ,--.           
|  .---' ,---. ,--.,--.`--',--,--, `--',--.  ,--. 
|  `--, | .-. ||  ||  |,--.|      \,--. \  `'  /  
|  `---.' '-' |'  ''  '|  ||  ||  ||  | /  /.  \  
`------' `-|  | `----' `--'`--''--'`--''--'  '--' 
           `--'                                   
,--.   ,--.              ,--.    ,------.,--.                   
|  |   |  | ,---. ,--.--.|  |,-. |  .---'|  | ,---. ,--.   ,--. 
|  |.'.|  || .-. ||  .--'|     / |  `--, |  || .-. ||  |.'.|  | 
|   ,'.   |' '-' '|  |   |  \  \ |  |`   |  |' '-' '|   .'.   | 
'--'   '--' `---' `--'   `--'`--'`--'    `--' `---' '--'   '--'


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

# tink-worker has been updated to use ID rather than WORKER_ID
# TODO: remove setting WORKER_ID when we no longer want to support backwards compatibility
# with the older tink-worker
docker run --privileged -t --name "tink-worker" \
	-e "container_uuid=$instance_id" \
	-e "WORKER_ID=$worker_id" \
	-e "ID=$worker_id" \
	-e "DOCKER_REGISTRY=$docker_registry" \
	-e "TINKERBELL_GRPC_AUTHORITY=$grpc_authority" \
	-e "TINKERBELL_CERT_URL=$grpc_cert_url" \
	-e "REGISTRY_USERNAME=$registry_username" \
	-e "REGISTRY_PASSWORD=$registry_password" \
	-v /worker:/worker \
	-v /var/run/docker.sock:/var/run/docker.sock \
	-t \
	--net host \
	"$docker_registry/tink-worker:latest"
