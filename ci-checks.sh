#!/usr/bin/env nix-shell
#!nix-shell -i bash
# shellcheck shell=bash

set -eux

failed=0

if ! shfmt -f . | grep -v shunit | xargs shfmt -d -s; then
	failed=1
fi

if ! shfmt -f . | grep -v -e installer/alpine/init -e packet_lsb_release -e shunit | xargs shellcheck; then
	failed=1
fi

if ! black -t py35 --check --diff .; then
	failed=1
fi
# shellcheck disable=SC2010,SC2046
if ! pylama --ignore=E203 docker $(ls osie-runner | grep -v hegel); then
	failed=1
fi

exit "$failed"
