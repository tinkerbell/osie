alpine_version_aarch64 := 3.4
alpine_version_x86_64 := 3.7

arches := aarch64 x86_64
x86s := x86_64
arms := 2a2 aarch64 amp hua qcom tx2
parches := $(sort $(arms) $(x86s))

target_checksum = $(word 4,$(subst -, ,$(1)))
build_path = $(word 3,$(1))/$(word 2,$(1))-vanilla-$(word 1,$(1))
target_to_path = $(call build_path,$(subst -, ,$(1)))

SHELL := bash
.SHELLFLAGS := -o pipefail -c

.SUFFIXES:
MAKEFLAGS +=  --no-builtin-rules

v := $(shell git describe --dirty)
ifeq (-g,$(findstring -g,$v))
build_git_version := true
endif
ifeq (-dirty,$(findstring -dirty,$v))
build_git_version := true
endif

ifeq (true,${build_git_version})
t := $(word 1, $(subst -, ,$v))
n := $(word 2, $(subst -, ,$v))
c := $(shell git rev-parse --short HEAD)
d := ,dirty
d := $(subst dirty,$d,$(findstring dirty,$v))
b := $(shell git symbolic-ref HEAD | sed -e 's|^refs/heads/||' -e 's|/|-|g' -e 's|^|,b=|')
v := $t-n=$n,c=$c$b$d
v := $(patsubst %dirty,dirty,$v)
endif
v := osie-$v

# ensure build/$v always exists without having to add as an explicit dependency
$(shell mkdir -p build/$v)

apps := $(shell git ls-files apps/)
cprs := $(shell git ls-files ci/cpr/)
grubs := $(shell git ls-files grub/)
osiesrcs := $(shell git ls-files docker/)

E=@echo
E+=
ifeq ($(V),1)
Q=
else
Q=@
endif

ifeq ($(T),1)
override undefine T
T := stdout
else
override undefine T
T := null
endif

.PHONY: all deploy package package-apps package-grubs test test-aarch6 test-x86_64 test-packet-networking v
all: build/$v/osie-aarch64.tar.gz build/$v/osie-x86_64.tar.gz
test: test-aarch64 test-x86_64 test-packet-networking
v:
	@echo $v

packaged-apps := $(subst apps/,build/$v/,${apps})
packaged-grubs := $(addprefix build/$v/,$(subst -,/,${grubs}))
packaged-osie-runners := build/$v/osie-runner-x86_64.tar.gz
packaged-osies := build/$v/osie-aarch64.tar.gz build/$v/osie-x86_64.tar.gz
packaged-repos := build/$v/repo-aarch64 build/$v/repo-x86_64
packages := ${packaged-apps} ${packaged-grubs} ${packaged-osie-runners} ${packaged-osies} ${packaged-repos}

.PHONY: package-2a2 package-aarch64 package-amp package-hua package-qcom package-tx2 package-x86_64
packaged-2a2 := build/$v/initramfs-2a2 build/$v/modloop-2a2 build/$v/vmlinuz-2a2
package-2a2: ${packaged-2a2}
packages += ${packaged-2a2}
packaged-aarch64 := build/$v/initramfs-aarch64 build/$v/modloop-aarch64 build/$v/vmlinuz-aarch64
package-aarch64: ${packaged-aarch64}
packages += ${packaged-aarch64}
packaged-amp := build/$v/initramfs-amp build/$v/modloop-amp build/$v/vmlinuz-amp
package-amp: ${packaged-amp}
packages += ${packaged-amp}
packaged-hua := build/$v/initramfs-hua build/$v/modloop-hua build/$v/vmlinuz-hua
package-hua: ${packaged-hua}
packages += ${packaged-hua}
packaged-qcom := build/$v/initramfs-qcom build/$v/modloop-qcom build/$v/vmlinuz-qcom
package-qcom: ${packaged-qcom}
packages += ${packaged-qcom}
packaged-tx2 := build/$v/initramfs-tx2 build/$v/modloop-tx2 build/$v/vmlinuz-tx2
package-tx2: ${packaged-tx2}
packages += ${packaged-tx2}
packaged-x86_64 := build/$v/initramfs-x86_64 build/$v/modloop-x86_64 build/$v/vmlinuz-x86_64
package-x86_64: ${packaged-x86_64}
packages += ${packaged-x86_64}


