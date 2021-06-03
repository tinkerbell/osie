-include rules.mk

rules.mk: rules.mk.j2 rules.mk.json
	@j2 -f json $^ > $@
