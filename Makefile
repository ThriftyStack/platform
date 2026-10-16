HELM ?= helm
CHART_CACHE ?=
STAGE ?=
CLUSTER ?= management
export THRIFTY_CLUSTER ?= $(CLUSTER)

.PHONY: status promote promote-pr pki-sign pki-trust verify-mesh verify-mesh-renewal check

status:
	ruby ops/status.rb

promote:
	@test -n "$(STAGE)" || (echo 'Set STAGE=<vault|pki|certificates|istio|qualification|enrollment>'; exit 1)
	ruby ops/promote.rb $(STAGE)

promote-pr:
	@test -n "$(STAGE)" || (echo 'Set STAGE=<vault|pki|certificates|istio|qualification|enrollment>'; exit 1)
	ruby ops/promote-pr.rb $(STAGE)

pki-sign:
	ruby ops/pki-handoff.rb sign

pki-trust:
	ruby ops/pki-handoff.rb trust

verify-mesh:
	python3 ops/verify-mesh.py

# Observes natural leaf renewal for up to ~70 minutes; writes gitignored .evidence/<cluster>/renewal.json.
verify-mesh-renewal:
	python3 ops/verify-mesh.py --permissive --renewal

check:
	@test -n "$(CHART_CACHE)" || (echo 'Set CHART_CACHE to an operator cache directory.'; exit 1)
	python3 ops/fetch-dependencies.py "$(CHART_CACHE)"
	CHART_CACHE=$(CHART_CACHE) HELM=$(HELM) ruby ops/check.rb
	python3 ops/verify-mesh.py --self-test