package: build/$v.tar.gz build/$v.tar.gz.sha512sum
package-common: package-apps package-grubs
package-apps: ${packaged-apps}
package-grubs: ${packaged-grubs}
package-osies: ${packaged-osies}
package-repos: ${packaged-repos}

deploy: package
	$(E)"UPLOAD   s3/tinkerbell-oss/osie-uploads/$v.tar.gz"
	$(Q)mc cp build/$v.tar.gz s3/tinkerbell-oss/osie-uploads/$v.tar.gz
	$(Q)if [[ $${DRONE_BRANCH:-} == "master" ]]; then mc cp s3/tinkerbell-oss/osie-uploads/$v.tar.gz s3/tinkerbell-oss/osie-uploads/latest.tar.gz; fi
	$(Q)echo "deploy this build with the following command:"
	$(Q)echo -n "./scripts/deploy osie update $v -m \"$$"
	$(Q)echo -n "(sed -n '/^## \[/,$$ {/\S/!q; p}' CHANGELOG.md)\" "
	$(Q)echo -n "$$(sed 's|.*= ||' build/$v.tar.gz.sha512sum)"
	$(Q)echo

upload-test: ${packages}
	$(E)"UPLOAD   s3/tinkerbell-oss/osie-uploads/osie-testing/$v/"
	$(Q)mc cp --recursive build/$v/ s3/tinkerbell-oss/osie-uploads/osie-testing/$v/ || ( \
		session=$$(mc session list --json | jq -r .sessionId); \
		for i in {1..5}; do \
			mc session resume $$session && exit 0; \
		done; \
		mc session clear $$sesion; \
		exit 1; \
	)

build/$v.tar.gz: ${packages}
	$(E)"TAR.GZ   $@"
	$(Q)cd build && \
		tar -cO $(sort $(subst build/,,$^)) | pigz >$(@F).tmp && \
		mv $(@F).tmp $(@F)

build/$v.tar.gz.sha512sum: build/$v.tar.gz
	$(E)"SHASUM   $@"
	$(Q)sha512sum --tag $^ | sed 's|build/||' >$@

${packaged-grubs}: ${grubs}
	$(E)"INSTALL  $@"
	$(Q)install -Dm644 $(addprefix grub/,$(subst /,-,$(patsubst build/$v/grub/%,%,$@))) $@

build/$v/%-rc: apps/%-rc
	$(E)"INSTALL  $@"
	$(Q)install -D -m644 $< $@

build/$v/%.sh: apps/%.sh
	$(E)"INSTALL  $@"
	$(Q)install -D -m644 $< $@

build/$v/osie-%: build/osie-%
	$(E)"INSTALL  $@"
	$(Q)install -D -m644 $< $@


build/$v/initramfs-2a2: build/$v-rootfs-2a2 installer/alpine/init-aarch64
	$(E)"CPIO     $@"
	$(Q) install -m755 installer/alpine/init-aarch64 build/$v-rootfs-2a2/init
	$(Q) (cd build/$v-rootfs-2a2 && find -print0 | bsdcpio --null --quiet -oH newc | pigz -9) >$@.osied
	$(Q) install -D -m644 $@.osied $@
	$(Q) touch $@

build/$v/initramfs-aarch64: build/$v-rootfs-aarch64 installer/alpine/init-aarch64
	$(E)"CPIO     $@"
	$(Q) install -m755 installer/alpine/init-aarch64 build/$v-rootfs-aarch64/init
	$(Q) (cd build/$v-rootfs-aarch64 && find -print0 | bsdcpio --null --quiet -oH newc | pigz -9) >$@.osied
	$(Q) install -D -m644 $@.osied $@
	$(Q) touch $@

