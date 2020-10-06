#!/bin/sh

apk del eclypsiumdriver-vanilla

# shellcheck disable=SC2039
set -o errexit -o pipefail -o xtrace

# Create rescue motd
cat <<'EOF' >/etc/motd
                                                  
,------.               ,--.        ,--.           
|  .---' ,---. ,--.,--.`--',--,--, `--',--.  ,--. 
|  `--, | .-. ||  ||  |,--.|      \,--. \  `'  /  
|  `---.' '-' |'  ''  '|  ||  ||  ||  | /  /.  \  
`------' `-|  | `----' `--'`--''--'`--''--'  '--' 
           `--'                                   
===============================================
   Rescue environment based on Alpine Linux $(cat /etc/alpine-release)

Use "apk" package manager for additional utilities.
See docs at http://wiki.alpinelinux.org

EOF

mkdir -p /root/.ssh
curl -sSLf https://metadata.packet.net/2009-04-04/meta-data/public-keys >/root/.ssh/authorized_keys

tinkerbell=$(sed -nr 's|.*\btinkerbell=(\S+).*|\1|p' /proc/cmdline)

curl -X POST -vs "$tinkerbell/phone-home" 2>&1 | logger -t phone_home

mdadm --assemble --scan || :
