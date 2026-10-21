#!/usr/bin/env bats
# tuning 003's dry run stopped during its probe check leaves nothing in TMPDIR. Through the
# real script (PL33); no cluster: kubectl is never reached. The sweep's Istio CR checks are
# in tuning-generations.bats.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 METRICS_READY_TIMEOUT=0
}

@test "tuning 003's dry run stopped during its probe check leaves nothing in TMPDIR" {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed (tuning lib)"
	# A SIGTERM while a probe checks its arguments (the probe's bash sends it to 003) ends 003
	# once that probe returns, and its EXIT trap removes the check's dir.
	local realbash t
	realbash="$(command -v bash)"
	t="${BATS_TEST_TMPDIR}/tmp-dry"
	mkdir -p "$t"
	printf '#!/bin/sh\ncase "$*" in *--dry-run*) [ -e "$DRY_SENT" ] || { : > "$DRY_SENT"; kill -TERM "$PPID"; } ;; esac\nexec %s "$@"\n' "$realbash" > "${BIN}/bash"
	chmod +x "${BIN}/bash"
	DRY_SENT="${BATS_TEST_TMPDIR}/dry-sent" TMPDIR="$t" PATH="${BIN}:${PATH}" KUBECONFIG="$EK" \
		run "$realbash" "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" --suite churn-dataplane --contexts ci-a,ci-b \
		--gitops-context ci-hub --dry-run --output-dir "${BATS_TEST_TMPDIR}/dres"
	[ -e "${BATS_TEST_TMPDIR}/dry-sent" ]
	[ "$status" -eq 143 ] || { echo "status ${status}: ${output}"; false; }
	refute_output --partial "Dry run complete"
	run ls -A "$t"
	assert_output ""
}
