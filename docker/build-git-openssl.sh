#!/usr/bin/env bash

set -euxo nounset

d=$(mktemp -d)
cd "$d"
apt-get install -y software-properties-common
# The version of git that comes with Xenial (2.7.4) doesn't support shallow
# clones from our github-mirror server, so use the latest officially supported
# Xenial release from the Ubuntu git maintainers PPA
add-apt-repository -y ppa:git-core/ppa
sed -i 's|^# deb-src|deb-src|' /etc/apt/sources.list
sed -i 's|^# deb-src|deb-src|' /etc/apt/sources.list.d/git-core-ubuntu-ppa-xenial.list
apt-get update

# this is to get mk-build-deps which creates a virtual package that deps on the
# build-deps of it's args, in this case git.
apt-get install -y --no-install-recommends devscripts equivs
# create virtual package that has same deps as git build-deps
mk-build-deps git
# remove mk-build-deps, because it pulls in a dep that somehow makes
# dpkg-buildpackage's git still link with libcurl4-gnutls
dpkg --unpack git-build-deps*
apt-get install -f -y --no-install-recommends

# this will force remove git-build-deps because git-build-deps deps on
# libcurl4-gnutls-dev which conflicts with libcurl4-openssl-dev.
# this is fine because it's only a virtual package and all the actual deps are
# marked as orphans and will still be removed by the autoremove later
apt-get install -y libcurl4-openssl-dev

apt-get source git
(
	cd git*
	sed -i debian/control \
		-e 's/libcurl4-gnutls-dev/libcurl4-openssl-dev/' \
		-e '/TEST\s*=\s*test/d' ./debian/rules
	debv=$(sed 's|.*-\([0-9]\+\).*|\1|' debian/changelog | head -n1)
	debv=$((debv + 1))
	sed "s|-.*|-${debv}packethost1) osie; urgency=medium|" debian/changelog |
		head -n1 >debian/changelog.tmp
	cat >>debian/changelog.tmp <<-EOF
		
		  * rebuild with openssl instead of gnutls
		
		 -- OSIE Builder <osie-builder@localhost>  $(date +'%a, %d %b %Y %T %z')
		
	EOF
	cat debian/changelog.tmp debian/changelog >debian/changelog.next
	mv debian/changelog.next debian/changelog
	rm debian/changelog.tmp

	dpkg-buildpackage -rfakeroot -b -j"$(nproc)"
)
mv ./*.deb /tmp/osie
apt-get purge -y devscripts equivs libcurl4-openssl-dev software-properties-common
apt-get autoremove -y
cd
rm -rf "$d"
