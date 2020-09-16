# OSIE

[![Build Status](https://drone.packet.net/api/badges/tinkerbell/osie/status.svg)](https://drone.packet.net/tinkerbell/osie)
![](https://img.shields.io/badge/Stability-Maintained-green.svg)

OSIE is the Operating System Installation Environment.
It consists of an Alpine Linux based netboot image which fetches a prebuilt Ubuntu 16.04 container that does the actual installation.
All of the above is built from this repository using `GNU Make`.

This repository is [Maintained](https://github.com/packethost/standards/blob/master/maintained-statement.md) meaning that this software is supported by Packet and its community - available to use in production environments.

## Building OSIE

### Ubuntu Based Container
The OSIE Ubuntu based container is built with `docker` for both `aarch64` and `x86_64`.
Some packages are rebuilt with different settings (git, using openssl) or updated upstream sources are built/installed.
These can be built individually with `make build/osie-aarch64.tar.gz` or `make build build/osie-x86_64.tar.gz`.

### Alpine Based Netboot Image
The OSIE Alpine boot files are built in an Alpine Docker container.
All the packages are built at container build time, including the kernel.
The built/installed packages are later used at run time to generate `initramfs` and `modloop` files.

##### Note: Skipping Alpine Kernel Builds

Building the Alpine Linux Kernel takes a _long_ time, on account of building just about _all_ of the kernel modules.
This is usually not needed as we don't mess with the kernel configuration very often.
Unfortunately, `make` will try to build the kernel unless certain steps are taken (usually only on initial `git clone`).
Skipping these builds can be done by running the `installer/alpine/skip-building-alpine-files` script, which updates the modified timestamp of the source files so `make` will not try to rebuild.

#### Build Dependencies

The build dependencies can be seen in `Makefile` and `rules.mk.j2`, they are the source of truth.
The packages found in [shell.nix](./shell.nix) are good second source.
Using [nix-shell](https://nixos.org/nix/manual/#sec-nix-shell) or [lorri](https://github.com/target/lorri) along with [direnv](https://direnv.net/) is **highly** recommended.

Otherwise, ensure the following tools are installed:

- bash
- curl
- cpio
- docker
- git
- git-lfs
- gnumake
- gnused
- [j2cli](https://pypi.org/project/j2cli) (for j2)
- libarchive (for bsdcpio, bsdtar)
- minio (for mc)
- pigz (and unpigz)

# Adding Alpine Packages To initramfs

The Alpine x86_64 initramfs image used is fully self-reliant.
We embed the .apk files, and repo metadata into the initramfs for all packages used as part of `/init`.
Alpine packages should be installed in the installer/alpine/Dockerfile like so:

```Dockerfile
RUN apk add --no-scripts --update --upgrade --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing kexec-tools
```

Those package names then need to be added to installer/alpine/init-x86_64 in this list:

```sh
KOPT_pkgs="curl,docker,jq,mdadm,openssh,kexec-tools"
```

If you need to install packages from a non-standard alpine repo, the URL will need to be listed in installer/alpine/init-x86_64 like so:

```sh
ALPINE_REPO="http://dl-cdn.alpinelinux.org/alpine/v3.7/main,http://dl-cdn.alpinelinux.org/alpine/v3.7/community,http://dl-cdn.alpinelinux.org/alpine/edge/testing"
```
