# Only use the recipes defined in these makefiles
MAKEFLAGS += --no-builtin-rules
.SUFFIXES:
# Delete target files if there's an error
# This avoids a failure to then skip building on next run if the output is created by shell redirection for example
.DELETE_ON_ERROR:
# Treat the whole recipe as a one shell script/invocation instead of one-per-line
.ONESHELL:
# Use bash instead of plain sh
SHELL := bash
.SHELLFLAGS := -o pipefail -euc

ifeq ($(V),1)
E := :
else
E := @echo
endif

-include rules.mk

rules.mk: rules.mk.j2 rules.mk.json
	$(E) "JINJA    $@"
	j2 -f json $^ > $@
