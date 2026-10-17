#!/usr/bin/env bash
# Post-process propagation test TSV files into summary statistics.
# Groups results by mesh_size to compare propagation latency across cluster counts.
#
# Filtering policy (one definition, prop_drop_reason in tests/lib/propagation.sh). P2 and
# P3 are measured on a remote, so a row's P2/P3 are excluded only for that remote's side:
#   - remote_status != OK       (field 22: its istiod RESTART or RESTART_UNKNOWN, a P2/P3
#                                timeout, its sidecar's DRAIN_TIMEOUT, SCRAPE_INCOMPLETE)
#   - remote_scrape_skew_ms > FANOUT_MAX_SKEW_MS (field 23; default 1000)
# never for the source's restart, P1 timeout or p1_overflow (I6). A TSV from before fields
# 22-23 cannot split the row by side: status != OK, restarted == 1|unknown, or
# scrape_skew_ms (field 19) over the ceiling drop it, p1_overflow does not.
# p2_ms values are also excluded when p2_dirty == 1 (EDS pushed but the canary
# never went healthy on that remote's watcher; could be unrelated churn).
# Reports both n_total (rows considered) and n_valid (rows used). The P1 phases
# (P1_local_wall, P1_conv_*) take one sample per iteration: P1 is measured on the source
# once per iteration and repeated on every remote's row (prop_p1_first in
# tests/lib/propagation.sh), so their n_total and n_valid both count iterations (distinct
# run_id, iteration), as 002's summary does (M1). An iteration's P1 is left out only for a
# source-side reason (fields 20 p1_status and 21 p1_scrape_skew_ms, and p1_overflow), never
# because its remote rows failed (B2); a TSV from before field 20 takes it from the first row
# with status OK, restarted=0, no p1_overflow and skew within the ceiling.
#
# Carries forward TSV preamble metadata (RUN_ID, HARNESS_SHA, ISTIO_VERSION and its
# ISTIO_VERSION_PIN / ISTIO_VERSION_SOURCE / ISTIO_VERSION_BY_CONTEXT, the start-of-run
# readiness ISTIO_NOTREADY_AT_START / ISTIO_READY_WAITED_SEC, each member's active
# revision ISTIO_ACTIVE_REVISIONS, its Istio CR / IstioRevision generations
# ISTIO_GENERATIONS and connected proxy versions ISTIO_PROXY_VERSIONS (unknown for a TSV
# written before them; mixed when pooled inputs differ), KUBE_VERSIONS, SETTLE_SEC,
# POLL_INTERVAL_S, TIMEOUT_SEC, ITERATIONS) into all report formats, plus RUN_CONFIG /
# RUN_CONFIG_SHA256 (the --config behind the inputs) over all input TSVs.
#
# Every endpoint-*.tsv under the results dir is read. More than one run there (several
# sweep-* dirs, or standalone probes with different run ids) stops the report unless
# --allow-multi-run, and then every format says it pools N runs (R3).
#
# Usage:
#   ./tests/propagation/005-report-results.sh [--results-dir DIR] [--allow-multi-run]
#     [--format text|csv|json|markdown|charts]
#
# Examples:
#   # Text report of one sweep:
#   ./tests/propagation/005-report-results.sh --results-dir tests/propagation/results/sweep-<RUN_ID>
#
#   # CSV output of the default results dir (one run in it):
#   ./tests/propagation/005-report-results.sh --format csv
#
#   # Every run under the default results dir, pooled on purpose:
#   ./tests/propagation/005-report-results.sh --allow-multi-run
#
#   # One sweep of a run config:
#   ./tests/propagation/005-report-results.sh --config tests/propagation/configs/smoke.env \
#     --results-dir tests/propagation/results/smoke/sweep-<RUN_ID> --format markdown
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_report_value
# --config FILE: export the file's keys before options.env fills in defaults.
config_preload propagation "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/options.env"  # PROPAGATION_RESULTS_DIR
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/istiod-diag.sh"  # istiod_diag_report
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/propagation.sh"  # PROP_ROW_AWK: which rows count (shared with 002)

RESULTS_DIR="$(config_repo_path "${PROPAGATION_RESULTS_DIR}")"
FORMAT="text"
# --allow-multi-run: pool more than one run (else the report refuses, R3). Per invocation
# like --force-large-matrix, so no options.env key.
ALLOW_MULTI_RUN=0


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE      Run config of KEY=value lines (config/options.env keys; see
                     tests/propagation/README.md, "Run config"). Precedence: flag >
                     --config > environment > default.
  --results-dir DIR  Results directory (default: ${PROPAGATION_RESULTS_DIR}). Every
                     endpoint-*.tsv under it is read; a sweep-*/ dir from 006 is one run.
  --allow-multi-run  Pool more than one run (several sweep-* dirs, or standalone probes
                     with different run ids). Without it the report stops, lists the
                     runs and how to report each alone; with it every format says it
                     pools N runs and lists their HARNESS_SHA and ISTIO_VERSION values.
  --format FMT       Output format: text, csv, json, markdown, charts (default: text).
  -h, --help         Show this help.

Example (one sweep, as 006 runs it; from the repo root):
  tests/propagation/$(basename "$0") --results-dir ${PROPAGATION_RESULTS_DIR}/sweep-<RUN_ID> --format markdown

TSV columns consumed (positions are stable; new columns appended):
  1  run_id            2  mesh_size       3  iteration       4  source_ctx
  5  remote_ctx        6  t0_epoch_ns     7  p1_ms           8  p2_ms
  9  p3_ms            10  status         11  p1_conv_p50_ms 12  p1_conv_p99_ms
 13  p1_sample_count  14  p1_proxy_count 15  p1_overflow    16  restarted
 17  p2_dirty         18  window_ms      19  scrape_skew_ms 20  p1_status
 21  p1_scrape_skew_ms                  22  remote_status  23  remote_scrape_skew_ms
