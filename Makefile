# Only use the recipes defined in these makefiles
MAKEFLAGS += --no-builtin-rules
.SUFFIXES:
# Delete target files if there's an error
# This avoids a failure to then skip building on next run if the output is created by shell redirection for example
.DELETE_ON_ERROR:
# Use bash instead of plain sh
SHELL := bash
.SHELLFLAGS := -o pipefail -euc

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
