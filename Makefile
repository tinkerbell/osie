help: ## Print this help
	@grep --no-filename -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sed 's/:.*##/·/' | sort | column -ts '·' -c 120
	
rules.mk: rules.mk.j2 rules.mk.json
	@j2 -f json $^ > $@

-include rules.mk

all: build/osie-$v/osie-aarch64.tar.gz build/osie-$v/osie-x86_64.tar.gz ## Build the osie container images

package: build/osie-$v.tar.gz build/osie-$v.tar.gz.sha512sum  ## Bundle up all the files needed for an OSIE release

package-common: package-apps package-grubs ## Bundle up all the architecture independent files

deploy: deploy-to-s3 ## Upload the packaged release to S3

test: test-aarch64 test-x86_64 ## Run VM based tests
