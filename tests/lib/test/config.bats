#!/usr/bin/env bats
# tests/lib/config.sh (`--config FILE` run configs) and its use by tests/controlplane/001-005:
# the parser and the vocabulary, precedence and provenance, then the controlplane scripts
# through their real entrypoints (PL33). No cluster: every script runs with KUBECONFIG pointing
# at an empty file. The other suites' scripts are tested in config-suites.bats. The parser and
# the vocabulary run in a child bash: config_allowed_keys forks once per options.env key, which
# under bats' DEBUG trap takes seconds per suite.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/config.sh"

GOOD="${ROOT}/tests/lib/test/fixtures/config/good.env"
SMOKE="${ROOT}/tests/controlplane/configs/smoke.env"
CP="${ROOT}/tests/controlplane"
REPORT_FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"

# The keys good.env sets, in file order.
GOOD_KEYS=(CONTROLPLANE_SERVICE_COUNT CONTROLPLANE_REPLICAS_PER_SERVICE CONTROLPLANE_SIDECAR_SCOPING
	CONTROLPLANE_RESULTS_DIR SETUP_CONTEXTS CONTROLPLANE_SETTLE_SEC CONTROLPLANE_TRAFFIC_CONFIG
	SCALE_TARGET_FRACTION METRICS_SCRAPE_TIMEOUT FANOUT_PF_BASE CAP_TOP_TIMEOUT)

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
}

# cfg <name> <line>...: write a config file into the test tmpdir and print its path.
cfg() {
	local f="${BATS_TEST_TMPDIR}/$1"
	shift
	printf '%s\n' "$@" > "$f"
	printf '%s' "$f"
}

# loaded <file> <key>...: load_config the file in a clean bash, print KEY=value per key.
# LOAD_SUITE (default controlplane) picks the key map.
# (stdin from /dev/null: a clean bash whose stdin is a socket may read ~/.bashrc.)
loaded() {
	local f="$1"
	shift
	env -i PATH="$PATH" ROOT="$ROOT" SUITE="${LOAD_SUITE:-controlplane}" bash -c '
		set -euo pipefail
		source "$ROOT/tests/lib/common.sh"
		source "$ROOT/tests/lib/config.sh"
		f="$1"; shift
		load_config "$f" "$SUITE" 2>/dev/null
		for k in "$@"; do printf "%s=%s\n" "$k" "${!k-<unset>}"; done' _ "$f" "$@" </dev/null
}

# sourced <file> <key>...: the same values the way a shell sees them (set -a; source).
sourced() {
	local f="$1"
	shift
	env -i PATH="$PATH" bash -c '
		f="$1"; shift
		set -a; source "$f"; set +a
		for k in "$@"; do printf "%s=%s\n" "$k" "${!k-<unset>}"; done' _ "$f" "$@" </dev/null
}

# file_keys <file>: the keys a config file assigns.
file_keys() {
	sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)=.*/\2/p' "$1"
}

# ---------------------------------------------------------------------------
# Parser and vocabulary
# ---------------------------------------------------------------------------

