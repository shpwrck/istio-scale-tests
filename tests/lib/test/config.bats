#!/usr/bin/env bats
# tests/lib/config.sh (`--config FILE` run configs) and its use by tests/controlplane/001-005.
# Parser and allowlist unit tests first, then tests through the real scripts (PL33). No
# cluster: every script runs with KUBECONFIG pointing at an empty file. The other suites'
# scripts are tested in config-suites.bats; the preload-order and vocabulary checks here
# cover every suite.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/config.sh"

GOOD="${ROOT}/tests/lib/test/fixtures/config/good.env"
SMOKE="${ROOT}/tests/controlplane/configs/smoke.env"
CP="${ROOT}/tests/controlplane"
# Every suite with a key map, and its script directory (same name).
SUITES=(controlplane dataplane churn churn-dataplane propagation gateway-api)
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

# reject <line> <reason> <file-line>...: load_config fails, naming <file>:<line>: and the reason.
reject() {
	local line="$1" reason="$2" f
	shift 2
	f="$(cfg bad.env "$@")"
	run load_config "$f" controlplane
	assert_failure 1
	assert_output --partial "${f}:${line}: ${reason}"
	assert_output --partial "nothing was applied"
	refute_output --partial "[config]"
}

# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

@test "load_config: good.env gives the exact value of every accepted form" {
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
}

@test "load_config: a file that parses means the same when sourced (good.env, smoke.env)" {
	local f keys
	for f in "$GOOD" "$SMOKE"; do
		mapfile -t keys < <(file_keys "$f")
		[ "${#keys[@]}" -gt 0 ]
		[ "$(loaded "$f" "${keys[@]}")" = "$(sourced "$f" "${keys[@]}")" ]
	done
}

@test "every suite's worked example loads and means the same when sourced" {
	local s f keys
	for s in "${SUITES[@]}"; do
		f="${ROOT}/tests/${s}/configs/smoke.env"
		[ -f "$f" ] || { echo "missing $f"; false; }
		mapfile -t keys < <(file_keys "$f")
		[ "${#keys[@]}" -gt 0 ]
		[ "$(LOAD_SUITE="$s" loaded "$f" "${keys[@]}")" = "$(sourced "$f" "${keys[@]}")" ] \
			|| { echo "$s: loaded != sourced"; false; }
		# No real context names in a committed example.
		! grep -qE '^[[:space:]]*(export[[:space:]]+)?SETUP_CONTEXTS=' "$f" || false
	done
}

@test "load_config: CRLF line endings and a missing final newline give the same values" {
	local crlf="${BATS_TEST_TMPDIR}/crlf.env"
	awk '{ printf "%s%s", (NR > 1 ? "\r\n" : ""), $0 }' "$GOOD" > "$crlf"
	[ "$(tail -c 1 "$crlf" | od -An -c | tr -d ' ')" != '\n' ]
	grep -q $'\r' "$crlf"
	[ "$(loaded "$crlf" "${GOOD_KEYS[@]}")" = "$(loaded "$GOOD" "${GOOD_KEYS[@]}")" ]
}