build/$v/initramfs-amp: build/$v-rootfs-amp installer/alpine/init-aarch64
	$(E)"CPIO     $@"
	$(Q) install -m755 installer/alpine/init-aarch64 build/$v-rootfs-amp/init
	$(Q) (cd build/$v-rootfs-amp && find -print0 | bsdcpio --null --quiet -oH newc | pigz -9) >$@.osied
	$(Q) install -D -m644 $@.osied $@
	$(Q) touch $@

build/$v/initramfs-hua: build/$v-rootfs-hua installer/alpine/init-aarch64
	$(E)"CPIO     $@"
	$(Q) install -m755 installer/alpine/init-aarch64 build/$v-rootfs-hua/init
	$(Q) (cd build/$v-rootfs-hua && find -print0 | bsdcpio --null --quiet -oH newc | pigz -9) >$@.osied
	$(Q) install -D -m644 $@.osied $@
	$(Q) touch $@

build/$v/initramfs-qcom: build/$v-rootfs-qcom installer/alpine/init-aarch64
	$(E)"CPIO     $@"
	$(Q) install -m755 installer/alpine/init-aarch64 build/$v-rootfs-qcom/init
	$(Q) (cd build/$v-rootfs-qcom && find -print0 | bsdcpio --null --quiet -oH newc | pigz -9) >$@.osied
	$(Q) install -D -m644 $@.osied $@
	$(Q) touch $@

build/$v/initramfs-tx2: build/$v-rootfs-tx2 installer/alpine/init-aarch64
	$(E)"CPIO     $@"
	$(Q) install -m755 installer/alpine/init-aarch64 build/$v-rootfs-tx2/init
	$(Q) (cd build/$v-rootfs-tx2 && find -print0 | bsdcpio --null --quiet -oH newc | pigz -9) >$@.osied
	$(Q) install -D -m644 $@.osied $@
	$(Q) touch $@

build/$v/initramfs-x86_64: build/$v-rootfs-x86_64 installer/alpine/init-x86_64
	$(E)"CPIO     $@"
	$(Q) install -m755 installer/alpine/init-x86_64 build/$v-rootfs-x86_64/init
	$(Q) (cd build/$v-rootfs-x86_64 && find -print0 | bsdcpio --null --quiet -oH newc | pigz -9) >$@.osied
	$(Q) install -D -m644 $@.osied $@
	$(Q) touch $@


build/$v/modloop-%: build/modloop-%
	$(E)"INSTALL  $@"
	$(Q)install -D -m644 $< $@

build/$v/vmlinuz-%: build/vmlinuz-%
	$(E)"INSTALL  $@"
	$(Q)install -D -m644 $< $@

build/$v/test-initramfs-%/test-initramfs: build/$v/initramfs-% installer/alpine/init-%
	$(E)"BUILD    $@"
	$(Q) rm -rf $(@D)
	$(Q) mkdir -p $(@D)
	$(Q) cp $^ $(@D)/
	$(Q) mv $(@D)/$(<F) $(@D)/initramfs.cpio.gz
	$(Q) cd $(@D) && \
		sed -i 's|curl |curl --insecure |g' init-* && \
		mv init-* init && \
		chmod +x init && \
		gunzip initramfs.cpio.gz && \
		echo init | cpio -oH newc --append -O initramfs.cpio && \
		pigz -9 initramfs.cpio && \
		mv initramfs.cpio.gz $(@F)

build/osie-test-env: ci/Dockerfile
	docker build -t osie-test-env ci 2>&1 | tee $@.log >/dev/$T
	touch $@

test-aarch64: $(cprs) build/osie-test-env package-apps package-grubs build/$v/osie-aarch64.tar.gz build/$v/osie-runner-aarch64.tar.gz build/$v/repo-aarch64 ${packaged-aarch64} ci/ifup.sh ci/vm.sh build/$v/test-initramfs-aarch64/test-initramfs
	$(E)"DOCKER   $@"
