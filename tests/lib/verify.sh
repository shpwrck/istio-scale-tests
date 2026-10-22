#!/usr/bin/env bash
# Pre-merge verification gate for tests/lib/ shared helpers.
# Runs syntax checks, shellcheck, inline-definition audits, bats unit tests, the
# bare-scrape and keyed-array lints, and the CI dry-run smoke (every tests/ script
# annotated `# ci-dry-run:`). Needs no cluster: dry-runs use an empty kubeconfig.
#
# Usage: tests/lib/verify.sh [--skip-dry-run] [--skip-shellcheck] [--jobs N]
# A missing shellcheck or bats-core fails the run; --skip-shellcheck skips that step on purpose.
# --jobs N runs N bats files at once (each file's tests in order); it needs GNU parallel, and
# without it the files run one after another, with a warning.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKIP_DRY_RUN=0
SKIP_SHELLCHECK=0
JOBS=1

usage() {
	echo "Usage: $(basename "$0") [--skip-dry-run] [--skip-shellcheck] [--jobs N]"
	echo "  --skip-dry-run     skip the dry-run smoke of the '# ci-dry-run:' scripts"
	echo "  --skip-shellcheck  skip shellcheck"
	echo "  --jobs N           run N bats files at once (default 1; needs GNU parallel)"
}

while (($#)); do
	case "$1" in
	--skip-dry-run)    SKIP_DRY_RUN=1 ;;
	--skip-shellcheck) SKIP_SHELLCHECK=1 ;;
	--jobs)
		[[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "error: --jobs needs a whole number of jobs, 1 or more" >&2; exit 1; }
		JOBS="$2"
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	*) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
	esac
	shift
done

# Every step runs awk. Sourcing common.sh checks it (awk_untyped_ok): with gawk 5.2 or 5.3 it runs
# awk as mawk, or stops here once with the install hint instead of failing every bats file and
# dry-run with it.
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"

pass=0
fail=0
step() { echo "--- [$1] $2"; }
ok()   { pass=$((pass + 1)); echo "    PASS"; }
err()  { fail=$((fail + 1)); echo "    FAIL: $1"; }

