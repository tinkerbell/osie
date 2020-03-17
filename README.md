# osie

[![Build Status](https://drone.packet.net/api/badges/packethost/osie/status.svg)](https://drone.packet.net/packethost/osie)

# Deploying
OSIE is built and uploaded to a self-hosted minio instance in ewr for master and tag builds.
Production deployments should only be done from tags.
Use the [git-tag-and-release](https://github.com/packethost/eng-tools/blob/master/git-tag-and-release) script found in the [eng-tools repo](https://github.com/packethost/eng-tools)
At the end of the `upload` step, drone will output the command that can be run locally to deploy to some/all of production.

# CI / Drone / Testing

Commits to osie will be built and tested by [Drone CI](https://drone.packet.net/packethost/osie/)
Configuration for the build can be found in the root of the repo in .drone.yml

# Alpine Kernel Compilation

The alpine kernel/initrd is built using the Dockerfile contained in installer/alpine.

Inside that Dockerfile we build linux-vanilla from the edge aports tree after enabling KEXEC in the config.
This build takes a very long time.

Any kernel modules you would like to be included in the resulting modloop need to be listed in build.sh

make V=1 will build the alpine kernel, initrd, and module set with full verbosity enabled.
The build artifacts will be placed in a folder named assets-$arch, only x86_64 is currently built.

Assets from assets-x86_64 then need to be uploaded to install.ewr1.packet.net into /srv/www/install/alpine/boot/3.7
Each file's sha512sum needs to then be updated in the main Makefile (in the root of the source repo).
During 'make package' these files will be downloaded, merged with some additional content and bundled up into the tarball for distribution to the various facility install servers.

# Installing Alpine packages

Alpine packages should be installed in the installer/alpine/Dockerfile like so:

```Dockerfile
RUN apk add --no-scripts --update --upgrade --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing kexec-tools
```

Those package names then need to be added to installer/alpine/init-x86_64 in this list:

```sh
KOPT_pkgs="curl,docker,jq,mdadm,openssh,kexec-tools"
```

If you need to install packages from a non-standard alpine repo, the URI will need to be listed in installer/alpine/init-x86_64 like so:

```sh
ALPINE_REPO="http://dl-cdn.alpinelinux.org/alpine/v3.7/main,http://dl-cdn.alpinelinux.org/alpine/v3.7/community,http://dl-cdn.alpinelinux.org/alpine/edge/testing"
```