ifneq ($(CI),drone)
	$(Q)docker run --rm -ti \
		--privileged \
		--name $(@F) \
		--volume $(CURDIR):/osie:ro \
		--env OSES \
		--env UEFI \
		osie-test-env \
		/osie/ci/vm.sh tests -C /osie/build/$v -k vmlinuz-aarch64 -i test-initramfs-aarch64/test-initramfs -m modloop-aarch64 -a aarch64 2>&1 | tee build/$@.log >/dev/$T
else
		ci/vm.sh tests -C build/$v -k vmlinuz-aarch64 -i test-initramfs-aarch64/test-initramfs -m modloop-aarch64 -a aarch64 2>&1 | tee build/$@.log >/dev/$T
endif
test-x86_64: $(cprs) build/osie-test-env package-apps package-grubs build/$v/osie-x86_64.tar.gz build/$v/osie-runner-x86_64.tar.gz build/$v/repo-x86_64 ${packaged-x86_64} ci/ifup.sh ci/vm.sh build/$v/test-initramfs-x86_64/test-initramfs
	$(E)"DOCKER   $@"
ifneq ($(CI),drone)
	$(Q)docker run --rm -ti \
		--privileged \
		--name $(@F) \
		--volume $(CURDIR):/osie:ro \
		--env OSES \
		--env UEFI \
		osie-test-env \
		/osie/ci/vm.sh tests -C /osie/build/$v -k vmlinuz-x86_64 -i test-initramfs-x86_64/test-initramfs -m modloop-x86_64 -a x86_64 2>&1 | tee build/$@.log >/dev/$T
else
		ci/vm.sh tests -C build/$v -k vmlinuz-x86_64 -i test-initramfs-x86_64/test-initramfs -m modloop-x86_64 -a x86_64 2>&1 | tee build/$@.log >/dev/$T
endif


build/$v-rootfs-%: build/initramfs-%
	$(E)"EXTRACT  $@"
	$(Q)rm -rf $@
	$(Q)mkdir $@
	$(Q)bsdtar -xf $< -C $@

test-packet-networking: build/osie-test-env docker/scripts/packet-networking ci/test-network.sh $(shell find ci/network-test-files/ -type f | grep -v ':')
	$(E)"DOCKER   $@"
ifneq ($(CI),drone)
	$(Q)docker run --rm -ti \
		--name $(@F) \
		--dns=147.75.207.207 \
		--cap-add=NET_ADMIN \
		--volume "$(CURDIR):/$(CURDIR):ro" \
		--volume "$(CURDIR)/network-coverage/:/coverage" \
		--workdir "$(CURDIR)" \
		-e MAKERS=${MAKERS} \
		-e MODES=${MODES} \
		-e OSES=${OSES} \
		-e TYPES=${TYPES} \
		osie-test-env \
		ci/vm.sh network_test | tee build/$@.log >/dev/$T
else
	mkdir -p build/network-coverage
	ln -nsf $(CURDIR)/build/network-coverage /coverage
	ci/vm.sh network_test | tee build/$@.log >/dev/$T
endif

build/osie-aarch64.tar.gz: SED=/FROM/ s|.*|FROM multiarch/ubuntu-debootstrap:arm64-xenial|
build/osie-x86_64.tar.gz: SED=
build/osie-%.tar.gz: docker/Dockerfile ${osiesrcs}
	$(E)"DOCKER   $@"
	$(Q)sed '${SED}' $< > $<.$*
	$(Q)docker build -t osie:$* -f $<.$* $(<D) 2>&1 | tee $@.log >/dev/$T
	$(Q)docker save osie:$* > $@.tmp
	$(Q)mv $@.tmp $@

