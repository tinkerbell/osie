#!/usr/bin/env bash

set -euxo nounset

NVMECLI_RELEASE=1.8.1
NVMECLI_SHA512=b31690f6dbc1f88ebd461636b452b8dedc6e1f67e2fe9d088b1f1d2ddf634ab6ef8d628d2c7fdc6977587d9565deb816a1df8f4881759a12b030a190af5c9095
NVMECLI_BASEURL=https://github.com/linux-nvme/nvme-cli/archive

curl -L "${NVMECLI_BASEURL}/v${NVMECLI_RELEASE}.tar.gz" >nvme-cli.tar.gz
echo "${NVMECLI_SHA512}  nvme-cli.tar.gz" | sha512sum -c
tar -zxvf nvme-cli.tar.gz
cd nvme-cli-${NVMECLI_RELEASE}
make
make install-bin