(older TSVs: 18, 19 or 21 columns; 006's SETUP_FAILED/PROBE_FAILED rows use all 23)

Phases emitted in the report:
  P1_local_wall  wall-clock ms (p1_ms) from the t0 active-label flip until the
                 histogram delta _count reached proxy_count.
  P1_conv_p50    p50 of delta-window pilot_proxy_convergence_time (ms).
  P1_conv_p99    p99 of delta-window pilot_proxy_convergence_time (ms).
                 Both are histogram bucket bounds: text and markdown show bucket
                 ranges with no average (max is the worst bucket); csv and json
                 keep the numbers and add worst_bucket.
  P2_discovery   pilot_xds_pushes{type="eds"} counter-delta detection (ms).
  P3_dataplane   watcher Envoy /clusters detection (ms).

Filtering policy (rows excluded from numeric aggregation): P2 and P3 are measured
on a remote, so a row's P2/P3 are left out only for that remote's side:
  remote_status (field 22) != OK   (its istiod RESTART or RESTART_UNKNOWN, a P2 or
                                    P3 timeout, its sidecar's DRAIN_TIMEOUT,
                                    SCRAPE_INCOMPLETE of its scrape)
  remote_scrape_skew_ms (field 23) > FANOUT_MAX_SKEW_MS
never for the source's restart, P1 timeout or p1_overflow. A row with no remote
(remote_status N/A) measures P1 only. A TSV without field 22 (21 or fewer
columns) cannot split a row by side: status != OK, restarted == 1 or unknown,
or scrape_skew_ms (field 19) > FANOUT_MAX_SKEW_MS drops it; p1_overflow does not.
P2 values are additionally suppressed when p2_dirty == 1.
P1 phases (one sample per iteration, measured on the source) use the source side
only: an iteration's P1 is left out when p1_status (field 20) is not OK
(TIMEOUT_P1, RESTART, RESTART_UNKNOWN, DRAIN_TIMEOUT of the source sidecar,
SCRAPE_INCOMPLETE of a source scrape), p1_overflow == 1, or p1_scrape_skew_ms
(field 21) > FANOUT_MAX_SKEW_MS; a remote that timed out or restarted keeps it. A
TSV without field 20 (written before it) takes P1 from the iteration's first row
with status OK, restarted 0, p1_overflow 0 and scrape_skew_ms within the ceiling.

n_total / n_valid: rows considered vs rows used after the above filtering; for
the P1 phases, iterations (P1 is one sample per iteration, as 002's summary counts it).
Averages are rounded to the nearest ms; json mesh_size is a number.

text, markdown and json also carry an "istiod restart diagnostics" section: every
istiod-diag-*/index.tsv under the results dir, one line per restart (run_id, what
changed, the cause, the evidence folder relative to the results dir) and a tally by
cause; restarted_untimed rows (may predate the window) are counted apart (json key
istiod_diag).

When the results dir holds sweep-outcome.txt (006 writes it),
every format repeats it, with the run that recorded it: the failed cells by reason, its
problems (the Istio version or active revision changed under the sweep) and notes
(members not ready at its start or end). The sweep writes it at its start as "not
finished" (EXIT=unfinished) and replaces it at its end: a record still not finished is
a sweep that died or still runs, or (I5) one interrupted, with when and by which signal;
one that stopped on an error after its start shows the stop and its reason. A sweep dir
without the file is from a sweep that stopped before its start (nothing ran), or from
an older harness.

Environment:
  FANOUT_MAX_SKEW_MS  Scrape-skew ceiling (ms) for the skew filters above: fields 21 and
                      23, or 19 in an older TSV (default 1000).
  PROPAGATION_PERCENTILE_MIN_N  Minimum sample count before p95/p99 are reported
                      (default 20; 0 disables). Below it p95/p99 are N/A
                      (null in JSON). p50 is always reported.
  PROPAGATION_RESULTS_DIR  --results-dir default (relative to the repo root).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2
		;;
	--results-dir)
		[[ -n "${2:-}" ]] || die "--results-dir requires a value"
		RESULTS_DIR="$2"
		shift 2
		;;
	--allow-multi-run)
		ALLOW_MULTI_RUN=1
		shift
		;;
	--format)
		[[ -n "${2:-}" ]] || die "--format requires a value"
		FORMAT="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1 (try --help)"
		;;
	esac
done