@test "load_config: every accepted form gives its exact value (CRLF and no final newline too); every committed example means what a shell reads and sets no SETUP_CONTEXTS" {
	run loaded "$GOOD" "${GOOD_KEYS[@]}"
	assert_success
	assert_output "$(printf '%s\n' \
		'CONTROLPLANE_SERVICE_COUNT=5' \
		'CONTROLPLANE_REPLICAS_PER_SERVICE=2' \
		'CONTROLPLANE_SIDECAR_SCOPING=namespace' \
		'CONTROLPLANE_RESULTS_DIR=results dir/with space' \
		'SETUP_CONTEXTS=ctx-a,ctx-b' \
		'CONTROLPLANE_SETTLE_SEC=7' \
		'CONTROLPLANE_TRAFFIC_CONFIG=' \
		'SCALE_TARGET_FRACTION=0.5' \
		'METRICS_SCRAPE_TIMEOUT=a$b`c "d"' \
		'FANOUT_PF_BASE=a=b:c/d@e%f+g-h.i,j' \
		'CAP_TOP_TIMEOUT=')"
	[ "$output" = "$(sourced "$GOOD" "${GOOD_KEYS[@]}")" ]
	local crlf="${BATS_TEST_TMPDIR}/crlf.env" f s keys n=0
	awk '{ printf "%s%s", (NR > 1 ? "\r\n" : ""), $0 }' "$GOOD" > "$crlf"
	grep -q $'\r' "$crlf"
	[ "$(loaded "$crlf" "${GOOD_KEYS[@]}")" = "$output" ]
	for f in "$ROOT"/tests/*/configs/*.env; do
		s="${f%/configs/*}"
		s="${s##*/}"
		mapfile -t keys < <(file_keys "$f")
		[ "${#keys[@]}" -gt 0 ]
		[ "$(LOAD_SUITE="$s" loaded "$f" "${keys[@]}")" = "$(sourced "$f" "${keys[@]}")" ] \
			|| { echo "${f#"$ROOT"/}: loaded != sourced"; false; }
		# No real context names in a committed example.
		! grep -qE '^[[:space:]]*(export[[:space:]]+)?SETUP_CONTEXTS=' "$f" || { echo "${f#"$ROOT"/} sets SETUP_CONTEXTS"; false; }
		n=$((n + 1))
	done
	# One example per suite with a key map at least.
	((n >= 6))
}

# _block <name>: the output of one case of the refusal batch below (in $BATCH).
_block() {
	awk -v n="== $1 " 'index($0, n) == 1 { on = 1; print; next } /^== / { on = 0 } on' <<<"$BATCH"
}

