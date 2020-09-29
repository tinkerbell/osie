SHELL := bash
.SHELLFLAGS := -o pipefail -c

#+buildx-sh
buildx-sh:
	curl -L raw.githubusercontent.com/MaxPeal/docker-scripts/master/install-docker-buildx.sh -o install-docker-buildx.sh
	chmod 755 install-docker-buildx.sh
	./install-docker-buildx.sh


.SUFFIXES:
MAKEFLAGS +=  --no-builtin-rules

.DELETE_ON_ERROR:

E=@echo
ifeq ($(V),1)
Q=
else
Q=@
endif

-include rules.mk

rules.mk: rules.mk.j2 rules.mk.json
	$(E) "JINJA    $@"
	$(Q) j2 -f json $^ > $@