# 1. bash -n syntax check
step 1 "bash -n on all test scripts"
syntax_fail=0
for f in "$ROOT"/tests/*/*.sh "$ROOT"/tests/lib/*.sh "$ROOT"/tests/lib/test/fixtures/*.sh "$ROOT"/tests/tuning/lib/*.sh; do
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
		# One call over every file, as CI runs it: shellcheck then follows a `source` of a file
		# on the same command line, so a name used as an array in a lib and as a scalar in a
		# suite is caught here too, not only in CI (whose find takes these files too, the bats
		# fixtures and tests/tuning/lib included).
		if shellcheck --shell=bash "$ROOT"/tests/lib/*.sh "$ROOT"/tests/*/*.sh "$ROOT"/tests/lib/test/fixtures/*.sh \
			"$ROOT"/tests/tuning/lib/*.sh; then
			ok
		else
			err "shellcheck violations found"
		fi
	else
		err "shellcheck not found on PATH (install it, or pass --skip-shellcheck to skip this step)"
	fi
fi

# 3. grep audit — no inline definitions of extracted functions outside lib/
step 3 "grep audit for inline function definitions"
audit_fail=0
EXTRACTED_PATTERNS=(
	'die() {'
	'awk_untyped_ok() {'
	'split_csv() {'
	'split_contexts() {'
	'ctx_file_safe() {'
	'is_pos_int() {'
	'is_nonneg_int() {'
	'file_sha256() {'
	'kv_value() {'
	'each_bounded() {'
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
	'env_limit_drift_warning() {'
	'env_pct_cell() {'
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
	# istiod restart diagnostics: istiod-diag.sh
	'istiod_diag_dir() {'
	'istiod_diag_capture() {'
	'istiod_diag_after_window() {'
	'istiod_diag_report() {'
	# per-cluster connected-proxy count + sanity check
	'fanout_gauge_sum_strict() {'
	'cap_proxy_check() {'
	# VirtualService/DestinationRule load axis
	'validate_traffic_config() {'
	'vsdr_service_count() {'
	'config_dump_breakdown() {'
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
	# one run per report, merged preambles (config.sh)
	'config_input_value() {'
	'config_merged_preamble() {'
	'config_check_multi_run() {'
	'config_multi_run_note() {'
	'config_multi_run_csv() {'
	'config_multi_run_json() {'
	# validation fixes: istiod replicas over every context, reach-check cost bound
	'env_replicas_summary() {'
	'env_replicas_label() {'
	'env_istiod_scan() {'
	'reach_worst_case_sec() {'
	# namespace scaling: fit.sh, growth.sh, the growth validators and preamble emitters
	'fit_linear() {'
	'fit_loglog() {'
	'mem_guard_project() {'
	'mem_guard_verdict() {'
	'validate_workload_mode() {'
	'validate_outside_mode() {'
	'growth_preamble_lines() {'
	'ns_lifecycle_init() {'
	'ns_lifecycle_row() {'
	'ns_lifecycle_api_counts() {'
	'growth_parse_envoy_stats() {'
	'growth_envoy_stats() {'
	'growth_parse_gateway_pods() {'
	'growth_gateway_pods() {'
	'growth_gateway_summary() {'
	'growth_root_cert_count() {'
	'growth_istiod_heap_mi() {'
	# ROSA window fixes (BACKLOG 9.3-9.7, 9.10)
	'growth_discovered_ns() {'
	'growth_retire_verified() {'
	'growth_parse_top_containers() {'
	'growth_gateway_ws() {'
	'growth_parse_remote_secrets() {'
	'growth_mesh_members() {'
	'growth_test_ns_counts() {'
	'mem_guard_project_abs() {'
	'cap_parse_proxy_requests() {'
	'cap_proxy_requests() {'
	'cap_per_pod_requests() {'
	'cap_parse_requested() {'
	'cap_requested() {'
	# bounded exec calls (common.sh)
	'timeout_cmd() {'
	'require_timeout() {'
	'run_timeout() {'
	# counter window deltas (metrics.sh)
	'counter_delta() {'
	# a sweep's start, steps, stop and outcome (common.sh)
	'sweep_start() {'
	'_sweep_record() {'
	'_sweep_mask() {'
	'_sweep_unlock() {'
	'sweep_step() {'
	'_sweep_step_stop() {'
	'_sweep_step_kill() {'
	'_sweep_on_signal() {'
	'_sweep_on_exit() {'
	'sweep_err_trap() {'
	'sweep_problem() {'
	# anchored: controlplane 004's msweep_note is another function
	'^[[:space:]]*sweep_note() {'
	'_sweep_outcome_by() {'
	'sweep_finish() {'
	'sweep_outcome_lines() {'
	# which propagation rows count (propagation.sh, awk)
	'function prop_drop_reason('
	'function prop_p1_drop_reason('
	'function prop_p1_first('
	'function prop_p1_sample('
	'function prop_p2_sample('
	'function prop_p3_sample('
	# the Istio version the mesh runs, read at the start and the end (preamble.sh)
	'istio_live_version() {'
	'_istio_read() {'
	'_istio_read_all() {'
	'_istio_read_one() {'
	'_istio_wait_one() {'
	'istio_version_resolve() {'
	'istio_version_recheck() {'
	'istio_generations_read() {'
	'istio_generations_diff() {'
	'istio_version_kv() {'
	'istio_version_label() {'
	# multi-run refusal (config.sh)
	'_config_run_key() {'
	'_config_run_ids() {'
	'_config_sq() {'
	'_config_canon_dir() {'
	'_config_distinct() {'
	'_config_join_mixed() {'
	# scrape completeness and per-replica counters (fanout.sh)
	'fanout_body_complete() {'
	'fanout_counter_in_batch() {'
	'fanout_replica_counter() {'
	# the keyed-array arithmetic lint (lint-keyed-arith.sh)
	'lint_keyed_arith_file() {'
	'lint_keyed_arith_paths() {'
	# placeholder rows and the legacy schema (propagation.sh); a TSV's end line,
	# escaped markdown cells, a fork-free size check (common.sh)
	'prop_placeholder_row() {'
	'function prop_legacy_reason_('
	'tsv_end_line() {'
	'md_cell() {'
	'function md_cell('
	'yaml_str() {'
	'file_min_bytes() {'
	# a controlplane cell's states (common.sh CP_CELL_AWK)
	'function cp_header('
	'function cp_isrow('
	'function cp_key('
	'function cp_cell_row('
	'function cp_cell_state('
	'function cp_wl_parse('
	'function cp_nr_parse('
	'function cp_comment('
	'function cp_end('
	'function cp_mxo('
	# the one JSON string escaper (common.sh)
	'JSON_STR_AWK='
	'function js('
	# an in-pod load stopped with its probe, or waited out after its exec failed (fortio.sh)
	'fortio_client_stop() {'
	'fortio_load_wait_out() {'
	# the client pod a probe execs its loads in: Ready, not being deleted (fortio.sh)
	'fortio_client_pod() {'
	# member platform: platform.sh (the suite charts' OpenShift overlay, the platform record)
	'platform_of() {'
	'platform_chart_args() {'
	'platform_validate() {'
	'platform_gitops_namespace() {'
	'platform_pod_filter() {'
	'platform_members_check() {'
	'platform_probe() {'
	'platform_member_value() {'
	'platform_probe_share() {'
	'platform_recorded_contexts() {'
	'platform_preamble_lines() {'
	'platform_md_row() {'
	'platform_collapse() {'
	'platform_drift_check() {'
	'platform_merge_by_context() {'
	'platform_report_values() {'
	'platform_report_warnings() {'
	'platform_report_lines() {'
	'platform_warning_lines() {'
	'platform_report_is_key() {'
	'platform_value_has() {'
	'platform_unread_members() {'
	'platform_kind_path_warning() {'
	'platform_summary() {'
	'platform_short_digests() {'
	'platform_tuning_objects() {'
	'platform_tuning_objects_refuse() {'
	'platform_start_warnings() {'
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
	bats_jobs=()
	if ((JOBS > 1)); then
		if command -v parallel >/dev/null 2>&1; then
			bats_jobs=(--jobs "$JOBS" --no-parallelize-within-files)
		else
			echo "    WARNING: --jobs ${JOBS} needs GNU parallel on PATH; running the bats files one after another"
		fi
	fi
	if "$BATS" ${bats_jobs[@]+"${bats_jobs[@]}"} "$ROOT"/tests/lib/test/*.bats; then
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

# 6. keyed-array arithmetic lint: bash 4.3-5.1 expand an array key twice in (( )), let,
# [[ -gt ]] and -v, so a key with a quote stops the script or reads false.
step 6 "keyed-array arithmetic lint"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/lint-keyed-arith.sh"
if lint_out="$(lint_keyed_arith_paths "$ROOT/tests" "$ROOT/terraform")"; then
	ok
else
	printf '    %s\n' "${lint_out//$'\n'/$'\n'    }"
	err "array element read by a variable key in shell arithmetic (read it into a scalar first)"
fi

# 7. dry-run smoke — same discovery and args as CI (portability.yml).
if ((SKIP_DRY_RUN)); then
	step 7 "dry-run smoke (SKIPPED)"
else
	step 7 "dry-run smoke for scripts annotated '# ci-dry-run:'"
	dry_fail=0
	empty_kubeconfig="$(mktemp)"
	dry_out="$(mktemp)"
	while IFS= read -r f; do
		dry_args=$(grep -m1 '^# ci-dry-run:' "$f" | sed 's/^# ci-dry-run://')
		rel="${f#"$ROOT"/}"
		# shellcheck disable=SC2086
		if (cd "$ROOT" && KUBECONFIG="$empty_kubeconfig" bash "$rel" --dry-run $dry_args) >"$dry_out" 2>&1; then
			echo "    ok: $rel --dry-run${dry_args}"
		else
			echo "    FAIL: $rel --dry-run${dry_args} (last 20 lines of its output):"
			tail -n 20 "$dry_out" | sed 's/^/      | /'
			dry_fail=1
		fi
	done < <(grep -rl --exclude-dir='bats-*' '^# ci-dry-run:' "$ROOT/tests" --include='*.sh' | sort)
	rm -f "$empty_kubeconfig" "$dry_out"
	if ((dry_fail)); then err "dry-run failures"; else ok; fi
fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="
((fail == 0))
