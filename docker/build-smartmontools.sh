#!/usr/bin/env bash

set -euxo nounset

SMARTMONTOOLS_RELEASE=RELEASE_7_1
SMARTMONTOOLS_TARNAME=smartmontools-7.1
SMARTMONTOOLS_SHA512=440b2a957da10d240a8ef0008bd3358b83adb9eaca0f8d3e049b25d56a139c61dcd0bb4b27898faef6f189a27e159bdca3331e52e445c0eebf35e5d930f9e295
SMARTMONTOOLS_BASEURL=https://github.com/smartmontools/smartmontools/releases/download/

curl -L "${SMARTMONTOOLS_BASEURL}/${SMARTMONTOOLS_RELEASE}/${SMARTMONTOOLS_TARNAME}.tar.gz" >smartmontools.tar.gz
echo "${SMARTMONTOOLS_SHA512}  smartmontools.tar.gz" | sha512sum -c
tar -zxvf smartmontools.tar.gz
cd $(echo $SMARTMONTOOLS_TARNAME)
./configure
make
make install
