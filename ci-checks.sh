#!/usr/bin/env nix-shell
#!nix-shell -i bash
# shellcheck shell=bash

set -eux

failed=0

if ! shfmt -d -s $(shfmt -f . | grep -v shunit); then
	failed=1
fi

if ! shellcheck apps/*.sh ci/*.sh; then
	failed=1
fi
if ! (cd docker/scripts && shellcheck -x *.sh); then
	failed=1
fi

if ! black -t py35 --check --diff --exclude docker/scripts/packet-networking .; then
	failed=1
fi
if ! pylama --ignore=E203 docker $(ls osie-runner | grep -v hegel); then
	failed=1
fi

exit "$failed"
