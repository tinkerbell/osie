-include rules.mk

all: build/$v/osie-aarch64.tar.gz build/$v/osie-x86_64.tar.gz

package: build/$v.tar.gz build/$v.tar.gz.sha512sum

package-common: package-apps package-grubs

deploy: deploy-to-s3

test: test-aarch64 test-x86_64
	
rules.mk: rules.mk.j2 rules.mk.json
	@j2 -f json $^ > $@