@test "load_config refuses a whole file that a shell would read otherwise or that sets a key its suite does not take, naming file:line and why; nothing runs, nothing is exported" {
	local d="${BATS_TEST_TMPDIR}/bad" pw="${BATS_TEST_TMPDIR}/pwned" c b
	mkdir -p "$d"
	# <suite>--<case>.env | the line it names | the reason.
	local -a cases=(
		"controlplane--subst|1|\$ and \` are not allowed outside single quotes|CONTROLPLANE_SETTLE_SEC=\$(touch ${pw})"
		"controlplane--backtick|1|\$ and \` are not allowed outside single quotes|CONTROLPLANE_SETTLE_SEC=\`touch ${pw}\`"
		"controlplane--semicolon|1|bad value|CONTROLPLANE_SETTLE_SEC=1;touch x"
		"controlplane--quote|1|bad value|CONTROLPLANE_SETTLE_SEC='1"
		"controlplane--backslash|1|bad value|CONTROLPLANE_SETTLE_SEC=\"a\\b\""
		"controlplane--spaces|1|no spaces around '='|CONTROLPLANE_SETTLE_SEC = 1"
		"controlplane--lower|1|keys are upper case|controlplane_settle_sec=1"
		"controlplane--words|1|not a KEY=value line|just words"
		"controlplane--typo|1|unknown key CONTROLPLANE_SERVICE_COUTN for the controlplane suite|CONTROLPLANE_SERVICE_COUTN=5"
		"controlplane--preload|1|unknown key LD_PRELOAD|LD_PRELOAD=/tmp/x.so"
		"controlplane--pin|1|ISTIO_VERSION is a version pin|ISTIO_VERSION=v1.0.0"
		"controlplane--internal|1|CONTROLPLANE_TEST_NAMESPACE is not settable from --config|CONTROLPLANE_TEST_NAMESPACE=istio-system"
		"controlplane--check|1|ISTIO_VERSION_CHECK is not settable from --config (env only|ISTIO_VERSION_CHECK=warn"
		"controlplane--grace|1|SWEEP_STOP_GRACE_SEC is not settable from --config (env only|SWEEP_STOP_GRACE_SEC=1"
		"dataplane--other|1|unknown key COEXEC_QPS for the dataplane suite (allowed: SETUP_CONTEXTS and the config/options.env keys DATAPLANE_*|COEXEC_QPS=5"
	)
	for c in "${cases[@]}"; do
		IFS='|' read -r b _ _ line <<<"$c"
		printf '%s\n' "$line" > "${d}/${b}.env"
	done
	# A duplicate key, and a bad last line after good ones: the whole file is refused.
	printf '%s\n' 'CONTROLPLANE_SETTLE_SEC=1' '# comment' 'CONTROLPLANE_SETTLE_SEC=2' > "${d}/controlplane--dup.env"
	printf '%s\n' 'CONTROLPLANE_SERVICE_COUNT=5' 'CONTROLPLANE_SETTLE_SEC=9' 'CONTROLPLANE_SETTLE_SEX=1' > "${d}/controlplane--late.env"
	printf '%s\n' 'CHURN_TEST_NAMESPACE=istio-system' 'COEXEC_TEST_NAMESPACE=istio-system' > "${d}/churn-dataplane--two.env"
	cases+=("controlplane--dup|3|duplicate key CONTROLPLANE_SETTLE_SEC (also on line 1)|"
		"controlplane--late|3|unknown key CONTROLPLANE_SETTLE_SEX|"
		"churn-dataplane--two|1|unknown key CHURN_TEST_NAMESPACE for the churn-dataplane suite|"
		"churn-dataplane--two|2|COEXEC_TEST_NAMESPACE is not settable from --config|")
	# Each file in a subshell of one clean bash; its EXIT trap shows what was exported.
	run env -i PATH="$PATH" ROOT="$ROOT" bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/config.sh"
		for f in "$@"; do
			b="${f##*/}"; b="${b%.env}"; s="${b%%--*}"; rc=0
			out="$( (trap '\''echo "exported: svc=${CONTROLPLANE_SERVICE_COUNT-unset} settle=${CONTROLPLANE_SETTLE_SEC-unset}"'\'' EXIT
				load_config "$f" "$s") 2>&1)" || rc=$?
			printf "== %s rc=%s\n%s\n" "$b" "$rc" "$out"
		done' _ "$d"/*.env </dev/null
	BATCH="$output"
	[ ! -e "$pw" ]
	for c in "${cases[@]}"; do
		IFS='|' read -r b line reason _ <<<"$c"
		run -0 _block "$b"
		[[ "$output" == "== ${b} rc=1"* ]] || { echo "$output"; false; }
		[[ "$output" == *"${d}/${b}.env:${line}: ${reason}"* ]] || { echo "$output"; false; }
		[[ "$output" == *"nothing was applied"* && "$output" != *"[config]"* ]] || { echo "$output"; false; }
		[[ "$output" == *"exported: svc=unset settle=unset"* ]] || { echo "$output"; false; }
	done
	# A missing file and a suite without a key map die too.
	run bash -c 'source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/config.sh"; load_config "$1" controlplane' _ "${d}/nope.env"
	assert_failure 1
	assert_output --partial "nope.env: not a readable file"
	run bash -c 'source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/config.sh"; load_config "$1" tuning' _ "$GOOD"
	assert_failure 1
	assert_output --partial "the 'tuning' suite has no config key map yet"
}

