ifeq ($V,1)
Q=
o=/dev/stdout
e=/dev/stdout
else
Q=@
o=/dev/null
e=/dev/null
endif
E := $(Q)echo
E +=

all: assets-x86_64
.PHONY: all osie-alpine-initramfs-builder-aarch64 osie-initramfs-builder-x86_64

assets-aarch64: osie-alpine-initramfs-builder-aarch64
assets-x86_64: osie-alpine-initramfs-builder-x86_64
assets-aarch64 assets-x86_64:
	$(E) "BUILD $@"
	$(Q) docker run --rm -v ${PWD}/$@/:/assets --name=osie-$@ $< 1>$o 2>$e

osie-alpine-initramfs-builder-aarch64: Dockerfile build.sh qemu-aarch64-static /proc/sys/fs/binfmt_misc/qemu-aarch64
	$(E) "IMAGE $@"
	$(Q) sed '/^FROM alpine/ s| .*| arm64v8/alpine:3.6|' Dockerfile > Dockerfile.aarch64
	$(Q) docker build -f Dockerfile.aarch64 -t $@ . 1>$o 2>$e
	$(Q) touch $@

osie-alpine-initramfs-builder-x86_64: Dockerfile build.sh qemu-aarch64-static
	$(E) "IMAGE $@"
	$(Q) docker build -f Dockerfile -t $@ . 1>$o 2>$e
	$(Q) touch $@

qemu-aarch64-static:
	$(E) "GET   $@"
	$(Q) wget -qN https://github.com/multiarch/qemu-user-static/releases/download/v2.9.1-1/$@

/proc/sys/fs/binfmt_misc/qemu-aarch64:
	$(E) 'You need to configure qemu-aarch64-static for aarch64 programs, for example:'
	$(E)
	$(E) '        docker run --rm --privileged multiarch/qemu-user-static:register --reset'
	$(E)
	$(E) 'and can disable all binfmt with:'
	$(E)
	$(E) '        echo -1 > /proc/sys/fs/binfmt_misc/status'
	$(E)
	$(Q) exit 1

clean:
	$(Q) rm -rf assets-* Dockerfile.aarch64 osie-alpine-initramfs-builder-* qemu-aarch64-static
	$(Q) docker rmi osie-alpine-initramfs-builder-aarch64 osie-alpine-initramfs-builder-x86_64 1>$o 2>$e
