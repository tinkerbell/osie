#!/usr/bin/env bash

set -euxo nounset

LSHW_RELEASE=B.02.18
LSHW_SHA512=090b79c144e4a42dd88a0a6d6992183d747ea891850f67403e0b63037b84d4b1891f2ad38f9151393b5ec1ac987b7ae70083c0f6eb8611f89d372a461390e8f3
LSHW_BASEURL=https://github.com/lyonel/lshw/archive

curl -L "${LSHW_BASEURL}/${LSHW_RELEASE}.tar.gz" >lshw.tar.gz
echo "${LSHW_SHA512}  lshw.tar.gz" | sha512sum -c
tar -zxvf lshw.tar.gz
cd lshw-${LSHW_RELEASE}/src
make -j "$(nproc)" lshw pci.ids usb.ids oui.txt manuf.txt
install -pDm 0755 lshw /usr/sbin
install -pDm 0644 -t /usr/share/lshw/ pci.ids usb.ids oui.txt manuf.txt