@test "config_allowed_keys: a suite's options.env exports and shared keys, never an env-only key or another suite's; a file setting each of controlplane's loads" {
	local all="${BATS_TEST_TMPDIR}/all.env" c s yes no k
	run bash -c 'source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/config.sh"
		for s in controlplane dataplane churn churn-dataplane propagation gateway-api; do
			config_allowed_keys "$s" | sed "s/^/${s} /"
		done
		config_allowed_keys controlplane | sed "s/\$/=1/" > "$1"
		load_config "$1" controlplane 2>&1 | grep -c "^\[config\]" | sed "s/^/loaded /"
		_config_key_matches CHURN_DEPLOYMENT_COUNTS CHURN_DEPLOYMENT_COUNT && echo "prefix: whole name matched"
		_config_key_matches DATAPLANE_QPS_LEVELS DATAPLANE_ && echo "prefix: DATAPLANE_ matched"' _ "$all" </dev/null
	assert_success
	# suite | keys it must allow | keys it must not allow
	local -a cases=(
		"controlplane|SETUP_CONTEXTS CONTROLPLANE_SERVICE_COUNT CONTROLPLANE_MESH_SIZES CONTROLPLANE_TRAFFIC_CONFIGS CONTROLPLANE_NS_DELETE_TIMEOUT_SEC SCALE_SIZING_MODE METRICS_SCRAPE_TIMEOUT FANOUT_MAX_SKEW_MS CAP_TOP_TIMEOUT ISTIOD_DIAG_ENABLED TEST_PLATFORM|CONTROLPLANE_TEST_NAMESPACE CONTROLPLANE_MAX_MATRIX ISTIO_VERSION BUSYBOX_VERSION ISTIO_VERSION_CHECK DATAPLANE_QPS_LEVELS METRICS_API_STATUS PATH"
		"dataplane|DATAPLANE_QPS_LEVELS DATAPLANE_MESH_SIZES DATAPLANE_NS_DELETE_TIMEOUT_SEC REACH_REQUESTS REACH_ON_UNREACHABLE FANOUT_MAX_SKEW_MS SETUP_CONTEXTS|DATAPLANE_TEST_NAMESPACE DATAPLANE_MAX_MATRIX METRICS_READY_TIMEOUT CONTROLPLANE_SERVICE_COUNT COEXEC_QPS CAP_TOP_TIMEOUT SCALE_SIZING_MODE"
		"churn|CHURN_DEPLOYMENT_COUNT CHURN_INTENSITIES CHURN_MESH_SIZES FANOUT_PF_BASE METRICS_SCRAPE_TIMEOUT|CHURN_TEST_NAMESPACE REACH_REQUESTS COEXEC_QPS DATAPLANE_QPS_LEVELS"
		"churn-dataplane|COEXEC_QPS COEXEC_MESH_SIZES COEXEC_ISTIOD_REPLICAS REACH_REQUESTS CHURN_DEPLOYMENT_COUNT CHURN_BASE_REPLICAS CHURN_SCALE_TO_REPLICAS|COEXEC_TEST_NAMESPACE CHURN_TEST_NAMESPACE CHURN_ITERATIONS CHURN_INTENSITIES CHURN_SETTLE_SEC DATAPLANE_QPS_LEVELS"
		"propagation|PROPAGATION_ITERATIONS PROPAGATION_MESH_SIZES PROPAGATION_SNAPSHOT_PF_BASE FANOUT_CTX_STRIDE|PROPAGATION_TEST_NAMESPACE PROPAGATION_MAX_MATRIX REACH_REQUESTS METRICS_READY_INTERVAL"
		"gateway-api|GWAPI_WORKLOAD_CONTEXT GWAPI_REQUESTS GWAPI_GATE_PASSES GWAPI_REPROBE_DELAY_SEC SETUP_CONTEXTS|REACH_REQUESTS FANOUT_PF_BASE METRICS_SCRAPE_TIMEOUT DATAPLANE_QPS_LEVELS"
	)
	for c in "${cases[@]}"; do
		IFS='|' read -r s yes no <<<"$c"
		for k in $yes; do grep -qx "${s} ${k}" <<<"$output" || { echo "${s}: missing ${k}"; false; }; done
		for k in $no; do ! grep -qx "${s} ${k}" <<<"$output" || { echo "${s}: unexpected ${k}"; false; }; done
	done
	# Every key a suite takes is an options.env export (or SETUP_CONTEXTS), so a key added
	# there later is taken with no change here; and every one of them loads.
	for k in $(awk '$1 == "controlplane" { print $2 }' <<<"$output"); do
		[ "$k" = SETUP_CONTEXTS ] || grep -q "^export ${k}=" "${ROOT}/config/options.env" || { echo "not an options.env export: ${k}"; false; }
	done
	assert_line "loaded $(wc -l < "$all")"
	# A whole key name is not a prefix: CHURN_DEPLOYMENT_COUNT does not let CHURN_DEPLOYMENT_COUNTS in.
	refute_line "prefix: whole name matched"
	assert_line "prefix: DATAPLANE_ matched"
}

# ---------------------------------------------------------------------------
# Precedence, config_preload, provenance
# ---------------------------------------------------------------------------

# after_versions <config-or-empty> <key>...: config_preload, then source versions.env.
after_versions() {
	local f="$1"
	shift
	bash -c '
		set -euo pipefail
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/config.sh"
		f="$1"; shift
		if [[ -n "$f" ]]; then config_preload controlplane --config "$f" 2>/dev/null; else config_preload controlplane; fi
		source "$ROOT/config/versions.env"
		for k in "$@"; do printf "%s=%s\n" "$k" "${!k-<unset>}"; done' _ "$f" "$@"
}

