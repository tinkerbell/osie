SHELL := bash
.SHELLFLAGS := -o pipefail -c

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
