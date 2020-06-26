#!/usr/bin/env bash

set -euxo nounset

MSTFLINT_RELEASE=4.14.0-1
MSTFLINT_SHA512=965b25141d1b960bb575fc9fb089e912b0408af72919d23f295c6a8e8650c95c9459cb496171dca7f818252a180bd85bee8ed0f876159279013828478a0c2101
MSTFLINT_BASEURL=https://github.com/Mellanox/mstflint/releases/download/

curl -L "${MSTFLINT_BASEURL}/v${MSTFLINT_RELEASE}/mstflint-${MSTFLINT_RELEASE}.tar.gz" >mstflint.tar.gz
apt install -y zlib1g-dev libibmad-dev libssl-dev g++
echo "${MSTFLINT_SHA512}  mstflint.tar.gz" | sha512sum -c
tar -zxvf mstflint.tar.gz
cd mstflint-$(echo $MSTFLINT_RELEASE | sed 's/v//' | sed 's/-1//')
./configure
make
make install
apt-get purge -y zlib1g-dev libibmad-dev libssl-dev g++
apt-get autoremove -y