@test "precedence: --config beats the environment, an empty value is the built-in default, and options.env derives its dependent defaults from config values (PL37)" {
	local f
	f="$(cfg p.env 'CONTROLPLANE_SERVICE_COUNT=5')"
	CONTROLPLANE_SERVICE_COUNT=7 run after_versions "$f" CONTROLPLANE_SERVICE_COUNT RUN_CONFIG
	assert_output "$(printf '%s\n' CONTROLPLANE_SERVICE_COUNT=5 RUN_CONFIG=p.env)"
	# Without --config the environment stays.
	CONTROLPLANE_SERVICE_COUNT=7 run after_versions "" CONTROLPLANE_SERVICE_COUNT RUN_CONFIG RUN_CONFIG_SHA256
	assert_output "$(printf '%s\n' CONTROLPLANE_SERVICE_COUNT=7 RUN_CONFIG=none RUN_CONFIG_SHA256=none)"
	f="$(cfg e.env 'CONTROLPLANE_CLEANUP_GRACE_SEC=' 'CONTROLPLANE_RESULTS_DIR=')"
	CONTROLPLANE_CLEANUP_GRACE_SEC=9 CONTROLPLANE_RESULTS_DIR=/elsewhere \
		run after_versions "$f" CONTROLPLANE_CLEANUP_GRACE_SEC CONTROLPLANE_RESULTS_DIR
	assert_output "$(printf '%s\n' CONTROLPLANE_CLEANUP_GRACE_SEC=5 CONTROLPLANE_RESULTS_DIR=tests/controlplane/results)"
	f="$(cfg d.env 'CONTROLPLANE_NS_DELETE_TIMEOUT_SEC=600' 'METRICS_SCRAPE_TIMEOUT=77')"
	run env -u CONTROLPLANE_SETUP_NS_WAIT_SEC -u FANOUT_METRICS_TIMEOUT \
		bash -c "$(declare -f after_versions); after_versions \"\$@\"" _ "$f" \
		CONTROLPLANE_SETUP_NS_WAIT_SEC FANOUT_METRICS_TIMEOUT
	assert_output "$(printf '%s\n' CONTROLPLANE_SETUP_NS_WAIT_SEC=600 FANOUT_METRICS_TIMEOUT=77)"
	# An explicitly set dependent value still wins over the derived default.
	CONTROLPLANE_SETUP_NS_WAIT_SEC=50 run after_versions "$f" CONTROLPLANE_SETUP_NS_WAIT_SEC
	assert_output CONTROLPLANE_SETUP_NS_WAIT_SEC=50
}

@test "config_preload: --config needs exactly one file argument" {
	run config_preload controlplane --dry-run --config
	assert_failure 1
	assert_output --partial "--config requires a value"
	run config_preload controlplane --config --dry-run
	assert_failure 1
	assert_output --partial "--config requires a file path (got '--dry-run')"
	run config_preload controlplane --config "$GOOD" --config "$GOOD"
	assert_failure 1
	assert_output --partial "--config given more than once"
	# --config-dump-samples is another flag, not --config.
	run config_preload controlplane --config-dump-samples 2
	assert_success
}

