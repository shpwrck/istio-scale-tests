#!/usr/bin/env bats
# On an ACM hub, `oc get application` (or app, apps, applications) resolves to ACM's
# applications.app.k8s.io, not Argo CD's applications.argoproj.io, so a read of an Argo CD
# Application by the short name finds nothing: the documented mesh-verify apply stopped on an
# empty REPO on a live hub. Every oc/kubectl command the repo documents or runs on Argo CD
# Applications names the group.

bats_require_minimum_version 1.5.0
load test_helper

@test "oc/kubectl commands on Argo CD Applications name applications.argoproj.io" {
	cd "$ROOT"
	run git grep -n -E \
		'(^|[[:space:]`(])(get|patch|delete|wait|describe|edit|annotate|label)[[:space:]]+(app|apps|application|applications)([[:space:]]|/|$)' \
		-- . ':!tests/lib/test/argocd-resource-names.bats'
	assert_failure 1
	assert_output ""
}
