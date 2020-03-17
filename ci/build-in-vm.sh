#! /bin/sh

w 150
root
w
cat >/tmp/run.sh <<'EOF'
set -ex
date
date -s '@DT@' || :
date
trap 'echo "done, powering off"; poweroff' EXIT
modprobe virtio-rng

facility=$(sed -nr 's|.*\bfacility=(\S+).*|\1|p' /proc/cmdline)
arch=$(uname -m)
tag=osie-$arch

# install deps
main_repo=$(sed -nr 's|.*\balpine_repo=(\S+).*|\1|p' /proc/cmdline)
comm_repo=${main_repo/main/community}
apk add --update --upgrade --repository "$main_repo" --repository "$comm_repo" coreutils curl docker e2fsprogs gptfdisk parted pigz wget

service docker start && sleep 5
until docker info; do sleep 5; done
docker login -u "packetrobot" -p "_H9aUkxxjh=f8~3="

cd /tmp
curl -f http://install.$facility.packet.net/osie-src.tar.gz | unpigz | tar -x
docker build -t $tag docker
docker save $tag > $tag.tar
sha512sum $tag.tar > $tag.tar.sha512sum
tar -cf- $tag.tar $tag.tar.sha512sum > $tag
ls -l $tag.tar $tag.tar.sha512sum $tag
cat $tag.tar.sha512sum
cat $tag > /dev/vda
sync
EOF
sh /tmp/run.sh