@test "provenance: RUN_CONFIG is repo-relative inside the repo, else the basename (never a home path), with its sha256; a step keeps its sweep's; config_repo_path resolves from the repo root" {
	local sum abs arg f
	sum="$(sha256sum "$SMOKE" | cut -d' ' -f1)"
	abs="$(cd "$(dirname "$SMOKE")" && pwd -P)/smoke.env"
	for arg in "$SMOKE" "tests/controlplane/configs/smoke.env"; do
		run bash -c 'cd "$ROOT"; source tests/lib/common.sh; source tests/lib/config.sh
			config_preload controlplane --config "$1" 2>/dev/null
			echo "$RUN_CONFIG $RUN_CONFIG_SHA256 $RUN_CONFIG_PATH"' _ "$arg"
		assert_output "tests/controlplane/configs/smoke.env ${sum} ${abs}"
	done
	# From another directory, by a relative path.
	run bash -c 'cd "$ROOT/tests/controlplane"; source ../lib/common.sh; source ../lib/config.sh
		config_preload controlplane --config configs/smoke.env 2>/dev/null; echo "$RUN_CONFIG"'
	assert_output "tests/controlplane/configs/smoke.env"
	f="$(cfg 'my lab.local.env' 'CONTROLPLANE_SETTLE_SEC=5')"
	run bash -c 'source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/config.sh"
		config_preload controlplane --config "$1" 2>/dev/null; echo "$RUN_CONFIG"' _ "$f"
	assert_output "my_lab.local.env"
	[[ "$output" != *"$HOME"* ]]
	# config_preamble_lines: the two lines, none without --config, a sweep's when a step inherits them.
	RUN_CONFIG=x.env RUN_CONFIG_SHA256=abc run config_preamble_lines
	assert_output "$(printf '%s\n' '# RUN_CONFIG=x.env' '# RUN_CONFIG_SHA256=abc')"
	run bash -c 'unset RUN_CONFIG RUN_CONFIG_SHA256; source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/config.sh"
		config_preload controlplane --dry-run; config_preamble_lines'
	assert_output "$(printf '%s\n' '# RUN_CONFIG=none' '# RUN_CONFIG_SHA256=none')"
	RUN_CONFIG=smoke.env RUN_CONFIG_SHA256=abc run bash -c 'source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/config.sh"
		config_preload controlplane; config_preamble_lines'
	assert_output "$(printf '%s\n' '# RUN_CONFIG=smoke.env' '# RUN_CONFIG_SHA256=abc')"
	run config_repo_path /abs/dir
	assert_output /abs/dir
	run config_repo_path tests/controlplane/results
	assert_output "${ROOT}/tests/controlplane/results"
}

# ---------------------------------------------------------------------------
# Controlplane scripts (PL33: through the real entrypoints)
# ---------------------------------------------------------------------------

@test "003 --dry-run --config: config values, the matrix and the Run config line; env loses, flags win" {
	cd "$ROOT"
	KUBECONFIG="$EK" run --separate-stderr bash tests/controlplane/003-run-sweep.sh --dry-run \
		--config tests/controlplane/configs/smoke.env --contexts ci-a,ci-b
	assert_success
	[[ "$stderr" == *"Settle time:       20s"* ]]
	[[ "$stderr" == *"Planned matrix:    4 = 2×1×1×1×2×1 (mesh × svc × rep × ns × scope × traffic)"* ]]
	[[ "$stderr" == *"Run config:        tests/controlplane/configs/smoke.env (sha256 "* ]]
	[[ "$stderr" == *"Output:            ${ROOT}/tests/controlplane/results/smoke/sweep-"* ]]
	[[ "$stderr" == *"scope=namespace"* ]]
	CONTROLPLANE_SETTLE_SEC=99 KUBECONFIG="$EK" run --separate-stderr bash tests/controlplane/003-run-sweep.sh \
		--dry-run --config tests/controlplane/configs/smoke.env --contexts ci-a,ci-b
	[[ "$stderr" == *"Settle time:       20s"* ]]
	[[ "$stderr" == *"(overrides env '99')"* ]]
	KUBECONFIG="$EK" run --separate-stderr bash tests/controlplane/003-run-sweep.sh --dry-run \
		--config tests/controlplane/configs/smoke.env --contexts ci-a,ci-b --settle 7 --mesh-sizes 1
	[[ "$stderr" == *"Settle time:       7s"* ]]
	[[ "$stderr" == *"Planned matrix:    2 = 1×1×1×1×2×1"* ]]
}

@test "003: a repeated axis value is refused before any step (one cell would run twice under one key)" {
	KUBECONFIG="$EK" run bash "$CP/003-run-sweep.sh" --dry-run --contexts ci-a --service-counts 5,5
	assert_failure 1
	assert_output --partial "--service-counts repeats a value (5,5)"
	KUBECONFIG="$EK" run bash "$CP/003-run-sweep.sh" --dry-run --contexts ci-a --traffic-configs none,vsdr,none
	assert_failure 1
	assert_output --partial "--traffic-configs repeats a value (none,vsdr,none)"
}

