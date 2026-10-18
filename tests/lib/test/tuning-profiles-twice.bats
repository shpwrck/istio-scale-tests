#!/usr/bin/env bats
# Tuning 003 refuses a profile listed twice in --profiles (each pass writes to a directory
# named after its profile, so a second pass would mix into the first's): a whole-run
# precondition, before any kubectl call or result dir, under --dry-run too. No cluster:
# kubectl is a stub that logs each call.

bats_require_minimum_version 1.5.0
load test_helper

@test "tuning 003 refuses a profile listed twice in --profiles (also as <name>.yaml), with and without --dry-run, before any kubectl call or result dir" {
	local bin="${BATS_TEST_TMPDIR}/bin" kc="${BATS_TEST_TMPDIR}/kubeconfig" res="${BATS_TEST_TMPDIR}/tres" dry
	local -a args
	mkdir -p "$bin"
	: > "$kc"
	export KLOG="${BATS_TEST_TMPDIR}/klog"
	printf '#!/bin/sh\necho "$*" >> "$KLOG"\nexit 1\n' > "${bin}/kubectl"
	chmod +x "${bin}/kubectl"
	for dry in 1 0; do
		args=()
		if ((dry)); then args=(--dry-run); fi
		PATH="${bin}:${PATH}" KUBECONFIG="$kc" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
			--suite churn --contexts ci-a --no-gitops-pause --output-dir "$res" \
			--profiles 01-push-throttling,02-xds-cache-off,01-push-throttling.yaml ${args[@]+"${args[@]}"}
		[ "$status" -eq 1 ] || { echo "dry=${dry} status ${status}: ${stderr}"; false; }
		[ "$stderr" = "error: profile listed twice in --profiles: 01-push-throttling (each pass writes to a directory named after its profile): list each once" ] \
			|| { echo "dry=${dry}: ${stderr}"; false; }
	done
	[ ! -e "$KLOG" ]
	[ ! -e "$res" ]
	# Each profile once still passes the parser.
	PATH="${bin}:${PATH}" KUBECONFIG="$kc" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite churn --contexts ci-a --no-gitops-pause --output-dir "$res" \
		--profiles 01-push-throttling,02-xds-cache-off --dry-run
	assert_success
	[[ "$stderr" != *"listed twice"* ]]
}
