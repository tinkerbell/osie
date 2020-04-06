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

cprs := $(shell git ls-files ci/cpr/)
grubs := $(shell git ls-files grub/)
osiesrcs := $(shell git ls-files docker/)

E=@echo
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

define packager_parch
.PHONY: package-$1
packaged-$1 := $$(addprefix build/$$v/, initramfs-$1 modloop-$1 vmlinuz-$1)
package-$1: $${packaged-$1}
endef
$(foreach parch,$(parches),$(eval $(call packager_parch,$(parch))))


packaged-apps := $(addprefix build/$v/, osie-installer.sh osie-installer-rc rescue-helper.sh rescue-helper-rc runner.sh runner-rc workflow-helper.sh workflow-helper-rc)
packaged-grubs := $(addprefix build/$v/,$(subst -,/,${grubs}))
packaged-osies := build/$v/osie-aarch64.tar.gz build/$v/osie-x86_64.tar.gz
packaged-repos := build/$v/repo-aarch64 build/$v/repo-x86_64
packages := ${packaged-apps} ${packaged-grubs} ${packaged-osies} ${packaged-repos} build/$v/osie-runner-x86_64.tar.gz
$(eval packages += $(foreach parch,$(parches),$${packaged-$(parch)}))

package: build/$v.tar.gz build/$v.tar.gz.sha512sum
package-common: package-apps package-grubs
package-apps: ${packaged-apps}
package-grubs: ${packaged-grubs}
package-osies: ${packaged-osies}
package-repos: ${packaged-repos}

deploy: package
	$(E) "UPLOAD   s3/tinkerbell-oss/osie-uploads/$v.tar.gz"
	$(Q)mc cp build/$v.tar.gz s3/tinkerbell-oss/osie-uploads/$v.tar.gz
	$(Q)echo "deploy this build with the following command:"
	$(Q)echo -n "./scripts/deploy osie update $v -m \"$$"
	$(Q)echo -n "(sed -n '/^## \[/,$$ {/\S/!q; p}' CHANGELOG.md)\" "
	$(Q)echo -n "$$(sed 's|.*= ||' build/$v.tar.gz.sha512sum)"
	$(Q)echo

upload-test: ${packages}
	$(E) "UPLOAD   s3/tinkerbell-oss/osie-uploads/osie-testing/$v/"
	$(Q)mc cp --recursive build/$v/ s3/tinkerbell-oss/osie-uploads/osie-testing/$v/ || ( \
		session=$$(mc session list --json | jq -r .sessionId); \
		for i in {1..5}; do \
			mc session resume $$session && exit 0; \
		done; \
		mc session clear $$sesion; \
		exit 1; \
	)

build/$v.tar.gz: ${packages}
	$(E) "TAR.GZ   $@"
	$(Q)cd build && \
		tar -cO $(sort $(subst build/,,$^)) | pigz >$(@F).tmp && \
		mv $(@F).tmp $(@F)

build/$v.tar.gz.sha512sum: build/$v.tar.gz
	$(E) "SHASUM   $@"
	$(Q)sha512sum --tag $^ | sed 's|build/||' >$@

${packaged-grubs}: ${grubs}
	$(E) "INSTALL  $@"
	$(Q)install -Dm644 $(addprefix grub/,$(subst /,-,$(patsubst build/$v/grub/%,%,$@))) $@

build/$v/osie-installer-rc: installer/osie-installer-rc
build/$v/osie-installer.sh: installer/osie-installer.sh
build/$v/rescue-helper-rc: installer/rescue-helper-rc
build/$v/rescue-helper.sh: installer/rescue-helper.sh
build/$v/workflow-helper-rc: installer/workflow-helper-rc
build/$v/workflow-helper.sh: installer/workflow-helper.sh
build/$v/runner-rc: installer/runner-rc
build/$v/runner.sh: installer/runner.sh
${packaged-apps}:
	$(E) "INSTALL  $@"
	$(Q)install -D -m644 $< $@

build/$v/osie-%: build/osie-%
	$(E) "INSTALL  $@"
	$(Q)install -D -m644 $< $@

define initramfs_builder_arch_parch
build/$$v/initramfs-$2: build/$$v-rootfs-$2 installer/alpine/init-$1
	$(E) "CPIO     $$@"
	$(Q) install -m755 installer/alpine/init-$1 build/$$v-rootfs-$2/init
	$(Q) (cd build/$$v-rootfs-$2 && find -print0 | bsdcpio --null --quiet -oH newc | pigz -9) >$$@.osied
	$(Q) install -D -m644 $$@.osied $$@
	$(Q) touch $$@
endef
$(foreach parch,$(x86s),$(eval $(call initramfs_builder_arch_parch,x86_64,$(parch))))
$(foreach parch,$(arms),$(eval $(call initramfs_builder_arch_parch,aarch64,$(parch))))

build/$v/modloop-%: build/modloop-%
	$(E) "INSTALL  $@"
	$(Q)install -D -m644 $< $@

build/$v/vmlinuz-%: build/vmlinuz-%
	$(E) "INSTALL  $@"
	$(Q)install -D -m644 $< $@