@test "001 --help shows the config's values as defaults; env loses to the config" {
	cd "$ROOT"
	CONTROLPLANE_SERVICE_COUNT=7 run bash tests/controlplane/001-setup-controlplane-test.sh \
		--config tests/controlplane/configs/smoke.env --help
	assert_success
	help_shows_default 5 --service-count CONTROLPLANE_SERVICE_COUNT
	help_shows_default 300 --wait-timeout CONTROLPLANE_WAIT_TIMEOUT_SEC
	CONTROLPLANE_SERVICE_COUNT=7 CONTROLPLANE_WAIT_TIMEOUT_SEC=42 run bash tests/controlplane/001-setup-controlplane-test.sh --help
	help_shows_default 7 --service-count CONTROLPLANE_SERVICE_COUNT
	help_shows_default 42 --wait-timeout CONTROLPLANE_WAIT_TIMEOUT_SEC
}

@test "002 --dry-run --config: settle and metadata tags come from the config" {
	cd "$ROOT"
	KUBECONFIG="$EK" run bash tests/controlplane/002-collect-resource-metrics.sh --dry-run \
		--config tests/controlplane/configs/smoke.env --contexts ci-a
	assert_success
	assert_output --partial "SETTLE_SEC=20"
	assert_output --partial "Services: 5  Replicas: 2"
	assert_output --partial "ConfigDumpSamples: 1"
}

@test "005 --dry-run --config: contexts from the config; --contexts wins; env-only keys refused" {
	local f
	f="$(cfg ctx.env 'SETUP_CONTEXTS=ci-x,ci-y' 'CONTROLPLANE_CLEANUP_GRACE_SEC=9')"
	KUBECONFIG="$EK" run bash "$CP/005-cleanup.sh" --dry-run --config "$f"
	assert_success
	assert_output --partial "--context=ci-x delete namespace -l"
	assert_output --partial "--context=ci-y delete namespace -l"
	assert_output --partial "--grace-period=9"
	KUBECONFIG="$EK" run bash "$CP/005-cleanup.sh" --dry-run --config "$f" --contexts ci-z
	assert_output --partial "--context=ci-z delete"
	refute_output --partial "--context=ci-x"
	f="$(cfg ns.env 'CONTROLPLANE_TEST_NAMESPACE=istio-system')"
	KUBECONFIG="$EK" run bash "$CP/005-cleanup.sh" --dry-run --config "$f"
	assert_failure 1
	assert_output --partial "not settable from --config"
	refute_output --partial "[dry-run]"
}

@test "004: results dir from --config; --results-dir wins" {
	mkdir -p "${BATS_TEST_TMPDIR}/empty" "${BATS_TEST_TMPDIR}/other"
	local f
	f="$(cfg r.env "CONTROLPLANE_RESULTS_DIR=${BATS_TEST_TMPDIR}/empty")"
	run bash "$CP/004-report-results.sh" --config "$f"
	assert_failure 1
	assert_output --partial "no TSV result files found in ${BATS_TEST_TMPDIR}/empty"
	run bash "$CP/004-report-results.sh" --config "$f" --results-dir "${BATS_TEST_TMPDIR}/other"
	assert_failure 1
	assert_output --partial "no TSV result files found in ${BATS_TEST_TMPDIR}/other"
}

# with_run_config <src> <dst> <run_id> <config> <sha>: copy a report fixture with its
# RUN_ID and RUN_CONFIG* preamble lines set.
with_run_config() {
	sed -e "s/^# RUN_ID=.*/# RUN_ID=$3/" \
		-e "s|^# CONTROLPLANE_SCHEMA=51\$|# CONTROLPLANE_SCHEMA=51\n# RUN_CONFIG=$4\n# RUN_CONFIG_SHA256=$5|" "$1" > "$2"
}

@test "004: a dir with several runs stops the report, from the --config results dir too (PL6)" {
	local d="${BATS_TEST_TMPDIR}/multi" f
	mkdir -p "$d"
	with_run_config "$REPORT_FIXTURE" "$d/controlplane-a.tsv" run-a smoke.env abc
	with_run_config "$REPORT_FIXTURE" "$d/controlplane-b.tsv" run-b smoke.env abc
	f="$(cfg multi.env "CONTROLPLANE_RESULTS_DIR=${d}")"
	run --separate-stderr bash "$CP/004-report-results.sh" --config "$f" --format json
	assert_failure 1
	[ -z "$output" ]
	[[ "$stderr" == *"error: ${d} holds 2 runs"* ]]
	[[ "$stderr" == *"run-a (its files are in ${d}, outside a sweep-* dir"* ]]
	[[ "$stderr" == *"--allow-multi-run"* ]]
}

