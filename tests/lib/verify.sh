#!/usr/bin/env bash
# Pre-merge verification gate for tests/lib/ shared helpers.
# Runs syntax checks, shellcheck, inline-definition audits, bats unit tests, the
# bare-scrape lint, and the CI dry-run smoke (every tests/ script annotated
# `# ci-dry-run:`). Needs no cluster: dry-runs use an empty kubeconfig.
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
	'now_ns() {'
	'now_ms() {'
	'extract_counter_sum() {'
	'extract_counter_by_label() {'
	'extract_gauge() {'
	'extract_gauge_sum() {'
	'delta_histogram_p99() {'
	'harness_sha() {'
	'kube_versions() {'
	'probe_kube_versions() {'
	'write_preamble() {'
	'infra_preamble_lines() {'
	'env_parse_istiod_resources() {'
	'env_parse_network() {'
	'env_pct_of_limit() {'
	'env_sla_verdict() {'
	'env_collect_infra() {'
	'env_istiod_resources() {'
	'env_network() {'
	'render_scale_envelope() {'
	'fanout_ctx_port_base() {'
	'fanout_list_istiod_pods() {'
	'fanout_preflight_istiod() {'
	'fanout_open() {'
	'fanout_scrape_all() {'
	'fanout_scrape_failed_count() {'
	'fanout_record_podset() {'
	'fanout_counter_sum() {'
	'fanout_counter_by_label_sum() {'
	'fanout_gauge_sum() {'
	'fanout_merge_histogram() {'
	'fanout_restart_status() {'
	# Task 2: per-cluster connected-proxy count + sanity check
	'fanout_gauge_sum_strict() {'
	'cap_proxy_check() {'
	# Task 6: VirtualService/DestinationRule load axis
	'validate_traffic_config() {'
	'vsdr_service_count() {'
	'config_dump_breakdown() {'
	'resume_preamble_scalar() {'
	# dataplane local baseline: fortio.sh + is_ratio
	'is_ratio() {'
	'fortio_percentile_ms() {'
	'fortio_max_ms() {'
	'fortio_actual_qps() {'
	'fortio_pct_200() {'
	'fortio_n_responses() {'
	'fortio_ret_codes() {'
	'fortio_row_status() {'
	# remote reachability: reach.sh + is_dns_label_for
	'is_dns_label_for() {'
	'reach_summarize() {'
	'reach_classify() {'
	'reach_sanitize() {'
	'reach_check_target() {'
	'reach_check_all() {'
	'reach_coverage_rows() {'
	'reach_coverage_render() {'
	# run config: config.sh (--config FILE)
	'config_suite_prefixes() {'
	'config_allowed_keys() {'
	'load_config() {'
	'config_preload() {'
	'config_preamble_lines() {'
	'config_repo_path() {'
	'config_snapshot() {'
	'config_report_value() {'
	'config_warn_multi_run() {'
)
EXCEPTIONS="tests/lib/"
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

# 5. bare by-design-non-zero scrape-call lint
# Catches the #31 incident class at review: a bare fanout_scrape_all / scrape_ctx /
# fanout_scrape_aggregate in statement position aborts the whole script under set -e
# before the next line can tag the row. Must be captured, || true'd, an if/while
# condition, or a function-tail return.
step 5 "bare by-design-non-zero scrape-call lint"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/lint-bare-scrape.sh"
if lint_out="$(lint_bare_scrape_paths "$ROOT/tests")"; then
	ok
else
	printf '    %s\n' "${lint_out//$'\n'/$'\n'    }"
	err "bare by-design-non-zero scrape call(s) found (capture, guard with || true, or use as if/while condition)"
fi

# 6. dry-run smoke — same discovery and args as CI (portability.yml).
if ((SKIP_DRY_RUN)); then
	step 6 "dry-run smoke (SKIPPED)"
else
	step 6 "dry-run smoke for scripts annotated '# ci-dry-run:'"
	dry_fail=0
	empty_kubeconfig="$(mktemp)"
	while IFS= read -r f; do
		args=$(grep -m1 '^# ci-dry-run:' "$f" | sed 's/^# ci-dry-run://')
		rel="${f#"$ROOT"/}"
		# shellcheck disable=SC2086
		if (cd "$ROOT" && KUBECONFIG="$empty_kubeconfig" bash "$rel" --dry-run $args) >/dev/null 2>&1; then
			echo "    ok: $rel --dry-run${args}"
		else
			echo "    FAIL: $rel --dry-run${args}"
			dry_fail=1
		fi
	done < <(grep -rl --exclude-dir='bats-*' '^# ci-dry-run:' "$ROOT/tests" --include='*.sh' | sort)
	rm -f "$empty_kubeconfig"
	if ((dry_fail)); then err "dry-run failures"; else ok; fi
fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="
((fail == 0))
