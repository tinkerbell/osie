#!/bin/sh

set -o errexit

readonly switch=hv

echo "args: $# $*"
if [ -n "$1" ]; then
	#ip link set dev $1 master $switch
	brctl addif $switch "$1"
	ip link set "$1" up
else
	echo "Error: no interface specified"
	exit 1
fi
