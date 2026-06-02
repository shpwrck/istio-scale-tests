#!/usr/bin/env bash
# Pre-merge verification gate for tests/lib/ shared helpers.
# Runs syntax checks, static analysis, inline-definition audits, unit tests,
# and optionally dry-run sweeps.
#
# Usage: tests/lib/verify.sh [--skip-dry-run] [--skip-shellcheck]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKIP_DRY_RUN=0
SKIP_SHELLCHECK=0

for arg in "$@"; do
	case "$arg" in
	--skip-dry-run)    SKIP_DRY_RUN=1 ;;
	--skip-shellcheck) SKIP_SHELLCHECK=1 ;;
	-h|--help)
		echo "Usage: $(basename "$0") [--skip-dry-run] [--skip-shellcheck]"
		exit 0
		;;
	*) echo "error: unknown option: $arg" >&2; exit 1 ;;
	esac
done

pass=0
fail=0
step() { echo "--- [$1] $2"; }
ok()   { pass=$((pass + 1)); echo "    PASS"; }
err()  { fail=$((fail + 1)); echo "    FAIL: $1"; }

# 1. bash -n syntax check
step 1 "bash -n on all test scripts"
syntax_fail=0
for f in "$ROOT"/tests/*/*.sh "$ROOT"/tests/lib/*.sh; do
	if ! bash -n "$f" 2>/dev/null; then
		echo "    syntax error: $f"
		bash -n "$f" 2>&1 || true
		syntax_fail=1
	fi
done
if ((syntax_fail)); then err "syntax errors found"; else ok; fi

# 2. shellcheck
if ((SKIP_SHELLCHECK)); then
	step 2 "shellcheck (SKIPPED)"
else
	step 2 "shellcheck on lib/ and suite scripts"
	if command -v shellcheck >/dev/null 2>&1; then
		sc_fail=0
		for f in "$ROOT"/tests/lib/*.sh "$ROOT"/tests/*/*.sh; do
			if ! shellcheck "$f" 2>/dev/null; then
				sc_fail=1
			fi
		done
		if ((sc_fail)); then err "shellcheck violations found"; else ok; fi
	else
		echo "    WARNING: shellcheck not found, skipping"
		pass=$((pass + 1))
	fi
fi

# 3. grep audit — no inline definitions of extracted functions outside lib/
step 3 "grep audit for inline function definitions"
audit_fail=0
EXTRACTED_PATTERNS=(
	'die() {'
	'split_csv() {'
	'is_pos_int() {'
	'is_nonneg_int() {'
	'validate_scoping() {'
	'_detect_now_ns() {'
	'_detect_now_ms() {'
	'now_ns() {'
	'now_ms() {'
	'extract_counter_sum() {'
	'extract_counter_by_label() {'
	'extract_gauge() {'
	'delta_histogram_p99() {'
	'scrape_istiod_metrics() {'
	'harness_sha() {'
	'kube_versions() {'
	'probe_kube_versions() {'
	'istiod_restart_status() {'
	'istiod_start_time_seconds() {'
	'write_preamble() {'
	'fanout_ctx_port_base() {'
	'fanout_list_istiod_pods() {'
	'fanout_preflight_istiod() {'
	'fanout_open() {'
	'fanout_scrape_all() {'
	'fanout_record_podset() {'
	'fanout_counter_sum() {'
	'fanout_counter_by_label_sum() {'
	'fanout_gauge_sum() {'
	'fanout_gauge_invariant() {'
	'fanout_merge_histogram() {'
	'fanout_restart_status() {'
)
EXCEPTIONS="tests/lib/|tests/tuning/004-compare-profiles.sh|tests/controlplane/002-collect-resource-metrics.sh|tests/propagation/002-run-endpoint-probe.sh"
for pat in "${EXTRACTED_PATTERNS[@]}"; do
	matches=$(grep -rn "$pat" "$ROOT/tests/" --include='*.sh' | grep -vE "$EXCEPTIONS" || true)
	if [[ -n "$matches" ]]; then
		echo "    INLINE FOUND: $pat"
		echo "      ${matches//$'\n'/$'\n'      }"
		audit_fail=1
	fi
done
if ((audit_fail)); then err "inline definitions found outside tests/lib/"; else ok; fi

# 4. bats unit tests
step 4 "bats-core unit tests"
BATS="${ROOT}/tests/lib/test/bats-core/bin/bats"
if [[ -x "$BATS" ]]; then
	if "$BATS" "$ROOT"/tests/lib/test/*.bats; then
		ok
	else
		err "bats tests failed"
	fi
else
	echo "    WARNING: bats-core not found (run: git submodule update --init)"
	fail=$((fail + 1))
fi

# 5. dry-run sweeps
if ((SKIP_DRY_RUN)); then
	step 5 "dry-run sweeps (SKIPPED)"
else
	step 5 "dry-run sweep scripts"
	dry_fail=0
	SWEEPS=(
		"tests/churn/003-run-sweep.sh --dry-run --contexts ci-dummy"
		"tests/controlplane/003-run-sweep.sh --dry-run --contexts ci-dummy"
		"tests/dataplane/003-run-sweep.sh --dry-run --contexts ci-dummy"
		"tests/propagation/006-run-sweep.sh --dry-run --contexts ci-dummy"
		"tests/churn-dataplane/004-run-sweep.sh --dry-run --contexts ci-dummy"
		"tests/tuning/003-run-tuning-sweep.sh --dry-run --contexts ci-dummy"
	)
	for sweep in "${SWEEPS[@]}"; do
		script="${ROOT}/${sweep%% *}"
		args="${sweep#* }"
		if [[ -x "$script" ]]; then
			# shellcheck disable=SC2086
			if "$script" $args >/dev/null 2>&1; then
				echo "    ok: $sweep"
			else
				echo "    FAIL: $sweep"
				dry_fail=1
			fi
		else
			echo "    SKIP (not executable): $sweep"
		fi
	done
	if ((dry_fail)); then err "dry-run failures"; else ok; fi
fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="
((fail == 0))