build/osie-runner-aarch64.tar.gz: SED=/FROM/ s|.*|FROM multiarch/alpine:arm64-v3.7|
build/osie-runner-x86_64.tar.gz: SED=
build/osie-runner-%.tar.gz: osie-runner/Dockerfile $(shell git ls-files osie-runner)
	$(E)"DOCKER   $@"
	$(Q)sed '${SED}' $< > $<.$*
	$(Q)docker build -t osie-runner:$* -f $<.$* $(<D) 2>&1 | tee $@.log >/dev/$T
	$(Q)docker save osie-runner:$* > $@.tmp
	$(Q)mv $@.tmp $@

build/osie-runner-aarch64.tar.gz:
	$(E)"FAKE     $@"
	$(Q) touch $@

build/$v/repo-aarch64:
	$(E)"LN       $@"
	$(Q)ln -nsf ../../../alpine/edge $@

build/repo-aarch64:
	$(Q)echo edge > $@

build/$v/repo-x86_64:
	$(E)"LN       $@"
	$(Q)ln -nsf ../../../alpine/v${alpine_version_x86_64} $@

build/repo-x86_64:
	$(Q)echo v${alpine_version_x86_64} > $@


build/initramfs-2a2: installer/alpine/assets-2a2/initramfs
build/modloop-2a2:   installer/alpine/assets-2a2/modloop
build/vmlinuz-2a2:   installer/alpine/assets-2a2/vmlinuz
build/initramfs-2a2 build/modloop-2a2 build/vmlinuz-2a2:
	$(E)"LN       $@"
	$(Q)ln -nsf ../$< $@

build/initramfs-aarch64: installer/alpine/assets-aarch64/initramfs
build/modloop-aarch64:   installer/alpine/assets-aarch64/modloop
build/vmlinuz-aarch64:   installer/alpine/assets-aarch64/vmlinuz
build/initramfs-aarch64 build/modloop-aarch64 build/vmlinuz-aarch64:
	$(E)"LN       $@"
	$(Q)ln -nsf ../$< $@

build/initramfs-amp: installer/alpine/assets-amp/initramfs
build/modloop-amp:   installer/alpine/assets-amp/modloop
build/vmlinuz-amp:   installer/alpine/assets-amp/vmlinuz
build/initramfs-amp build/modloop-amp build/vmlinuz-amp:
	$(E)"LN       $@"
	$(Q)ln -nsf ../$< $@

build/initramfs-hua: installer/alpine/assets-hua/initramfs
build/modloop-hua:   installer/alpine/assets-hua/modloop
build/vmlinuz-hua:   installer/alpine/assets-hua/vmlinuz
build/initramfs-hua build/modloop-hua build/vmlinuz-hua:
	$(E)"LN       $@"
	$(Q)ln -nsf ../$< $@

build/initramfs-qcom: installer/alpine/assets-qcom/initramfs
build/modloop-qcom:   installer/alpine/assets-qcom/modloop
build/vmlinuz-qcom:   installer/alpine/assets-qcom/vmlinuz
build/initramfs-qcom build/modloop-qcom build/vmlinuz-qcom:
	$(E)"LN       $@"
	$(Q)ln -nsf ../$< $@

build/initramfs-tx2: installer/alpine/assets-tx2/initramfs
build/modloop-tx2:   installer/alpine/assets-tx2/modloop
build/vmlinuz-tx2:   installer/alpine/assets-tx2/vmlinuz
build/initramfs-tx2 build/modloop-tx2 build/vmlinuz-tx2:
	$(E)"LN       $@"
	$(Q)ln -nsf ../$< $@

build/initramfs-x86_64: installer/alpine/assets-x86_64/initramfs
build/modloop-x86_64:   installer/alpine/assets-x86_64/modloop
build/vmlinuz-x86_64:   installer/alpine/assets-x86_64/vmlinuz
build/initramfs-x86_64 build/modloop-x86_64 build/vmlinuz-x86_64:
	$(E)"LN       $@"
	$(Q)ln -nsf ../$< $@