[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"

ENDPOINT_FILES=()
while IFS= read -r f; do
	ENDPOINT_FILES+=("$f")
done < <(find -H "$RESULTS_DIR" -name 'endpoint-*.tsv' -type f 2>/dev/null | sort)

if [[ ${#ENDPOINT_FILES[@]} -eq 0 ]]; then
	die "no TSV result files found in $RESULTS_DIR"
fi

# ---- preamble metadata: collect across all files ----------------------------
# Two partitions (PL19 — preamble propagation must survive into all 4 formats):
#
# SWEEP_LEVEL_KEYS — scalar, identical across all input TSVs in a sweep. Emitted
#   once at the top of the metadata block.
#     SWEEP_RUN_ID is first so the outer→inner ordering reads correctly when
#     a sweep ran. For standalone probe TSVs SWEEP_RUN_ID is absent (002 omits
#     the line when --sweep-run-id is empty), and the report just drops it.
#
# PER_ITER_KEYS — vary per iteration; emitted as a sequence (one entry per input
#   TSV). A single-input run (or a sweep with one mesh size and one probe) is
#   still rendered as a one-element sequence so the schema is uniform.
#
# Implementation: for each input file we collect a row of key=value pairs into
# PER_FILE_VALS[KEY|i]; sequences iterate the rows in input order. Scalars are merged
# over every input (config_merged_preamble): one value, or mixed:a,b with a warning.
SWEEP_LEVEL_KEYS=(SWEEP_RUN_ID HARNESS_SHA ISTIO_VERSION ISTIO_VERSION_PIN ISTIO_VERSION_SOURCE ISTIO_VERSION_BY_CONTEXT ISTIO_NOTREADY_AT_START ISTIO_READY_WAITED_SEC ISTIO_ACTIVE_REVISIONS ISTIO_GENERATIONS ISTIO_PROXY_VERSIONS SOURCE_CTX ITERATIONS POLL_INTERVAL_S TIMEOUT_SEC SETTLE_SEC FANOUT_MAX_SKEW_MS FANOUT_METRICS_TIMEOUT BACKER_IMAGE TUNING_BASELINE SIDECAR_EGRESS_HOSTS RUN_CONFIG RUN_CONFIG_SHA256)
PER_ITER_KEYS=(RUN_ID DATE MESH_SIZE REMOTES KUBE_VERSIONS)
# Legacy combined order used by report_endpoint_*'s "first valid value" lookup
# (preserved so any scalar key, even one we have not classified, still appears).
# shellcheck disable=SC2034
PREAMBLE_KEYS=("${SWEEP_LEVEL_KEYS[@]}" "${PER_ITER_KEYS[@]}")

declare -A PREAMBLE=()         # every key merged over all inputs (config_merged_preamble)
declare -A PER_FILE_VALS=()    # KEY|idx -> value (per-iteration values)
declare -a PER_FILE_INDICES=() # 0..N-1 indices for input files, in collection order
N_FILES=0
for f in "${ENDPOINT_FILES[@]}"; do
	idx="$N_FILES"
	PER_FILE_INDICES+=("$idx")
	while IFS= read -r line; do
		case "$line" in
			'# '*)
				kv="${line#\# }"
				key="${kv%%=*}"
				val="${kv#*=}"
				[[ "$key" == "$kv" ]] && continue
				PER_FILE_VALS["${key}|${idx}"]="$val"
				;;
			*) ;;
		esac
	done < <(grep -E '^# [A-Z_]+=' "$f" || true)
	N_FILES=$((N_FILES + 1))
done
# Sweep-level values over every input, never the first or the last file's (PL26): a key
# that varies reads mixed:a,b, and a sweep-level one warns (it should not vary in a run).
while IFS= read -r kv; do
	PREAMBLE["${kv%%=*}"]="${kv#*=}"
done < <(config_merged_preamble "${ENDPOINT_FILES[@]}")
# J13: a key every input predates (the Istio version keys, the R2 readiness keys) reads
# unknown, as in the other reports: not recorded, rather than absent.
for k in $CONFIG_MERGED_UNKNOWN_IF_MISSING; do
	[[ -n "${PREAMBLE[$k]:-}" ]] || PREAMBLE[$k]=unknown
done
for k in "${SWEEP_LEVEL_KEYS[@]}"; do
	case "$k" in RUN_CONFIG | RUN_CONFIG_SHA256) continue ;; esac
	if [[ "${PREAMBLE[$k]:-}" == mixed:* ]]; then
		echo "warning: input TSVs disagree on sweep-level ${k} (${PREAMBLE[$k]#mixed:}); the report shows it as mixed" >&2
	fi
done
# Which --config produced the inputs (PL2/PL19), over every input rather than the last
# file: `none` without one, `unknown` for files written before the key existed,
# mixed:a,b with a warning when they differ (PL26).
PREAMBLE[RUN_CONFIG]="$(config_report_value RUN_CONFIG "${ENDPOINT_FILES[@]}")"
PREAMBLE[RUN_CONFIG_SHA256]="$(config_report_value RUN_CONFIG_SHA256 "${ENDPOINT_FILES[@]}")"
# R3/PL6: the report pools every TSV under the results dir; more than one run stops it
# unless --allow-multi-run, and then every format says so (config_multi_run_note).
config_check_multi_run "$RESULTS_DIR" "$ALLOW_MULTI_RUN" "${ENDPOINT_FILES[@]}"
POOLED_NOTE="$(config_multi_run_note)"

# Helper: does any per-file row carry this key?
preamble_has() {
	local k="$1" i
	for i in "${PER_FILE_INDICES[@]}"; do
		[[ -n "${PER_FILE_VALS[${k}|${i}]:-}" ]] && return 0
	done
	[[ -n "${PREAMBLE[$k]:-}" ]] && return 0
	return 1
}

# JSON-escape a single value (backslash + quote only; values are ASCII run metadata).
json_escape() {
	local v="$1"
	v="${v//\\/\\\\}"
	v="${v//\"/\\\"}"
	printf '%s' "$v"
}

# CSV-escape (RFC4180 — quote if comma/quote/newline; double internal quotes).
csv_escape() {
	local v="$1"
	if [[ "$v" == *","* || "$v" == *'"'* || "$v" == *$'\n'* ]]; then
		printf '"%s"' "${v//\"/\"\"}"
	else
		printf '%s' "$v"
	fi
}

format_preamble_text() {
	local k i v
	for k in "${SWEEP_LEVEL_KEYS[@]}"; do
		preamble_has "$k" || continue
		printf "  %s: %s\n" "$k" "${PREAMBLE[$k]:-}"
	done
	# Per-iteration block: one section per input file, indented under "iterations:".
	local any_iter=0
	for k in "${PER_ITER_KEYS[@]}"; do
		preamble_has "$k" && { any_iter=1; break; }
	done
	((any_iter)) || return 0
	printf "  iterations:\n"
	for i in "${PER_FILE_INDICES[@]}"; do
		printf "    -\n"
		for k in "${PER_ITER_KEYS[@]}"; do
			v="${PER_FILE_VALS[${k}|${i}]:-}"
			[[ -n "$v" ]] && printf "      %s: %s\n" "$k" "$v"
		done
	done
	return 0
}

format_preamble_md() {
	# YAML frontmatter: scalars first, then iterations as a YAML sequence so
	# downstream tools (and human readers) can recover per-iteration provenance.
	local k i v
	for k in "${SWEEP_LEVEL_KEYS[@]}"; do
		preamble_has "$k" || continue
		printf "%s: \"%s\"\n" "$k" "${PREAMBLE[$k]:-}"
	done
	local any_iter=0
	for k in "${PER_ITER_KEYS[@]}"; do
		preamble_has "$k" && { any_iter=1; break; }
	done
	((any_iter)) || return 0
	printf "iterations:\n"
	for i in "${PER_FILE_INDICES[@]}"; do
		# Sequence marker on its own line so each per-iteration mapping is a
		# proper YAML block — easier to read than inline flow form for sweeps
		# with many iterations.
		printf "  -\n"
		for k in "${PER_ITER_KEYS[@]}"; do
			v="${PER_FILE_VALS[${k}|${i}]:-}"
			[[ -n "$v" ]] && printf "    %s: \"%s\"\n" "$k" "$v"
		done
	done
	return 0
}

format_preamble_csv_header() {
	# Sweep-level scalars rendered as "# KEY=VALUE" comment lines above the
	# data table (uniform with text format) so the CSV remains a single tabular
	# stream readable by spreadsheet tools that skip leading comments.
	# Per-iteration block is a small CSV blob after the scalars.
	local k i v
	for k in "${SWEEP_LEVEL_KEYS[@]}"; do
		preamble_has "$k" || continue
		printf "# %s=%s\n" "$k" "${PREAMBLE[$k]:-}"
	done
	local any_iter=0
	for k in "${PER_ITER_KEYS[@]}"; do
		preamble_has "$k" && { any_iter=1; break; }
	done
	if ((any_iter)); then
		printf "# iterations:\n"
		# Header row for the per-iteration block.
		local first=1
		printf "# "
		for k in "${PER_ITER_KEYS[@]}"; do
			preamble_has "$k" || continue
			((first)) || printf ","
			printf "%s" "$k"
			first=0
		done
		printf "\n"
		for i in "${PER_FILE_INDICES[@]}"; do
			first=1
			printf "# "
			for k in "${PER_ITER_KEYS[@]}"; do
				preamble_has "$k" || continue
				((first)) || printf ","
				v="${PER_FILE_VALS[${k}|${i}]:-}"
				csv_escape "$v"
				first=0
			done
			printf "\n"
		done
	fi
}

format_preamble_json() {
	# Sweep-level scalars become top-level metadata fields; per-iteration values
	# go into an "iterations" array of objects so downstream JSON consumers can
	# recover every iteration's RUN_ID/DATE/MESH_SIZE without re-reading TSVs.
	local k i v first=1
	printf '{'
	for k in "${SWEEP_LEVEL_KEYS[@]}"; do
		preamble_has "$k" || continue
		((first)) || printf ","
		printf '"%s":"%s"' "$k" "$(json_escape "${PREAMBLE[$k]:-}")"
		first=0
	done
	local any_iter=0
	for k in "${PER_ITER_KEYS[@]}"; do
		preamble_has "$k" && { any_iter=1; break; }
	done
	if ((any_iter)); then
		((first)) || printf ","
		printf '"iterations":['
		local row_first=1 kv_first
		for i in "${PER_FILE_INDICES[@]}"; do
			((row_first)) || printf ","
			printf '{'
			kv_first=1
			for k in "${PER_ITER_KEYS[@]}"; do
				v="${PER_FILE_VALS[${k}|${i}]:-}"
				[[ -z "$v" ]] && continue
				((kv_first)) || printf ","
				printf '"%s":"%s"' "$k" "$(json_escape "$v")"
				kv_first=0
			done
			printf '}'
			row_first=0
		done
		printf ']'
	fi
	printf '}'
}

# Schema reminder: tab columns are
#   1 run_id  2 mesh_size  3 iter  4 src  5 remote
#   6 t0      7 p1_ms      8 p2_ms 9 p3_ms 10 status
#  11 p1_conv_p50_ms  12 p1_conv_p99_ms  13 p1_sample_count
#  14 p1_proxy_count  15 p1_overflow     16 restarted
#  17 p2_dirty (new)  18 window_ms       19 scrape_skew_ms
#  20 p1_status       21 p1_scrape_skew_ms (B2: the source-side P1 verdict)
#  22 remote_status   23 remote_scrape_skew_ms (I6: the remote-side P2/P3 verdict)
#
# Pre-branch TSVs have NF=18 (no p2_dirty column); the missing column is
# default-filled to "0" (clean), which keeps legacy reports identical.

# Shared awk aggregation block. Uses SUBSEP-keyed single-dim arrays so it works
# in mawk (no gawk multi-dim required). The $-style dollars are awk fields, not bash.
# shellcheck disable=SC2016
AWK_AGG="${PROP_ROW_AWK}"'
BEGIN { FS = "\t"; SUBSEP = "\034"; if (MAXSKEW == "") MAXSKEW = 1000 }
/^#/ { next }
/^run_id/ { next }
NF < 10 { next }
{
	ms = $2
	cp50 = ($11 == "") ? "N/A" : $11
	cp99 = ($12 == "") ? "N/A" : $12

	n_total[ms]++
	seen[ms] = 1
	# P1 is one sample per iteration (D1), so its n_total counts iterations too (M1):
	# distinct (run_id, iteration) per mesh size, kept or dropped, as the 002 summary does.
	if (!((ms, $1, $3) in p1_iter_seen)) { p1_iter_seen[ms, $1, $3] = 1; p1_total[ms]++ }

	# P1 phases, before the row filter: one sample per iteration (prop_p1_first), not one
	# per remote row (D1), left out only for a source-side reason (B2).
	if (prop_p1_sample(MAXSKEW)) {
		p1_n[ms]++; p1_vals[ms, p1_n[ms]] = $7 + 0
	}
	if (prop_p1_first(MAXSKEW) && cp50 ~ /^[0-9]+$/) {
		cp50_n[ms]++; cp50_vals[ms, cp50_n[ms]] = cp50 + 0
	}
	if (prop_p1_first(MAXSKEW) && cp99 ~ /^[0-9]+$/) {
		cp99_n[ms]++; cp99_vals[ms, cp99_n[ms]] = cp99 + 0
	}

	# Which rows count for P2/P3: prop_drop_reason (tests/lib/propagation.sh), the
	# definition 002 summarizes its own rows with (R6). It reads the remote side only
	# (remote_status, remote_scrape_skew_ms; I6); a TSV from before them: any non-OK
	# status, restarted=1|unknown, and (R2 reproducibility fallback) a pre-gate row written
	# OK whose recorded scrape_skew_ms exceeds the current FANOUT_MAX_SKEW_MS.
	if (prop_drop_reason(MAXSKEW) != "") next

	n_valid[ms]++

	# prop_p2_sample skips a dirty p2 (EDS bumped but P3 did not succeed).
	if (prop_p2_sample()) {
		p2_n[ms]++; p2_vals[ms, p2_n[ms]] = $8 + 0
	}
	if (prop_p3_sample()) {
		p3_n[ms]++; p3_vals[ms, p3_n[ms]] = $9 + 0
	}
}
# phase_total: the n_total of a phase row: iterations for the P1 phases, rows otherwise.
function phase_total(phase, ms) { return (phase ~ /^P1/) ? p1_total[ms] + 0 : n_total[ms] + 0 }
function load(into, src, ms, n,    i) {
	for (i = 1; i <= n; i++) into[i] = src[ms, i]
}
function sort_arr(arr, n,    i, j, tmp) {
	for (i = 2; i <= n; i++) {
		tmp = arr[i]
		j = i - 1
		while (j >= 1 && arr[j] > tmp) { arr[j+1] = arr[j]; j-- }
		arr[j+1] = tmp
	}
}
function percentile(arr, n, pct,    idx, rank, min_n) {
	if (n == 0) return "N/A"
	# P1-7: min-n gate for TAIL percentiles. percentile() is nearest-rank (no
	# interpolation), so for a high pct at small n the index pins to the top
	# element — p99 == max(n), a single worst sample masquerading as a tail
	# quantile. Below PCT_MIN_N samples, refuse to report p95/p99 (emit N/A); p50
	# is robust at low n so it is always returned. PCT_MIN_N defaults to 20 here
	# and is threaded from PROPAGATION_PERCENTILE_MIN_N; 0 disables the gate.
	min_n = (PCT_MIN_N == "" ? 20 : PCT_MIN_N + 0)
	if (pct >= 95 && min_n > 0 && n < min_n) return "N/A"
	# Nearest rank = ceil(n * pct / 100). Flooring it made p50 of 3 samples the minimum.
	rank = n * pct / 100
	idx = int(rank)
	if (rank - idx > 1e-9) idx++
	if (idx < 1) idx = 1
	if (idx > n) idx = n
	return arr[idx]
}
# Histogram phases (P1_conv_*) hold bucket upper bounds in ms; bucket_range turns one
# into its range label. Their mean can land in a bucket no row hit, so the text and
# markdown tables never bucket an average: the avg cell of a histogram row is "-" and
# max is the worst bucket. csv/json keep the numbers and add worst_bucket.
function bucket_range(upper_ms) {
	if (upper_ms+0 <= 0)     return "N/A"
	if (upper_ms+0 <= 100)   return "0-100"
	if (upper_ms+0 <= 500)   return "100-500"
	if (upper_ms+0 <= 1000)  return "500-1000"
	if (upper_ms+0 <= 3000)  return "1000-3000"
	if (upper_ms+0 <= 5000)  return "3000-5000"
	if (upper_ms+0 <= 10000) return "5000-10000"
	if (upper_ms+0 <= 20000) return "10000-20000"
	if (upper_ms+0 <= 30000) return "20000-30000"
	return ">30000"
}
function asorti_seen(    i, k) {
	# mawk lacks asorti — emit sorted keys from seen[] manually.
	delete __sorted
	__n = 0
	for (k in seen) { __sorted[++__n] = k }
	# insertion sort, numeric: keys are mesh sizes, and array subscripts are
	# strings, so a plain > would order 10 before 2.
	for (i = 2; i <= __n; i++) {
		__tmp = __sorted[i]; j = i - 1
		while (j >= 1 && __sorted[j]+0 > __tmp+0) { __sorted[j+1] = __sorted[j]; j-- }
		__sorted[j+1] = __tmp
	}
}
'

report_endpoint_text() {
	echo "=== Endpoint Propagation Latency ==="
	echo ""
	[[ -z "$POOLED_NOTE" ]] || printf 'POOLED RUNS: %s\n\n' "$POOLED_NOTE"
	sweep_outcome_recorded "$RESULTS_DIR" text
	echo "Run metadata:"
	format_preamble_text
	echo ""
	cat "${ENDPOINT_FILES[@]}" | awk -v MAXSKEW="${FANOUT_MAX_SKEW_MS:-1000}" -v PCT_MIN_N="${PROPAGATION_PERCENTILE_MIN_N:-20}" "$AWK_AGG"'
	function stats_line(label, src, ms, n,    arr, sum, i) {
		if (n == 0) {
			printf "  %-3s | %-26s | %5d | %5s | %11s | %11s | %11s | %11s | %11s | %11s\n",
				ms, label, phase_total(label, ms), "-", "-", "-", "-", "-", "-", "-"
			return
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		printf "  %-3s | %-26s | %5d | %5d | %11d | %11d | %11.0f | %11s | %11s | %11s\n",
			ms, label, phase_total(label, ms), n, arr[1], arr[n], sum/n,
			percentile(arr, n, 50), percentile(arr, n, 95), percentile(arr, n, 99)
	}
	# Histogram rows: no average (see bucket_range); max is the worst bucket.
	function stats_line_hist(label, src, ms, n,    arr) {
		if (n == 0) {
			printf "  %-3s | %-26s | %5d | %5s | %11s | %11s | %11s | %11s | %11s | %11s\n",
				ms, label, phase_total(label, ms), "-", "-", "-", "-", "-", "-", "-"
			return
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		printf "  %-3s | %-26s | %5d | %5d | %11s | %11s | %11s | %11s | %11s | %11s\n",
			ms, label, phase_total(label, ms), n,
			bucket_range(arr[1]), bucket_range(arr[n]), "-",
			bucket_range(percentile(arr, n, 50)),
			bucket_range(percentile(arr, n, 95)),
			bucket_range(percentile(arr, n, 99))
	}
	END {
		printf "  %-3s | %-26s | %5s | %5s | %11s | %11s | %11s | %11s | %11s | %11s\n",
			"Sz", "Phase", "n_tot", "n_val", "min", "max", "avg", "p50", "p95", "p99"
		printf "  %-3s-+-%-26s-+-%5s-+-%5s-+-%11s-+-%11s-+-%11s-+-%11s-+-%11s-+-%11s\n",
			"---", "--------------------------", "-----", "-----", "-----------", "-----------", "-----------", "-----------", "-----------", "-----------"
		asorti_seen()
		for (s = 1; s <= __n; s++) {
			ms_cur = __sorted[s]
			stats_line("P1 local xDS (wall)",    p1_vals,   ms_cur, p1_n[ms_cur])
			stats_line_hist("P1 conv_p50 (hist)", cp50_vals, ms_cur, cp50_n[ms_cur])
			stats_line_hist("P1 conv_p99 (hist)", cp99_vals, ms_cur, cp99_n[ms_cur])
			stats_line("P2 remote istiod EDS",   p2_vals,   ms_cur, p2_n[ms_cur])
			stats_line("P3 remote sidecar",      p3_vals,   ms_cur, p3_n[ms_cur])
		}
	}'
	echo ""
	istiod_diag_report text "$RESULTS_DIR"
}

report_endpoint_csv() {
	format_preamble_csv_header
	config_multi_run_csv
	sweep_outcome_recorded "$RESULTS_DIR" csv
	echo ""
	# worst_bucket: the bucket range of max_ms, for the histogram phases only.
	echo "mesh_size,phase,n_total,n_valid,min_ms,max_ms,avg_ms,p50_ms,p95_ms,p99_ms,worst_bucket"
	cat "${ENDPOINT_FILES[@]}" | awk -v MAXSKEW="${FANOUT_MAX_SKEW_MS:-1000}" -v PCT_MIN_N="${PROPAGATION_PERCENTILE_MIN_N:-20}" "$AWK_AGG"'
	function csv_line(ms, phase, src, n, hist,    arr, sum, i) {
		if (n == 0) {
			printf "%s,%s,%d,%d,,,,,,,\n", ms, phase, phase_total(phase, ms), 0
			return
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		printf "%s,%s,%d,%d,%d,%d,%.0f,%s,%s,%s,%s\n",
			ms, phase, phase_total(phase, ms), n, arr[1], arr[n], sum/n,
			percentile(arr, n, 50), percentile(arr, n, 95), percentile(arr, n, 99),
			(hist ? bucket_range(arr[n]) : "")
	}
	END {
		asorti_seen()
		for (s = 1; s <= __n; s++) {
			m = __sorted[s]
			csv_line(m, "P1_local_wall",   p1_vals,   p1_n[m], 0)
			csv_line(m, "P1_conv_p50",     cp50_vals, cp50_n[m], 1)
			csv_line(m, "P1_conv_p99",     cp99_vals, cp99_n[m], 1)
			csv_line(m, "P2_discovery",    p2_vals,   p2_n[m], 0)
			csv_line(m, "P3_dataplane",    p3_vals,   p3_n[m], 0)
		}
	}'
}

# Metric glossary appended to the end of the markdown summary.
glossary_section() {
	cat <<'GLOSSARY'

## Glossary

Definitions for every phase and statistic column in the tables above (see also
`tests/propagation/README.md`). Each phase measures one stage of a single config change
propagating across the mesh; all values are **milliseconds**. Remote phases (P2/P3) are
undefined at mesh size 1 (no remote cluster). P2 and P3 are measured on a remote, so a row
is dropped from them (not counted in `n_valid`) only for that remote's side: `remote_status
!= OK` (its istiod restarted or unknown, a P2 or P3 timeout, its sidecar's drain timeout, its
scrape incomplete) or `remote_scrape_skew_ms` over `FANOUT_MAX_SKEW_MS`, never for the
source's restart, P1 timeout or `p1_overflow`. A TSV without `remote_status` cannot split a row
by side: `status != OK`, `restarted ∈ {1, unknown}` or a high `scrape_skew_ms` drop it. P2
additionally drops `p2_dirty=1` rows (an EDS bump not confirmed by the remote sidecar going
healthy). The P1
phases are measured on the source, so only the source side drops an iteration's P1:
`p1_status != OK` (a P1 timeout, a source istiod restart or unknown restart state, a source
sidecar drain timeout, a source scrape that failed), `p1_overflow=1`, or `p1_scrape_skew_ms`
over `FANOUT_MAX_SKEW_MS`; a remote that timed out or restarted does not.

| Phase | Units | Source | Definition / caveats |
|-------|-------|--------|----------------------|
| `P1_local_wall` | ms (wall clock) | timing + source `pilot_proxy_convergence_time` | Time from the t0 active-label flip until the source istiod has pushed the change to all connected proxies (delta `_count` reaches proxy count). |
| `P1_conv_p50` | ms (bucket range) | source `pilot_proxy_convergence_time` histogram delta | p50 of the per-bucket convergence-time delta in the window; bucket range (boundaries 100/500/1000/3000/5000/10000/20000/30000 ms); `N/A` if restarted or below the p50 min-sample floor. An iteration whose window put any sample in `+Inf` (`p1_overflow=1`) is dropped from the P1 phases (never from P2/P3), so `overflow` never reaches this table: it shows as `n_valid < n_total`. |
| `P1_conv_p99` | ms (bucket range) | source `pilot_proxy_convergence_time` histogram delta | p99 of the convergence-time delta; same bucket-range and overflow handling; `N/A` if restarted or below the p99 min-sample floor (`PROPAGATION_PERCENTILE_MIN_N`). |
| `P2_discovery` | ms (wall clock) | remote `pilot_xds_pushes{type="eds"}` counter delta | Time until the remote istiod pushes EDS for the new endpoint (control-plane discovery); excluded when `p2_dirty=1`. |
| `P3_dataplane` | ms (wall clock) | remote watcher Envoy `/clusters` | Time until the remote sidecar reports the canary endpoint healthy (full data-plane apply); typically ~10× P1/P2. |

| Stat column | Definition |
|-------------|------------|
| `n_total` | All rows considered for the phase/mesh size, kept or dropped. For the P1 phases, iterations (distinct run_id and iteration, as the probe's summary counts them), so a clean run reads `n_total == n_valid` and an overflowed iteration shows as one less `n_valid`. |
| `n_valid` | Samples used for the statistics: rows surviving the drop filters above. For the P1 phases, iterations: P1 is measured on the source once per iteration and repeated on every remote's row, so it counts once per iteration whose source side is clean (from the iteration's first valid row in a TSV without `p1_status`). |
| `min_ms` / `max_ms` / `avg_ms` | Minimum / maximum / mean (rounded to ms) latency across the `n_valid` samples. A histogram row (`P1 conv_*`) has no average (`-`): the mean of bucket bounds can land in a bucket no row hit, so read `max` (the worst bucket). CSV and JSON keep the numbers and add `worst_bucket`, the range of `max_ms`, for those phases. |
| `p50_ms` / `p95_ms` / `p99_ms` | Nearest-rank percentiles across the `n_valid` samples; `p95`/`p99` are `N/A` below `PROPAGATION_PERCENTILE_MIN_N` samples (a single worst sample would otherwise masquerade as a tail quantile). |
GLOSSARY
}

report_endpoint_markdown() {
	echo "---"
	format_preamble_md
	echo "generated: $(date -u -Iseconds)"
	echo "---"
	echo ""
	echo "# Endpoint Propagation Latency"
	echo ""
	[[ -z "$POOLED_NOTE" ]] || printf '> **Pooled runs.** %s\n\n' "$POOLED_NOTE"
	sweep_outcome_recorded "$RESULTS_DIR" md
	echo "**Source files:** ${#ENDPOINT_FILES[@]} TSV file(s)"
	echo ""
	for f in "${ENDPOINT_FILES[@]}"; do
		echo "- \`${f##*/}\`"
	done
	echo ""
	cat "${ENDPOINT_FILES[@]}" | awk -v MAXSKEW="${FANOUT_MAX_SKEW_MS:-1000}" -v PCT_MIN_N="${PROPAGATION_PERCENTILE_MIN_N:-20}" "$AWK_AGG"'
	function md_row(phase, src, ms, n,    arr, sum, i) {
		if (n == 0) {
			printf "| %s | %d | %d | - | - | - | - | - | - |\n", phase, phase_total(phase, ms), 0
			return
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		printf "| %s | %d | %d | %d | %d | %.0f | %s | %s | %s |\n",
			phase, phase_total(phase, ms), n, arr[1], arr[n], sum/n,
			percentile(arr, n, 50), percentile(arr, n, 95), percentile(arr, n, 99)
	}
	# Histogram rows: no average (see bucket_range); max is the worst bucket.
	function md_row_hist(phase, src, ms, n,    arr) {
		if (n == 0) {
			printf "| %s | %d | %d | - | - | - | - | - | - |\n", phase, phase_total(phase, ms), 0
			return
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		printf "| %s | %d | %d | %s | %s | - | %s | %s | %s |\n",
			phase, phase_total(phase, ms), n,
			bucket_range(arr[1]), bucket_range(arr[n]),
			bucket_range(percentile(arr, n, 50)),
			bucket_range(percentile(arr, n, 95)),
			bucket_range(percentile(arr, n, 99))
	}
	function cmp_avg(src, ms, n,    arr, sum, i) {
		if (n == 0) return "-- (0)"
		load(arr, src, ms, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		return sprintf("%.0f (%d)", sum/n, n)
	}
	# The worst bucket any valid row hit, never the bucket of the mean.
	function cmp_worst_hist(src, ms, n,    arr) {
		if (n == 0) return "-- (0)"
		load(arr, src, ms, n)
		sort_arr(arr, n)
		return sprintf("%s (%d)", bucket_range(arr[n]), n)
	}
	END {
		asorti_seen()
		for (s = 1; s <= __n; s++) {
			ms_cur = __sorted[s]
			printf "## Mesh size: %s\n\n", ms_cur
			printf "| Phase | n_total | n_valid | min (ms) | max (ms) | avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) |\n"
			printf "|-------|---------|---------|----------|----------|----------|----------|----------|----------|\n"
			md_row("P1 local xDS (wall)",  p1_vals,   ms_cur, p1_n[ms_cur])
			md_row_hist("P1 conv_p50 (hist)",   cp50_vals, ms_cur, cp50_n[ms_cur])
			md_row_hist("P1 conv_p99 (hist)",   cp99_vals, ms_cur, cp99_n[ms_cur])
			md_row("P2 remote istiod EDS", p2_vals,   ms_cur, p2_n[ms_cur])
			md_row("P3 remote sidecar",    p3_vals,   ms_cur, p3_n[ms_cur])
			printf "\n"
		}
		# Cross-mesh-size comparison (only meaningful when >1 mesh size was swept).
		if (__n > 1) {
			printf "## Comparison across mesh sizes\n\n"
			printf "Averages over rows surviving the report filter (P1: its source side, p1_status != OK, "
			printf "p1_overflow=1 or a high source skew drop it; P2/P3: the remote side, remote_status != OK "
			printf "or a high remote skew; P2 also drops p2_dirty=1 rows). "
			printf "Cells show `avg (n_valid)`, except P1 conv_p99: the worst bucket any valid row hit "
			printf "`(n_valid)`, never averaged. Per-mesh-size tables above carry the full breakdown.\n\n"
			printf "| Mesh Size | P1 wall avg (ms) | P1 conv_p99 worst (ms) | P2 EDS avg (ms) | P3 sidecar avg (ms) |\n"
			printf "|-----------|------------------|------------------------|-----------------|---------------------|\n"
			for (s = 1; s <= __n; s++) {
				ms_cur = __sorted[s]
				printf "| %s | %s | %s | %s | %s |\n",
					ms_cur,
					cmp_avg(p1_vals,   ms_cur, p1_n[ms_cur]),
					cmp_worst_hist(cp99_vals, ms_cur, cp99_n[ms_cur]),
					cmp_avg(p2_vals,   ms_cur, p2_n[ms_cur]),
					cmp_avg(p3_vals,   ms_cur, p3_n[ms_cur])
			}
			printf "\n"
		}
	}'

	istiod_diag_report md "$RESULTS_DIR"
	echo ""

	# Metric glossary at the very end of the markdown summary.
	glossary_section
}

report_endpoint_json() {
	# Emit a single object: { metadata: {...}, rows: [...] }.
	printf '{"metadata":'
	format_preamble_json
	printf ',"pooled_runs":%s' "$(config_multi_run_json)"
	printf ',"sweep_outcome":%s' "$(sweep_outcome_recorded "$RESULTS_DIR" json)"
	printf ',"rows":'
	cat "${ENDPOINT_FILES[@]}" | awk -v MAXSKEW="${FANOUT_MAX_SKEW_MS:-1000}" -v PCT_MIN_N="${PROPAGATION_PERCENTILE_MIN_N:-20}" "$AWK_AGG"'
	function jnum(v) { return (v == "N/A" ? "null" : v) }
	# mesh_size is a number (it was a string); worst_bucket (the range of max_ms) is set
	# for the histogram phases, null for the wall-clock ones.
	function jms(ms) { return (ms ~ /^[0-9]+$/) ? ms : sprintf("\"%s\"", ms) }
	function json_obj(ms, phase, src, n, hist,    arr, sum, i) {
		if (n == 0) {
			return sprintf("{\"mesh_size\":%s,\"phase\":\"%s\",\"n_total\":%d,\"n_valid\":0,\"min_ms\":null,\"max_ms\":null,\"avg_ms\":null,\"p50_ms\":null,\"p95_ms\":null,\"p99_ms\":null,\"worst_bucket\":null}", jms(ms), phase, phase_total(phase, ms))
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		return sprintf("{\"mesh_size\":%s,\"phase\":\"%s\",\"n_total\":%d,\"n_valid\":%d,\"min_ms\":%d,\"max_ms\":%d,\"avg_ms\":%.0f,\"p50_ms\":%s,\"p95_ms\":%s,\"p99_ms\":%s,\"worst_bucket\":%s}",
			jms(ms), phase, phase_total(phase, ms), n, arr[1], arr[n], sum/n,
			jnum(percentile(arr, n, 50)), jnum(percentile(arr, n, 95)), jnum(percentile(arr, n, 99)),
			(hist ? sprintf("\"%s\"", bucket_range(arr[n])) : "null"))
	}
	END {
		printf "["
		first = 1
		asorti_seen()
		for (s = 1; s <= __n; s++) {
			m = __sorted[s]
			if (!first) printf ","; printf "%s", json_obj(m, "P1_local_wall", p1_vals,   p1_n[m], 0);   first = 0
			printf ",";             printf "%s", json_obj(m, "P1_conv_p50",   cp50_vals, cp50_n[m], 1)
			printf ",";             printf "%s", json_obj(m, "P1_conv_p99",   cp99_vals, cp99_n[m], 1)
			printf ",";             printf "%s", json_obj(m, "P2_discovery",  p2_vals,   p2_n[m], 0)
			printf ",";             printf "%s", json_obj(m, "P3_dataplane",  p3_vals,   p3_n[m], 0)
		}
		printf "]"
	}'
	printf ',"istiod_diag":'
	istiod_diag_report json "$RESULTS_DIR"
	printf '}\n'
}

report_endpoint_charts() {
	echo "---"
	format_preamble_md
	echo "generated: $(date -u -Iseconds)"
	echo "---"
	echo ""
	echo "# Endpoint Propagation Latency — Charts"
	echo ""
	[[ -z "$POOLED_NOTE" ]] || printf '> **Pooled runs.** %s\n\n' "$POOLED_NOTE"
	cat "${ENDPOINT_FILES[@]}" | awk -v MAXSKEW="${FANOUT_MAX_SKEW_MS:-1000}" -v PCT_MIN_N="${PROPAGATION_PERCENTILE_MIN_N:-20}" "$AWK_AGG"'
	function chart_avg(src, ms, n,    arr, sum, i) {
		if (n == 0) return -1
		load(arr, src, ms, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		return sum / n
	}
	END {
		asorti_seen()
		if (__n < 2) {
			print "> Charts require at least two mesh sizes."
			exit
		}
		# Collect mesh sizes >= 2 (remote series undefined at mesh 1).
		n_remote = 0
		for (s = 1; s <= __n; s++) {
			ms = __sorted[s]
			if (ms + 0 >= 2) {
				n_remote++
				remote_ms[n_remote] = ms
			}
		}
		if (n_remote < 2) {
			print "> Charts require at least two mesh sizes with remote data (mesh >= 2)."
			exit
		}

		# PL13/PL15 gate: each charted phase point is the mean over n_valid samples
		# (p{1,2,3}_n[ms]). A phase/mesh cell with zero valid samples is ABSENT (chart_avg
		# returns -1, rendered as the structural 0 filler the mermaid xychart requires),
		# not a real 0 latency point. Count those dropped cells across the plotted grid
		# (P1, P2, P3 x remote mesh sizes) and caption it, mirroring the markdown footnote.
		cells_total = 0; cells_dropped = 0
		for (i = 1; i <= n_remote; i++) {
			m = remote_ms[i]
			cells_total += 3
			if (p1_n[m] + 0 == 0) cells_dropped++
			if (p2_n[m] + 0 == 0) cells_dropped++
			if (p3_n[m] + 0 == 0) cells_dropped++
		}
		if (cells_dropped > 0) {
			printf "> %d of %d charted cells dropped (no valid samples / restart-poisoned / overflow) — not plotted.\n\n", cells_dropped, cells_total
		}

		# Chart 1: P1 wall + P2 EDS latency vs mesh size
		printf "```mermaid\n"
		printf "xychart-beta\n"
		printf "    title \"P1 + P2 Latency vs Mesh Size\"\n"
		printf "    x-axis \"Mesh Size\" ["
		for (i = 1; i <= n_remote; i++) {
			if (i > 1) printf ", "
			printf "%s", remote_ms[i]
		}
		printf "]\n"
		printf "    y-axis \"Latency (ms)\"\n"
		printf "    line ["; sep = ""
		for (i = 1; i <= n_remote; i++) {
			v = chart_avg(p1_vals, remote_ms[i], p1_n[remote_ms[i]])
			printf "%s%.0f", sep, (v < 0 ? 0 : v); sep = ", "
		}
		printf "]\n"
		printf "    line ["; sep = ""
		for (i = 1; i <= n_remote; i++) {
			v = chart_avg(p2_vals, remote_ms[i], p2_n[remote_ms[i]])
			printf "%s%.0f", sep, (v < 0 ? 0 : v); sep = ", "
		}
		printf "]\n"
		printf "```\n"
		printf "\n"
		printf "> Series order: **P1 wall avg** (ms), **P2 EDS avg** (ms).\n"
		printf "> x-axis starts at mesh 2 — P2 is undefined at mesh size 1 (no remote cluster).\n"
		printf "\n"

		# Chart 2: P3 remote sidecar latency vs mesh size
		printf "```mermaid\n"
		printf "xychart-beta\n"
		printf "    title \"P3 Remote Sidecar Latency vs Mesh Size\"\n"
		printf "    x-axis \"Mesh Size\" ["
		for (i = 1; i <= n_remote; i++) {
			if (i > 1) printf ", "
			printf "%s", remote_ms[i]
		}
		printf "]\n"
		printf "    y-axis \"Latency (ms)\"\n"
		printf "    line ["; sep = ""
		for (i = 1; i <= n_remote; i++) {
			v = chart_avg(p3_vals, remote_ms[i], p3_n[remote_ms[i]])
			printf "%s%.0f", sep, (v < 0 ? 0 : v); sep = ", "
		}
		printf "]\n"
		printf "```\n"
		printf "\n"
		printf "> Series: **P3 sidecar avg** (ms). Separate chart — P3 is typically ~10x P1/P2 scale.\n"
	}'
}

case "$FORMAT" in
text)
	echo "Files: ${ENDPOINT_FILES[*]}"
	report_endpoint_text
	;;
csv)
	report_endpoint_csv
	;;
json)
	report_endpoint_json
	;;
markdown|md)
	echo "Files: ${ENDPOINT_FILES[*]}" >&2
	report_endpoint_markdown
	;;
charts)
	echo "Files: ${ENDPOINT_FILES[*]}" >&2
	report_endpoint_charts
	;;
*)
	die "unknown format: $FORMAT (use text, csv, json, markdown, or charts)"
	;;
esac