@test "003 with --config, no cluster: the config's snapshot, RUN_CONFIG in the TSV and the report, and each of its two cells counted failed" {
	local res="${BATS_TEST_TMPDIR}/res" f d sum
	f="$(cfg sweep.env 'SETUP_CONTEXTS=ci-a,ci-b' 'CONTROLPLANE_SERVICE_COUNTS=5,6' 'CONTROLPLANE_MESH_SIZES=1' \
		'CONTROLPLANE_SETTLE_SEC=0' 'METRICS_READY_TIMEOUT=0' "CONTROLPLANE_RESULTS_DIR=${res}")"
	sum="$(sha256sum "$f" | cut -d' ' -f1)"
	# No Istio CR answers either: warn records ISTIO_VERSION=unknown and goes on.
	export ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0
	# Every step fails fast against the empty kubeconfig: a PROBE_FAILED row per cell, then
	# the report, then exit 4 (finished with failed cells).
	KUBECONFIG="$EK" run bash "$CP/003-run-sweep.sh" --config "$f"
	assert_failure 4
	assert_output --partial "2 of 2 cells failed: PROBE_FAILED x2."
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	[ -n "$d" ]
	cmp "$f" "$d"/run-config-*.env
	grep -qx '# RUN_CONFIG=sweep.env' "$d"/controlplane-*.tsv
	grep -qx "# RUN_CONFIG_SHA256=${sum}" "$d"/controlplane-*.tsv
	[ "$(awk -F'\t' '$2 == "PROBE_FAILED"' "$d"/controlplane-*.tsv | wc -l)" -eq 2 ]
	grep -qx "run_config_sha256: \"${sum}\"" "$d"/sweep-*.md
}

@test "003: a cell count that fails is a problem, never 'every cell ran', and keeps local paths out of the record" {
	local res="${BATS_TEST_TMPDIR}/res" d fakeawk="${BATS_TEST_TMPDIR}/fakeawk" realawk
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
	# The count's awk fails (as when it could not start): a problem, exit 4, never
	# "All 1 cells ran", and the record says TOTAL=unknown and FAILED=unknown.
	realawk="$(command -v awk)"
	mkdir -p "$fakeawk"
	printf '#!/bin/sh\nfor a; do last="$a"; done\ncase "$*" in *"print \\"TOTAL\\\\t\\" ncell"*) echo "awk: simulated: argument list too long reading $last" >&2; exit 2 ;; esac\nexec %s "$@"\n' "$realawk" > "${fakeawk}/awk"
	chmod +x "${fakeawk}/awk"
	CONTROLPLANE_RESULTS_DIR="$res" PATH="${fakeawk}:${PATH}" KUBECONFIG="$EK" run bash "$CP/003-run-sweep.sh" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	assert_output --regexp "could not count the sweep's cells: awk: simulated: argument list too long reading <sweep dir>/controlplane-[^ ]+\.tsv; the rows are intact, but the cells without a row \(NOT_RUN\) are then not counted"
	refute_output --partial "cells ran"
	refute_output --partial "count its cells"
	grep -q "^PROBLEM=could not count the sweep's cells" "$d/sweep-outcome.txt"
	grep -qx 'TOTAL=unknown' "$d/sweep-outcome.txt"
	grep -qx 'FAILED=unknown' "$d/sweep-outcome.txt"
	# The sweep dir (a local path) is on stderr only: never in the record or the markdown summary.
	assert_output --partial "The sweep dir: "
	! grep -qF "$BATS_TEST_TMPDIR" "$d/sweep-outcome.txt" || false
	! grep -qE '(^|[ :=(])/[A-Za-z]' "$d/sweep-outcome.txt" || false
	! grep -h "could not count" "$d"/*.md | grep -qF "$BATS_TEST_TMPDIR" || false
}