@test "load_config: command substitution is rejected and never runs" {
	reject 1 '$ and ` are not allowed outside single quotes' 'CONTROLPLANE_SETTLE_SEC=$(touch '"${BATS_TEST_TMPDIR}"'/pwned)'
	[ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
	reject 1 '$ and ` are not allowed outside single quotes' 'CONTROLPLANE_SETTLE_SEC=`touch '"${BATS_TEST_TMPDIR}"'/pwned`'
	[ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
	reject 1 '$ and ` are not allowed outside single quotes' 'CONTROLPLANE_SETTLE_SEC=$HOME'
	reject 1 '$ and ` are not allowed outside single quotes' 'CONTROLPLANE_SETTLE_SEC="${HOME}"'
}

@test "load_config: syntax errors name the line and the reason" {
	reject 1 'bad value' 'CONTROLPLANE_SETTLE_SEC=1;touch x'
	reject 1 "no spaces around '='" 'CONTROLPLANE_SETTLE_SEC = 1'
	reject 1 "no spaces around '='" 'CONTROLPLANE_SETTLE_SEC= 1'
	reject 1 'bad value' 'CONTROLPLANE_SETTLE_SEC=1 2'
	reject 1 'bad value' "CONTROLPLANE_SETTLE_SEC='1"
	reject 1 'bad value' 'CONTROLPLANE_SETTLE_SEC="a\b"'
	reject 1 'keys are upper case' 'controlplane_settle_sec=1'
	reject 1 'not a KEY=value line' 'just words'
	reject 3 'duplicate key CONTROLPLANE_SETTLE_SEC (also on line 1)' \
		'CONTROLPLANE_SETTLE_SEC=1' '# comment' 'CONTROLPLANE_SETTLE_SEC=2'
}

@test "load_config: keys outside the controlplane vocabulary are rejected" {
	reject 1 'unknown key CONTROLPLANE_SERVICE_COUTN for the controlplane suite' 'CONTROLPLANE_SERVICE_COUTN=5'
	reject 1 'unknown key DATAPLANE_QPS_LEVELS' 'DATAPLANE_QPS_LEVELS=10'
	reject 1 'unknown key METRICS_API_STATUS' 'METRICS_API_STATUS=available'
	reject 1 'unknown key PATH' 'PATH=/tmp'
	reject 1 'unknown key LD_PRELOAD' 'LD_PRELOAD=/tmp/x.so'
	reject 1 'ISTIO_VERSION is a version pin' 'ISTIO_VERSION=v1.0.0'
	reject 1 'CONTROLPLANE_TEST_NAMESPACE is not settable from --config' 'CONTROLPLANE_TEST_NAMESPACE=istio-system'
	reject 1 'CONTROLPLANE_MAX_MATRIX is not settable from --config' 'CONTROLPLANE_MAX_MATRIX=9999'
	# Every suite reads it; a file never turns the Istio version check off.
	reject 1 'ISTIO_VERSION_CHECK is not settable from --config (env only: running on a mesh whose Istio version is not the pin' 'ISTIO_VERSION_CHECK=warn'
	# The other shared keys every sweep or version check reads say why too.
	reject 1 'ISTIO_VERSION_READY_WAIT_SEC is not settable from --config (env only: the version check' 'ISTIO_VERSION_READY_WAIT_SEC=5'
	reject 1 'SWEEP_STOP_GRACE_SEC is not settable from --config (env only: a setting of every sweep' 'SWEEP_STOP_GRACE_SEC=1'
}

@test "load_config: one bad line rejects the whole file; nothing is exported" {
	local f
	f="$(cfg late.env 'CONTROLPLANE_SERVICE_COUNT=5' 'CONTROLPLANE_SETTLE_SEC=9' 'CONTROLPLANE_SETTLE_SEX=1')"
	# The EXIT trap shows the variables when die() exits.
	run env -i PATH="$PATH" ROOT="$ROOT" bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/config.sh"
		trap '\''echo "svc=${CONTROLPLANE_SERVICE_COUNT-unset} settle=${CONTROLPLANE_SETTLE_SEC-unset}"'\'' EXIT
		load_config "$1" controlplane' _ "$f" </dev/null
	assert_failure 1
	assert_output --partial "late.env:3: unknown key CONTROLPLANE_SETTLE_SEX"
	assert_output --partial "svc=unset settle=unset"
	refute_output --partial "[config]"
}

@test "load_config: a missing file and an unmapped suite die" {
	run load_config "${BATS_TEST_TMPDIR}/nope.env" controlplane
	assert_failure 1
	assert_output --partial "nope.env: not a readable file"
	run load_config "$GOOD" tuning
	assert_failure 1
	assert_output --partial "the 'tuning' suite has no config key map yet"
}

@test "load_config: logs each key, and the env value it overrides" {
	local f
	f="$(cfg log.env 'CONTROLPLANE_SERVICE_COUNT=5' 'CONTROLPLANE_SETTLE_SEC=20')"
	CONTROLPLANE_SERVICE_COUNT=7 run --separate-stderr load_config "$f" controlplane
	assert_success
	[[ "$stderr" == *"[config] log.env sha256="*": CONTROLPLANE_SERVICE_COUNT=5 (overrides env '7')"* ]]
	[[ "$stderr" == *": CONTROLPLANE_SETTLE_SEC=20"* ]]
	[[ "$stderr" != *"CONTROLPLANE_SETTLE_SEC=20 (overrides"* ]]
}

# ---------------------------------------------------------------------------
# Allowlist
# ---------------------------------------------------------------------------

@test "config_allowed_keys: options.env exports with the suite prefixes, minus env-only keys" {
	run config_allowed_keys controlplane
	assert_success
	for k in SETUP_CONTEXTS CONTROLPLANE_SERVICE_COUNT CONTROLPLANE_SETTLE_SEC CONTROLPLANE_RESULTS_DIR \
		CONTROLPLANE_WAIT_TIMEOUT_SEC CONTROLPLANE_MESH_SIZES CONTROLPLANE_TRAFFIC_CONFIGS \
		CONTROLPLANE_VSDR_EVERY CONTROLPLANE_VSDR_SUBSETS CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT \
		CONTROLPLANE_NS_DELETE_TIMEOUT_SEC SCALE_SIZING_MODE METRICS_SCRAPE_TIMEOUT FANOUT_MAX_SKEW_MS \
		CAP_TOP_TIMEOUT; do
		grep -qx "$k" <<<"$output" || { echo "missing: $k"; false; }
	done
	for k in CONTROLPLANE_TEST_NAMESPACE CONTROLPLANE_MAX_MATRIX ISTIO_VERSION BUSYBOX_VERSION \
		ISTIO_VERSION_CHECK DATAPLANE_QPS_LEVELS METRICS_API_STATUS PATH; do
		! grep -qx "$k" <<<"$output" || { echo "unexpected: $k"; false; }
	done
	# Every listed key is an options.env export (or SETUP_CONTEXTS), so a key added
	# there later is accepted with no change here.
	for k in $output; do
		[ "$k" = SETUP_CONTEXTS ] || grep -q "^export ${k}=" "${ROOT}/config/options.env"
	done
}

@test "config_allowed_keys: a file setting every allowed key loads" {
	local f="${BATS_TEST_TMPDIR}/all.env"
	config_allowed_keys controlplane | sed 's/$/=1/' > "$f"
	run load_config "$f" controlplane
	assert_success
	[ "$(grep -c '^\[config\]' <<<"$output")" -eq "$(wc -l < "$f")" ]
}

@test "config_allowed_keys: each suite's list, its shared keys, and nothing from another suite" {
	local s k
	# suite | keys it must allow | keys it must not allow
	local -a cases=(
		"dataplane|DATAPLANE_QPS_LEVELS DATAPLANE_MESH_SIZES DATAPLANE_RESULTS_DIR DATAPLANE_WAIT_TIMEOUT_SEC DATAPLANE_NS_DELETE_TIMEOUT_SEC REACH_REQUESTS REACH_ON_UNREACHABLE FANOUT_MAX_SKEW_MS METRICS_SCRAPE_TIMEOUT SETUP_CONTEXTS|DATAPLANE_TEST_NAMESPACE DATAPLANE_MAX_MATRIX METRICS_READY_TIMEOUT CONTROLPLANE_SERVICE_COUNT COEXEC_QPS CAP_TOP_TIMEOUT SCALE_SIZING_MODE"
		"churn|CHURN_DEPLOYMENT_COUNT CHURN_INTENSITIES CHURN_MESH_SIZES CHURN_RESULTS_DIR CHURN_WAIT_TIMEOUT_SEC FANOUT_PF_BASE METRICS_SCRAPE_TIMEOUT|CHURN_TEST_NAMESPACE REACH_REQUESTS COEXEC_QPS DATAPLANE_QPS_LEVELS"
		"churn-dataplane|COEXEC_QPS COEXEC_MESH_SIZES COEXEC_RESULTS_DIR COEXEC_WAIT_TIMEOUT_SEC COEXEC_ISTIOD_REPLICAS REACH_REQUESTS CHURN_DEPLOYMENT_COUNT CHURN_BASE_REPLICAS CHURN_SCALE_TO_REPLICAS FANOUT_MAX_SKEW_MS METRICS_SCRAPE_TIMEOUT|COEXEC_TEST_NAMESPACE CHURN_TEST_NAMESPACE CHURN_ITERATIONS CHURN_INTENSITIES CHURN_SETTLE_SEC DATAPLANE_QPS_LEVELS"
		"propagation|PROPAGATION_ITERATIONS PROPAGATION_MESH_SIZES PROPAGATION_RESULTS_DIR PROPAGATION_WAIT_TIMEOUT_SEC PROPAGATION_SNAPSHOT_PF_BASE FANOUT_CTX_STRIDE METRICS_SCRAPE_TIMEOUT|PROPAGATION_TEST_NAMESPACE PROPAGATION_MAX_MATRIX REACH_REQUESTS METRICS_READY_INTERVAL"
		"gateway-api|GWAPI_WORKLOAD_CONTEXT GWAPI_HUB_CONTEXT GWAPI_INGRESS GWAPI_REQUESTS GWAPI_TIMEOUT_SEC GWAPI_DETAIL_TIMEOUT_SEC GWAPI_WAIT_TIMEOUT_SEC GWAPI_GATE_PASSES GWAPI_SETTLE_SEC GWAPI_REPROBE_DELAY_SEC GWAPI_NAMESPACE GWAPI_SHARED_NAMESPACE GWAPI_RESULTS_DIR SETUP_CONTEXTS|REACH_REQUESTS FANOUT_PF_BASE METRICS_SCRAPE_TIMEOUT DATAPLANE_QPS_LEVELS PROPAGATION_TEST_NAMESPACE"
	)
	local c allowed yes no
	for c in "${cases[@]}"; do
		IFS='|' read -r s yes no <<<"$c"
		allowed="$(config_allowed_keys "$s")"
		for k in $yes; do grep -qx "$k" <<<"$allowed" || { echo "$s: missing $k"; false; }; done
		for k in $no; do ! grep -qx "$k" <<<"$allowed" || { echo "$s: unexpected $k"; false; }; done
	done
	# A whole key name is not a prefix: CHURN_DEPLOYMENT_COUNT does not let CHURN_DEPLOYMENT_COUNTS in.
	run _config_key_matches CHURN_DEPLOYMENT_COUNTS CHURN_DEPLOYMENT_COUNT
	assert_failure
	run _config_key_matches DATAPLANE_QPS_LEVELS DATAPLANE_
	assert_success
}

@test "config_allowed_keys: for every suite, a file setting every allowed key loads" {
	local s f
	for s in "${SUITES[@]}"; do
		f="${BATS_TEST_TMPDIR}/all-${s}.env"
		config_allowed_keys "$s" | sed 's/$/=1/' > "$f"
		run load_config "$f" "$s"
		assert_success
		[ "$(grep -c '^\[config\]' <<<"$output")" -eq "$(wc -l < "$f")" ]
	done
}

@test "load_config: a key of another suite names the suite's list" {
	local f
	f="$(cfg dp.env 'COEXEC_QPS=5')"
	run load_config "$f" dataplane
	assert_failure 1
	assert_output --partial "unknown key COEXEC_QPS for the dataplane suite (allowed: SETUP_CONTEXTS and the config/options.env keys DATAPLANE_*, REACH_*, FANOUT_*, METRICS_SCRAPE_TIMEOUT)"
	f="$(cfg cd.env 'CHURN_TEST_NAMESPACE=istio-system' 'COEXEC_TEST_NAMESPACE=istio-system')"
	run load_config "$f" churn-dataplane
	assert_failure 1
	assert_output --partial "cd.env:1: unknown key CHURN_TEST_NAMESPACE for the churn-dataplane suite"
	assert_output --partial "cd.env:2: COEXEC_TEST_NAMESPACE is not settable from --config"
}

# reads_ok <suite> <script>: every config/options.env key the script reads with ${KEY is
# in the suite's vocabulary, or environment only. Script-internal names are skipped.
reads_ok() {
	local s="$1" f="$2" allowed k
	allowed="$(config_allowed_keys "$s")"
	for k in $(grep -ohE '\$\{[A-Z][A-Z0-9_]+' "$f" | sed 's/^\${//' | sort -u); do
		grep -q "^export ${k}=" "${ROOT}/config/options.env" || continue
		grep -qE "^[[:space:]]*${k}=" "$f" && continue
		[[ -n "$(_config_env_only_reason "$k")" ]] && continue
		grep -qx "$k" <<<"$allowed" || { echo "$(basename "$f") ($s) reads $k, which its --config cannot set"; return 1; }
	done
}

@test "every options.env key a suite's scripts read is in that suite's --config vocabulary" {
	local s f n=0
	for s in "${SUITES[@]}"; do
		for f in "${ROOT}/tests/${s}"/0*.sh; do
			reads_ok "$s" "$f"
			n=$((n + 1))
		done
	done
	[ "$n" -eq 28 ]
	# The check fires on a script that reads a key outside its list.
	f="${BATS_TEST_TMPDIR}/005-reads.sh"
	printf '%s\n' '#!/usr/bin/env bash' 'echo "${COEXEC_QPS:-200}"' > "$f"
	run reads_ok dataplane "$f"
	assert_failure
	assert_output --partial "reads COEXEC_QPS, which its --config cannot set"
}

# ---------------------------------------------------------------------------
# Precedence and options.env defaults
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

@test "precedence: --config beats the environment; without --config the environment stays" {
	local f
	f="$(cfg p.env 'CONTROLPLANE_SERVICE_COUNT=5')"
	CONTROLPLANE_SERVICE_COUNT=7 run after_versions "$f" CONTROLPLANE_SERVICE_COUNT RUN_CONFIG
	assert_output "$(printf '%s\n' CONTROLPLANE_SERVICE_COUNT=5 RUN_CONFIG=p.env)"
	CONTROLPLANE_SERVICE_COUNT=7 run after_versions "" CONTROLPLANE_SERVICE_COUNT RUN_CONFIG RUN_CONFIG_SHA256
	assert_output "$(printf '%s\n' CONTROLPLANE_SERVICE_COUNT=7 RUN_CONFIG=none RUN_CONFIG_SHA256=none)"
}

@test "precedence: options.env derives its dependent defaults from config values (PL37)" {
	local f
	f="$(cfg d.env 'CONTROLPLANE_NS_DELETE_TIMEOUT_SEC=600' 'METRICS_SCRAPE_TIMEOUT=77')"
	run env -u CONTROLPLANE_SETUP_NS_WAIT_SEC -u FANOUT_METRICS_TIMEOUT \
		bash -c "$(declare -f after_versions); after_versions \"\$@\"" _ "$f" \
		CONTROLPLANE_SETUP_NS_WAIT_SEC FANOUT_METRICS_TIMEOUT
	assert_output "$(printf '%s\n' CONTROLPLANE_SETUP_NS_WAIT_SEC=600 FANOUT_METRICS_TIMEOUT=77)"
	# An explicitly set dependent value still wins over the derived default.
	CONTROLPLANE_SETUP_NS_WAIT_SEC=50 run after_versions "$f" CONTROLPLANE_SETUP_NS_WAIT_SEC
	assert_output CONTROLPLANE_SETUP_NS_WAIT_SEC=50
}

@test "precedence: an empty value means the built-in default, whatever the environment says" {
	local f
	f="$(cfg e.env 'CONTROLPLANE_CLEANUP_GRACE_SEC=' 'CONTROLPLANE_RESULTS_DIR=')"
	CONTROLPLANE_CLEANUP_GRACE_SEC=9 CONTROLPLANE_RESULTS_DIR=/elsewhere \
		run after_versions "$f" CONTROLPLANE_CLEANUP_GRACE_SEC CONTROLPLANE_RESULTS_DIR
	assert_output "$(printf '%s\n' CONTROLPLANE_CLEANUP_GRACE_SEC=5 CONTROLPLANE_RESULTS_DIR=tests/controlplane/results)"
}

# ---------------------------------------------------------------------------
# config_preload, provenance
# ---------------------------------------------------------------------------

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

@test "provenance: RUN_CONFIG is repo-relative inside the repo, else the basename; sha256 matches" {
	local sum abs
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
	local f
	f="$(cfg 'my lab.local.env' 'CONTROLPLANE_SETTLE_SEC=5')"
	run bash -c 'source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/config.sh"
		config_preload controlplane --config "$1" 2>/dev/null; echo "$RUN_CONFIG"' _ "$f"
	assert_output "my_lab.local.env"
	[[ "$output" != *"$HOME"* ]]
}

@test "provenance: config_preamble_lines prints two lines; without --config they are none or inherited" {
	RUN_CONFIG=x.env RUN_CONFIG_SHA256=abc run config_preamble_lines
	assert_output "$(printf '%s\n' '# RUN_CONFIG=x.env' '# RUN_CONFIG_SHA256=abc')"
	run bash -c 'unset RUN_CONFIG RUN_CONFIG_SHA256; source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/config.sh"
		config_preload controlplane --dry-run; config_preamble_lines'
	assert_output "$(printf '%s\n' '# RUN_CONFIG=none' '# RUN_CONFIG_SHA256=none')"
	# A step run by a config-driven sweep keeps the sweep's provenance.
	RUN_CONFIG=smoke.env RUN_CONFIG_SHA256=abc run bash -c 'source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/config.sh"
		config_preload controlplane; config_preamble_lines'
	assert_output "$(printf '%s\n' '# RUN_CONFIG=smoke.env' '# RUN_CONFIG_SHA256=abc')"
}

@test "config_repo_path: absolute paths stay, relative ones resolve from the repo root" {
	run config_repo_path /abs/dir
	assert_output /abs/dir
	run config_repo_path tests/controlplane/results
	assert_output "${ROOT}/tests/controlplane/results"
}

# ---------------------------------------------------------------------------
# Controlplane scripts (PL33: through the real entrypoints)
# ---------------------------------------------------------------------------

# preload_order_ok <script> [suite]: config_preload <suite> "$@" runs before the first
# versions.env/options.env source, the first other tests/lib source after config.sh (a lib
# such as fanout.sh reads its defaults when sourced) and the first read of a key the suite
# can set; the parser has a --config) arm; the usage lists --config FILE.
preload_order_ok() {
	local f="$1" s="${2:-controlplane}" pre src lib rd p re=""
	for p in $(config_suite_prefixes "$s"); do re="${re:+${re}|}${p}"; done
	pre="$(grep -n "^config_preload ${s} \"\\\$@\"" "$f" | head -1 | cut -d: -f1)"
	src="$(grep -nE 'source .*config/(versions|options)\.env' "$f" | head -1 | cut -d: -f1)"
	lib="$(grep -nE 'source .*tests/lib/' "$f" | grep -vE 'tests/lib/(common|config)\.sh' | head -1 | cut -d: -f1)"
	rd="$(grep -nE "\\\$\{(${re})" "$f" | head -1 | cut -d: -f1)"
	[[ -n "$pre" && -n "$src" ]] || { echo "$f: missing preload ($pre) or versions/options.env source ($src)"; return 1; }
	((pre < src)) || { echo "$f: config_preload (line $pre) after versions/options.env (line $src)"; return 1; }
	[[ -z "$lib" ]] || ((pre < lib)) || { echo "$f: config_preload (line $pre) after a tests/lib source (line $lib)"; return 1; }
	[[ -z "$rd" ]] || ((pre < rd)) || { echo "$f: config_preload (line $pre) after a ${s} key read (line $rd)"; return 1; }
	grep -qE '^[[:space:]]+--config\)' "$f" || { echo "$f: no --config) parser arm"; return 1; }
	grep -q -- '--config FILE' "$f" || { echo "$f: usage lacks --config FILE"; return 1; }
}

@test "every numbered script of every suite calls config_preload before any default is read" {
	local s f n=0
	for s in "${SUITES[@]}"; do
		for f in "${ROOT}/tests/${s}"/0*.sh; do
			preload_order_ok "$f" "$s"
			n=$((n + 1))
		done
	done
	# controlplane 5, dataplane 5, churn 5, churn-dataplane 6, propagation 6, gateway-api 1
	[ "$n" -eq 28 ]
	# Tuning has no key map yet: none of its scripts preloads.
	! grep -l 'config_preload' "${ROOT}"/tests/tuning/0*.sh
}

@test "the preload-order check fires on a script that preloads too late" {
	local f="${BATS_TEST_TMPDIR}/005-late.sh"
	# Move the preload below the versions.env source.
	awk '/^config_preload controlplane/ { held = $0; next }
		{ print } index($0, "config/versions.env\"") && held != "" { print held; held = "" }' \
		"$CP/005-cleanup.sh" > "$f"
	grep -q 'config_preload controlplane' "$f"
	run preload_order_ok "$f"
	assert_failure
	assert_output --partial "after versions/options.env"
	# propagation 002 sources fanout.sh before versions.env: the preload must precede it too.
	f="${BATS_TEST_TMPDIR}/002-late.sh"
	awk '/^config_preload propagation/ { held = $0; next }
		{ print } index($0, "tests/lib/fanout.sh\"") && held != "" { print held; held = "" }' \
		"${ROOT}/tests/propagation/002-run-endpoint-probe.sh" > "$f"
	grep -q 'config_preload propagation' "$f"
	run preload_order_ok "$f" propagation
	assert_failure
	assert_output --partial "after a tests/lib source"
}

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

@test "001 --help shows the config's values as defaults; env loses to the config" {
	cd "$ROOT"
	CONTROLPLANE_SERVICE_COUNT=7 run bash tests/controlplane/001-setup-controlplane-test.sh \
		--config tests/controlplane/configs/smoke.env --help
	assert_success
	assert_output --partial "--service-count N      Number of dummy services per cluster (default: 5)."
	assert_output --partial "--wait-timeout N       Seconds to wait for pods (default: 300)."
	CONTROLPLANE_SERVICE_COUNT=7 CONTROLPLANE_WAIT_TIMEOUT_SEC=42 run bash tests/controlplane/001-setup-controlplane-test.sh --help
	assert_output --partial "(default: 7)."
	assert_output --partial "--wait-timeout N       Seconds to wait for pods (default: 42)."
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

@test "004: RUN_CONFIG and RUN_CONFIG_SHA256 reach every format (PL19); older files read unknown" {
	local d="${BATS_TEST_TMPDIR}/r"
	mkdir -p "$d"
	with_run_config "$REPORT_FIXTURE" "$d/controlplane-a.tsv" run-a smoke.env abc123
	run --separate-stderr bash "$CP/004-report-results.sh" --results-dir "$d" --format json
	assert_success
	[ "$(jq -r '.metadata.run_config + " " + .metadata.run_config_sha256' <<<"$output")" = "smoke.env abc123" ]
	run --separate-stderr bash "$CP/004-report-results.sh" --results-dir "$d" --format markdown
	assert_output --partial $'run_config: "smoke.env"\nrun_config_sha256: "abc123"'
	run --separate-stderr bash "$CP/004-report-results.sh" --results-dir "$d" --format text
	assert_output --partial "run_config=smoke.env  run_config_sha256=abc123"
	run --separate-stderr bash "$CP/004-report-results.sh" --results-dir "$d" --format csv
	assert_output --partial "# run_config: run_config=smoke.env run_config_sha256=abc123"
	run --separate-stderr bash "$CP/004-report-results.sh" --results-dir "$d" --format charts
	assert_output --partial 'run_config: "smoke.env"'
	# A file from before the key existed.
	rm "$d/controlplane-a.tsv"
	cp "$REPORT_FIXTURE" "$d/controlplane-old.tsv"
	run --separate-stderr bash "$CP/004-report-results.sh" --results-dir "$d" --format json
	[ "$(jq -r '.metadata.run_config' <<<"$output")" = "unknown" ]
}

@test "004: inputs from different configs print mixed: with a warning (PL26)" {
	local d="${BATS_TEST_TMPDIR}/m"
	mkdir -p "$d"
	with_run_config "$REPORT_FIXTURE" "$d/controlplane-a.tsv" run-a a.env aaa
	with_run_config "$REPORT_FIXTURE" "$d/controlplane-b.tsv" run-b b.env bbb
	run --separate-stderr bash "$CP/004-report-results.sh" --results-dir "$d" --allow-multi-run --format json
	assert_success
	[ "$(jq -r '.metadata.run_config' <<<"$output")" = "mixed:a.env,b.env" ]
	[[ "$stderr" == *"input TSVs disagree on RUN_CONFIG (a.env,b.env)"* ]]
}

@test "004: a file without RUN_CONFIG next to a config-driven one prints mixed:...,unknown (PL26)" {
	local d="${BATS_TEST_TMPDIR}/legacy" t
	mkdir -p "$d"
	with_run_config "$REPORT_FIXTURE" "$d/controlplane-a.tsv" run-a smoke.env abc123
	# A file from before the key existed (no RUN_CONFIG* lines), e.g. an older lab run.
	sed 's/^# RUN_ID=.*/# RUN_ID=run-old/' "$REPORT_FIXTURE" > "$d/controlplane-b.tsv"
	! grep -q '^# RUN_CONFIG' "$d/controlplane-b.tsv" || false
	run --separate-stderr bash "$CP/004-report-results.sh" --results-dir "$d" --allow-multi-run --format json
	assert_success
	[ "$(jq -r '.metadata.run_config' <<<"$output")" = "mixed:smoke.env,unknown" ]
	[ "$(jq -r '.metadata.run_config_sha256' <<<"$output")" = "mixed:abc123,unknown" ]
	[[ "$stderr" == *"input TSVs disagree on RUN_CONFIG (smoke.env,unknown)"* ]]
	[[ "$stderr" == *"input TSVs disagree on RUN_CONFIG_SHA256 (abc123,unknown)"* ]]
	for t in text csv markdown charts; do
		run --separate-stderr bash "$CP/004-report-results.sh" --results-dir "$d" --allow-multi-run --format "$t"
		assert_success
		assert_output --partial "mixed:smoke.env,unknown"
		refute_output --regexp 'run_config[=:] "?smoke\.env'
	done
	# The VS/DR and proxy-check scalars keep skipping files without the key.
	[[ "$stderr" != *"disagree on PROXY_CHECK"* ]]
}

@test "004: a dir with several runs stops the report, with or without --config / --results-dir (PL6)" {
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
	[[ "$stderr" == *"Or pass --allow-multi-run"* ]]
	run --separate-stderr bash "$CP/004-report-results.sh" --config "$f" --results-dir "$d" --format json
	assert_failure 1
	[[ "$stderr" == *"holds 2 runs"* ]]
	run --separate-stderr bash "$CP/004-report-results.sh" --results-dir "$d" --format json
	assert_failure 1
	[[ "$stderr" == *"holds 2 runs"* ]]
	run --separate-stderr bash "$CP/004-report-results.sh" --results-dir "$d" --allow-multi-run --format json
	assert_success
	# At the top level, as in every suite's JSON.
	[ "$(jq -c '.pooled_runs' <<<"$output")" = '{"runs":2,"run_ids":["run-a","run-b"],"harness_sha":["fixture"],"istio_version":["1.30.5"]}' ]
}

@test "003 with --config, no cluster: snapshot, preamble and report provenance" {
	local res="${BATS_TEST_TMPDIR}/res" f d sum
	f="$(cfg sweep.env 'SETUP_CONTEXTS=ci-a,ci-b' 'CONTROLPLANE_SERVICE_COUNT=5' 'CONTROLPLANE_MESH_SIZES=1' \
		'CONTROLPLANE_SETTLE_SEC=0' 'METRICS_READY_TIMEOUT=0' "CONTROLPLANE_RESULTS_DIR=${res}")"
	sum="$(sha256sum "$f" | cut -d' ' -f1)"
	# No Istio CR answers either: warn records ISTIO_VERSION=unknown and goes on.
	export ISTIO_VERSION_CHECK=warn
	# Every step fails fast against the empty kubeconfig: one PROBE_FAILED row, then the
	# report, then exit 4 (finished with a failed cell).
	KUBECONFIG="$EK" run bash "$CP/003-run-sweep.sh" --config "$f"
	assert_failure 4
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	[ -n "$d" ]
	cmp "$f" "$d"/run-config-*.env
	grep -qx '# RUN_CONFIG=sweep.env' "$d"/controlplane-*.tsv
	grep -qx "# RUN_CONFIG_SHA256=${sum}" "$d"/controlplane-*.tsv
	awk -F'\t' '$2 == "PROBE_FAILED" { f = 1 } END { exit !f }' "$d"/controlplane-*.tsv
	grep -qx "run_config_sha256: \"${sum}\"" "$d"/sweep-*.md
}

@test "003: a count that fails is a problem, never all ran, and keeps local paths out of the record; a keys file it cannot read is that problem too" {
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
	assert_output --regexp "error: could not count the sweep's cells: awk: simulated: argument list too long reading <sweep dir>/controlplane-[^ ]+\.tsv; the rows are intact: 004-report-results\.sh counts them from the sweep dir; exit 4\."
	refute_output --partial "cells ran"
	grep -qxE "PROBLEM=could not count the sweep's cells: awk: simulated: argument list too long reading <sweep dir>/controlplane-[^ ]+\.tsv; the rows are intact: 004-report-results\.sh counts them from the sweep dir" "$d/sweep-outcome.txt"
	grep -qx 'TOTAL=unknown' "$d/sweep-outcome.txt"
	grep -qx 'FAILED=unknown' "$d/sweep-outcome.txt"
	# The sweep dir (a local path) is on stderr only: never in the record, the markdown
	# summary or the scale envelope.
	assert_output --partial "The sweep dir: "
	! grep -qF "$BATS_TEST_TMPDIR" "$d/sweep-outcome.txt" || false
	! grep -qE '(^|[ :=(])/[A-Za-z]' "$d/sweep-outcome.txt" || false
	! grep -h "could not count" "$d"/*.md | grep -qF "$BATS_TEST_TMPDIR" || false
	# A keys file the count cannot read is that problem too, not a count of the rows only.
	rm -rf "$res"
	printf '#!/bin/sh\nn=$#; i=0; for a in "$@"; do i=$((i + 1)); case "$a" in keys=*) a="keys=/nonexistent/keys" ;; esac; set -- "$@" "$a"; done; shift "$n"\nexec %s "$@"\n' "$realawk" > "${fakeawk}/awk"
	CONTROLPLANE_RESULTS_DIR="$res" PATH="${fakeawk}:${PATH}" KUBECONFIG="$EK" run bash "$CP/003-run-sweep.sh" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	assert_output --partial "error: could not count the sweep's cells: awk: cannot read the matrix cell keys file; the rows are intact"
	refute_output --partial "cells ran"
}

@test "003: repeated axis values are refused; a run counts each of its cells" {
	local res="${BATS_TEST_TMPDIR}/res"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0
	# A repeated axis value would run one cell twice under one key.
	KUBECONFIG="$EK" run bash "$CP/003-run-sweep.sh" --dry-run --contexts ci-a --service-counts 5,5
	assert_failure 1
	assert_output --partial "error: --service-counts repeats a value (5,5): each value is one set of cells; list it once"
	KUBECONFIG="$EK" run bash "$CP/003-run-sweep.sh" --dry-run --contexts ci-a --traffic-configs none,vsdr,none
	assert_failure 1
	assert_output --partial "error: --traffic-configs repeats a value (none,vsdr,none)"
	CONTROLPLANE_RESULTS_DIR="$res" KUBECONFIG="$EK" run bash "$CP/003-run-sweep.sh" --contexts ci-a --mesh-sizes 1 --service-counts 5,6
	assert_failure 4
	assert_output --partial "error: 2 of 2 cells failed: PROBE_FAILED x2."
}

@test "config_merged_preamble leaves out the keys older TSVs carry that no run writes any more, so a pooled report never shows their value as every input's" {
	local d="${BATS_TEST_TMPDIR}/old-keys"
	mkdir -p "$d"
	printf '# RUN_ID=r1\n# ISTIO_PROXY_VERSIONS=ci-a=1.30.5:30\n# ISTIO_NOTREADY_AT_START=none\n# ISTIO_READY_WAITED_SEC=0\n# ISTIO_GENERATIONS=ci-a=2/2\ntimestamp\tx\n' > "$d/old.tsv"
	printf '# RUN_ID=r2\n# ISTIO_GENERATIONS=ci-a=2/2\ntimestamp\tx\n' > "$d/new.tsv"
	run config_merged_preamble "$d/old.tsv" "$d/new.tsv"
	assert_success
	assert_output "$(printf '%s\n' RUN_ID=mixed:r1,r2 ISTIO_GENERATIONS=ci-a=2/2)"
}