build/$v/test-initramfs-%/test-initramfs: build/$v/initramfs-% installer/alpine/init-%
	$(E) "BUILD    $@"
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

define test_arch
test-$1: $(cprs) build/osie-test-env package-apps package-grubs build/$v/osie-$1.tar.gz build/$v/osie-runner-$1.tar.gz build/$v/repo-$1 $${packaged-$1} ci/ifup.sh ci/vm.sh build/$v/test-initramfs-$1/test-initramfs
	$(E) "DOCKER   $$@"
ifneq ($(CI),drone)
	$(Q)docker run --rm -ti \
		--privileged \
		--name $$(@F) \
		--volume $(CURDIR):/osie:ro \
		--env OSES \
		--env UEFI \
		osie-test-env \
		/osie/ci/vm.sh tests -C /osie/build/$v -k vmlinuz-$1 -i test-initramfs-$1/test-initramfs -m modloop-$1 -a $1 2>&1 | tee build/$$@.log >/dev/$T
else
		ci/vm.sh tests -C build/$v -k vmlinuz-$1 -i test-initramfs-$1/test-initramfs -m modloop-$1 -a $1 2>&1 | tee build/$$@.log >/dev/$T
endif
endef
$(foreach arch,aarch64 x86_64,$(eval $(call test_arch,$(arch))))

build/$v-rootfs-%: build/initramfs-%
	$(E) "EXTRACT  $@"
	$(Q)rm -rf $@
	$(Q)mkdir $@
	$(Q)bsdtar -xf $< -C $@

test-packet-networking: build/osie-test-env docker/scripts/packet-networking ci/test-network.sh $(shell find ci/network-test-files/ -type f | grep -v ':')
	$(E) "DOCKER   $@"
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

build/osie-test-env: ci/Dockerfile
	docker build -t osie-test-env ci 2>&1 | tee $@.log >/dev/$T
	touch $@

build/osie-aarch64.tar.gz: SED=/FROM/ s|.*|FROM multiarch/ubuntu-debootstrap:arm64-xenial|
build/osie-x86_64.tar.gz: SED=
build/osie-%.tar.gz: docker/Dockerfile ${osiesrcs}
	$(E) "DOCKER   $@"
	$(Q)sed '${SED}' $< > $<.$*
	$(Q)docker build -t osie:$* -f $<.$* $(<D) 2>&1 | tee $@.log >/dev/$T
	$(Q)docker save osie:$* > $@.tmp
	$(Q)mv $@.tmp $@

build/osie-runner-aarch64.tar.gz: SED=/FROM/ s|.*|FROM multiarch/alpine:arm64-v3.7|
build/osie-runner-x86_64.tar.gz: SED=
build/osie-runner-%.tar.gz: osie-runner/Dockerfile $(shell git ls-files osie-runner)
	$(E) "DOCKER   $@"
	$(Q)sed '${SED}' $< > $<.$*
	$(Q)docker build -t osie-runner:$* -f $<.$* $(<D) 2>&1 | tee $@.log >/dev/$T
	$(Q)docker save osie-runner:$* > $@.tmp
	$(Q)mv $@.tmp $@

build/osie-runner-aarch64.tar.gz:
	$(E) "FAKE     $@"
	$(Q) touch $@

# aarch64
build/$v/repo-aarch64:
	$(E) "LN       $@"
	$(Q)ln -nsf ../../../alpine/edge $@

build/repo-aarch64:
	$(Q)echo edge > $@

build/$v/repo-x86_64:
	$(E) "LN       $@"
	$(Q)ln -nsf ../../../alpine/v${alpine_version_x86_64} $@

build/repo-x86_64:
	$(Q)echo v${alpine_version_x86_64} > $@


define fetcher_arch_parch
build/initramfs-$2: installer/alpine/assets-$2/initramfs
build/modloop-$2:   installer/alpine/assets-$2/modloop
build/vmlinuz-$2:   installer/alpine/assets-$2/vmlinuz
build/initramfs-$2 build/modloop-$2 build/vmlinuz-$2:
	$(Q)ln -nsf ../$$< $$@
endef
$(foreach parch,$(x86s),$(eval $(call fetcher_arch_parch,x86_64,$(parch))))
$(foreach parch,$(arms),$(eval $(call fetcher_arch_parch,aarch64,$(parch))))

.PHONY: check-checksums clean fetch info
fetch: $(foreach parch,$(parches), build/initramfs-$(parch) build/modloop-$(parch) build/vmlinuz-$(parch))

checksums :=
define checksums_builder_parch
checksums += $${checksum_$1_initramfs}  build/initramfs-$1
checksums += $${checksum_$1_modloop}  build/modloop-$1
checksums += $${checksum_$1_vmlinuz}  build/vmlinuz-$1
endef
$(foreach parch,$(parches),$(eval $(call checksums_builder_parch,$(parch))))
check-checksums:
	$(E) "${checksums}" | sed -e 's|^ ||' -e 's|\(\S\) \(\S\)|\1\n\2|g' | sha512sum -c | sort
