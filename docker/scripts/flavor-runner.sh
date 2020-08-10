#!/usr/bin/env bash

shopt -s extglob
get_script() {
	local state=$1 slug=$2
	case $slug:$state in
	*:deprovisioning)
		echo /home/packet/deprovision.sh
		;;
	@(centos|debian|opensuse|rhel|scientific|suse|ubuntu)*)
		echo /home/packet/osie.sh
		;;
	freebsd*)
		echo /home/packet/frosie.sh
		;;
	virtuozzo*)
		echo /home/packet/vosie.sh
		;;
	windows*)
		echo /home/packet/wosie.sh
		;;
	esac
}

if [[ $0 == "${BASH_SOURCE[0]}" ]]; then
	set -o errexit -o nounset -o pipefail -o xtrace
	state=$(jq -r .state /statedir/metadata)
	slug=$(jq -r .operating_system.slug /statedir/metadata)
	script=$(get_script "$state" "$slug")

	[[ -z ${script} ]] && exit 1

	exec "$script" "$@"
fi
