SHELL := bash
.SHELLFLAGS := -o pipefail -c

#.NOTPARALLEL:
#-include Makefile.buildxsh


.SUFFIXES:
MAKEFLAGS +=  --no-builtin-rules

.DELETE_ON_ERROR:

E=@echo
ifeq ($(V),1)
Q=
else
Q=@
endif

#.NOTPARALLEL:
#-include Makefile.buildxsh

-include rules.mk

#        $(E) buildxsh
#        $(Q) curl -L raw.githubusercontent.com/MaxPeal/docker-scripts/master/install-docker-buildx.sh -o install-docker-buildx.sh && chmod 755 install-docker-buildx.sh && ./install-docker-buildx.sh


#.NOTPARALLEL:
rules.mk: rules.mk.j2 rules.mk.json
#	$(E) buildxsh
#	$(Q) curl -L raw.githubusercontent.com/MaxPeal/docker-scripts/master/install-docker-buildx.sh -o install-docker-buildx.sh && chmod 755 install-docker-buildx.sh && ./install-docker-buildx.sh
	$(E) "JINJA    $@"
	$(Q) j2 -f json $^ > $@

#-include Makefile.buildxsh

