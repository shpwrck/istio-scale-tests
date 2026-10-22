#!/usr/bin/env bats
# `--config FILE` through the real scripts of dataplane, churn, churn-dataplane and
# propagation (PL33): precedence, the values reaching each step, the up-front checks, each
# sweep's failed cells counted with the config on their placeholders and its snapshot, each
# report's multi-run guard (PL6), and the shared report helpers (tests/lib/config.sh). Every
# format of every report carrying the merged values is report-formats.bats's. No cluster:
# KUBECONFIG is an empty file, and the few runs past the preflight use a stub kubectl.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/config.sh"

DP="${ROOT}/tests/dataplane"
CH="${ROOT}/tests/churn"
CD="${ROOT}/tests/churn-dataplane"
PR="${ROOT}/tests/propagation"
FX="${ROOT}/tests/lib/test/fixtures"

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
	: > "$STUB_LOG"
	# A stub kubectl: one Running istiod pod, a dataplane fortio client/server answering
	# with STUB_JSON, the Istio CR at the pin, every other call fails. Each call is
	# logged.
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" get pods "*"-l app=istiod"*) [[ -n "${STUB_ISTIOD:-}" ]] && echo istiod-0 ;;
*" exec "*) cat "$STUB_JSON" ;;
*" get deploy dataplane-server "*) printf '1/1' ;;
*" get pod -l app=dataplane-client "*) printf 'dataplane-client-0\t\tTrue' ;;
*" get pods "*) : ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
	export STUB_JSON="${FX}/fortio_ok.json"
}

# cfg <name> <line>...: write a config file into the test tmpdir and print its path.
cfg() {
	local f="${BATS_TEST_TMPDIR}/$1"
	shift
	printf '%s\n' "$@" > "$f"
	printf '%s' "$f"
}

# sum <file>: its sha256.
sum() { sha256sum "$1" | cut -d' ' -f1; }

# no_plan: the last run stopped before its plan's first step.
no_plan() { [[ "$output" != *"Dry-run complete"* && "$output" != *"[dry-run] 001"* && "$output" != *"001-setup"* ]]; }

# ---------------------------------------------------------------------------
# Shared report helpers (tests/lib/config.sh)
# ---------------------------------------------------------------------------

@test "config_report_value: one value, mixed with a warning, unknown for a file without the key" {
	local a b old
	a="$(cfg a.tsv '# RUN_CONFIG=a.env' '# RUN_CONFIG_SHA256=aaa' 'run_id')"
	b="$(cfg b.tsv '# RUN_CONFIG=b.env' '# RUN_CONFIG_SHA256=bbb' 'run_id')"
	old="$(cfg old.tsv '# RUN_ID=x' 'run_id')"
	run --separate-stderr config_report_value RUN_CONFIG "$a" "$a"
	assert_output a.env
	[ -z "$stderr" ]
	run --separate-stderr config_report_value RUN_CONFIG_SHA256 "$a" "$b"
	assert_output mixed:aaa,bbb
	[[ "$stderr" == *"input TSVs disagree on RUN_CONFIG_SHA256 (aaa,bbb)"* ]]
	run --separate-stderr config_report_value RUN_CONFIG "$a" "$old"
	assert_output mixed:a.env,unknown
	run config_report_value RUN_CONFIG "$old"
	assert_output unknown
	# RUN_CONFIG does not pick up the RUN_CONFIG_SHA256 line.
	run config_report_value RUN_CONFIG "$(cfg sha-only.tsv '# RUN_CONFIG_SHA256=ccc')"
	assert_output unknown
}

@test "config_check_multi_run: one run per sweep dir however the report reaches it, one per RUN_ID outside one; more than one dies unless --allow-multi-run, which lists every run" {
	local r="${BATS_TEST_TMPDIR}/r"
	mkdir -p "$r/sweep-1" "$r/sweep-2" "$r/store/data"
	# One sweep: its combos carry their own RUN_IDs, still one run.
	printf '# RUN_ID=c1\n# HARNESS_SHA=h1\n# ISTIO_VERSION=v1\nrun_id\nc1\n' > "$r/sweep-1/a.tsv"
	printf '# RUN_ID=c2\n# HARNESS_SHA=h1\n# ISTIO_VERSION=v1\nrun_id\nc2\n' > "$r/sweep-1/b.tsv"
	: > "$r/sweep-2/c.tsv"
	run --separate-stderr config_check_multi_run "$r" 0 "$r/sweep-1/a.tsv" "$r/sweep-1/b.tsv"
	assert_success
	[ -z "$stderr" ]
	config_check_multi_run "$r" 0 "$r/sweep-1/a.tsv" "$r/sweep-1/b.tsv"
	[ "$MULTI_RUN_N" = 1 ]
	[ "$MULTI_RUN_IDS" = sweep-1 ]
	[ -z "$(config_multi_run_note)" ]
	[ -z "$(config_multi_run_csv)" ]
	[ "$(config_multi_run_json)" = '{"runs":1,"run_ids":["sweep-1"],"harness_sha":["h1"],"istio_version":["v1"]}' ]
	# The same sweep from inside it (--results-dir .), as sweep-1/ (find's sweep-1//file),
	# through latest -> sweep-1, and a sweep-3 symlink to a directory of any name (the link's
	# own name is the key), with CDPATH set.
	cp "$r/sweep-1/a.tsv" "$r/sweep-1/b.tsv" "$r/store/data/"
	ln -s sweep-1 "$r/latest"
	ln -s "$r/store/data" "$r/sweep-3"
	export CDPATH="$r/store"
	(cd "$r/sweep-1" && config_check_multi_run . 0 ./a.tsv b.tsv && [ "$MULTI_RUN_IDS" = sweep-1 ])
	(cd "$r" && config_check_multi_run sweep-1/ 0 sweep-1//a.tsv sweep-1//b.tsv && [ "$MULTI_RUN_IDS" = sweep-1 ])
	(cd "$r" && config_check_multi_run . 0 sweep-1//a.tsv sweep-1//b.tsv && [ "$MULTI_RUN_IDS" = sweep-1 ])
	(config_check_multi_run "$r/latest" 0 "$r/latest/a.tsv" "$r/latest/b.tsv" && [ "$MULTI_RUN_IDS" = sweep-1 ])
	(cd "$r/latest" && config_check_multi_run . 0 ./a.tsv b.tsv && [ "$MULTI_RUN_IDS" = sweep-1 ])
	(config_check_multi_run "$r/sweep-3" 0 "$r/sweep-3/a.tsv" "$r/sweep-3/b.tsv" && [ "$MULTI_RUN_IDS" = sweep-3 ])
	(cd "$r/sweep-3" && config_check_multi_run . 0 ./a.tsv b.tsv && [ "$MULTI_RUN_IDS" = sweep-3 ])
	# A plain directory (no sweep-* on either side) counts its ids.
	run --separate-stderr config_check_multi_run "$r/store/data" 0 "$r/store/data/a.tsv" "$r/store/data/b.tsv"
	assert_failure 1
	[[ "$stderr" == *"holds 2 runs"* ]]
	unset CDPATH
	# Two sweeps: dies, naming each sweep dir and the command that reports it alone, its path
	# quoted.
	run --separate-stderr config_check_multi_run "$r" 0 "$r/sweep-1/a.tsv" "$r/sweep-2/c.tsv"
	assert_failure 1
	[[ "$stderr" == *"error: ${r} holds 2 runs"* ]]
	[[ "$stderr" == *"  sweep-2:"$'\n'"    "*" --results-dir '${r}/sweep-2'"* ]]
	[[ "$stderr" == *"  sweep-1:"$'\n'"    "*" --results-dir '${r}/sweep-1'"* ]]
	[[ "$stderr" == *"Or pass --allow-multi-run"* ]]
	# Opted in: a warning, and the note, csv lines and json list both runs; a file without
	# HARNESS_SHA / ISTIO_VERSION reads unknown.
	run --separate-stderr config_check_multi_run "$r" 1 "$r/sweep-1/a.tsv" "$r/sweep-2/c.tsv"
	assert_success
	[[ "$stderr" == *"--allow-multi-run: this report pools 2 runs from ${r} (sweep-1,sweep-2)"* ]]
	config_check_multi_run "$r" 1 "$r/sweep-1/a.tsv" "$r/sweep-2/c.tsv" 2>/dev/null
	[ "$(config_multi_run_note)" = "This report pools 2 runs (--allow-multi-run): sweep-1, sweep-2. HARNESS_SHA: h1, unknown. ISTIO_VERSION: v1, unknown. These differ, so the pooled rows were not all measured with the same harness or Istio version." ]
	[[ "$(config_multi_run_csv)" == "# POOLED_RUNS=2"$'\n'"# POOLED_RUN_IDS=sweep-1,sweep-2"$'\n'* ]]
	[ "$(config_multi_run_json)" = '{"runs":2,"run_ids":["sweep-1","sweep-2"],"harness_sha":["h1","unknown"],"istio_version":["v1","unknown"]}' ]
	# Two standalone probes into one dir: two RUN_IDs (preamble, else the first data row).
	printf '# RUN_ID=p1\nrun_id\tx\np1\t1\n' > "$r/latency-p1.tsv"
	printf 'run_id\tx\np2\t1\n' > "$r/churn-p2.tsv"
	run --separate-stderr config_check_multi_run "$r" 0 "$r/latency-p1.tsv" "$r/churn-p2.tsv"
	assert_failure 1
	[[ "$stderr" == *"holds 2 runs"* && "$stderr" == *"  p2 ("* && "$stderr" == *"  p1 ("* ]]
	# Files of one standalone run (same RUN_ID) are one run; propagation's SWEEP_RUN_ID wins.
	printf '# RUN_ID=p1\nrun_id\n' > "$r/latency-p1b.tsv"
	printf '# SWEEP_RUN_ID=s9\n# RUN_ID=e1\nrun_id\n' > "$r/endpoint-e1.tsv"
	printf '# SWEEP_RUN_ID=s9\n# RUN_ID=e2\nrun_id\n' > "$r/endpoint-e2.tsv"
	run --separate-stderr config_check_multi_run "$r" 0 "$r/latency-p1.tsv" "$r/latency-p1b.tsv"
	assert_success
	run --separate-stderr config_check_multi_run "$r" 0 "$r/endpoint-e1.tsv" "$r/endpoint-e2.tsv"
	assert_success
	# A file with no run id at all counts as a run of its own.
	: > "$r/empty.tsv"
	run --separate-stderr config_check_multi_run "$r" 0 "$r/latency-p1.tsv" "$r/empty.tsv"
	assert_failure 1
	[[ "$stderr" == *"  empty.tsv ("* && "$stderr" == *"  p1 ("* ]]
}

@test "config_check_multi_run: the commands it prints separate the runs, never touch a sweep dir or nest a run already alone in its dir, and the report then accepts each" {
	local r="${BATS_TEST_TMPDIR}/r2" cmd pass
	mkdir -p "$r/istiod-diag-20261016T100000Z-1" "$r/sweep-20261015T100000Z-4" "$r/run-20261014T100000Z-3"
	printf '# RUN_ID=20261016T100000Z-1\nrun_id\n' > "$r/latency-20261016T100000Z-1.tsv"
	: > "$r/latency-20261016T100000Z-1.md"
	printf '# RUN_ID=20261016T110000Z-2\nrun_id\n' > "$r/latency-20261016T110000Z-2.tsv"
	printf '# RUN_ID=c1\nrun_id\nc1\n' > "$r/sweep-20261015T100000Z-4/a.tsv"
	printf '# RUN_ID=20261014T100000Z-3\nrun_id\n' > "$r/run-20261014T100000Z-3/latency-20261014T100000Z-3.tsv"
	run --separate-stderr config_check_multi_run "$r" 0 "$r"/*.tsv "$r/sweep-20261015T100000Z-4/a.tsv" \
		"$r/run-20261014T100000Z-3/latency-20261014T100000Z-3.tsv"
	assert_failure 1
	[[ "$stderr" == *"holds 4 runs"* ]]
	# The run already alone in run-<id>/ only gets its report, never run-<id>/run-<id>/.
	[[ "$stderr" == *" --results-dir '${r}/run-20261014T100000Z-3'"* ]]
	[[ "$stderr" != *"run-20261014T100000Z-3/run-"* ]]
	# Run each printed mkdir/for/find line as the operator would paste it, twice.
	for pass in 1 2; do
		while IFS= read -r cmd; do
			bash -c "$cmd"
		done < <(sed -n 's/^    \(mkdir .*\|for f in .*\|find .*\)$/\1/p' <<<"$stderr")
	done
	[ -f "$r/run-20261016T100000Z-1/latency-20261016T100000Z-1.tsv" ]
	[ -f "$r/run-20261016T100000Z-1/latency-20261016T100000Z-1.md" ]
	[ -d "$r/run-20261016T100000Z-1/istiod-diag-20261016T100000Z-1" ]
	[ -f "$r/run-20261016T110000Z-2/latency-20261016T110000Z-2.tsv" ]
	[ -f "$r/sweep-20261015T100000Z-4/a.tsv" ]
	[ -f "$r/run-20261014T100000Z-3/latency-20261014T100000Z-3.tsv" ]
	[ -z "$(find "$r" -maxdepth 1 -type f)" ]
	run --separate-stderr config_check_multi_run "$r/run-20261016T100000Z-1" 0 "$r/run-20261016T100000Z-1"/*.tsv
	assert_success
}

@test "config_input_value and config_merged_preamble read every input, never the first or last file's (PL26); a leading v is one version; keys no run writes any more drop out" {
	local a b c va vb vc
	a="$(cfg a.tsv '# RUN_ID=r1' '# QPS=10' '# KUBE_VERSIONS=a=1.30,b=1.30' '# HOSTS=' '# ONLY_A=x' $'run_id\tx' $'r1\t1' '# LATE=1')"
	b="$(cfg b.tsv '# RUN_ID=r2' '# QPS=10' '# KUBE_VERSIONS=a=1.31' '# HOSTS=h' '# K[c]=1' 'run_id')"
	run config_input_value QPS "" "$a" "$b"
	assert_output 10
	run config_input_value RUN_ID "" "$a" "$b"
	assert_output mixed:r1,r2
	run config_input_value ONLY_A "" "$a" "$b"
	assert_output x
	run config_input_value ONLY_A unknown "$a" "$b"
	assert_output mixed:x,unknown
	run config_input_value NOPE "" "$a" "$b"
	assert_output ""
	# First-seen key order; a value with a comma joins with " | "; an empty value reads
	# (empty) in a mixed list; a key only one file has keeps its value; nothing after the
	# header line is preamble.
	run config_merged_preamble "$a" "$b"
	assert_success
	assert_output "$(printf '%s\n' 'RUN_ID=mixed:r1,r2' 'QPS=10' 'KUBE_VERSIONS=mixed:a=1.30,b=1.30 | a=1.31' 'HOSTS=mixed:(empty),h' 'ONLY_A=x' 'K[c]=1')"
	# An ISTIO_VERSION* value is one value whatever its leading v; a real difference still
	# reads mixed, each version once.
	va="$(cfg va.tsv '# ISTIO_VERSION=v1.30.5' '# ISTIO_VERSION_PIN=v1.30.5' '# ISTIO_VERSION_BY_CONTEXT=x=v1.30.5,y=v1.30.5' '# TAG=v1' 'run_id')"
	vb="$(cfg vb.tsv '# ISTIO_VERSION=1.30.5' '# ISTIO_VERSION_PIN=1.30.5' '# ISTIO_VERSION_BY_CONTEXT=x=1.30.5,y=1.30.5' '# TAG=1' 'run_id')"
	vc="$(cfg vc.tsv '# ISTIO_VERSION=mixed:1.30.5/v1.29.0' '# ISTIO_VERSION_PIN=1.30.5' '# ISTIO_VERSION_BY_CONTEXT=x=1.30.5,y=v1.29.0' '# TAG=1' 'run_id')"
	run config_input_value ISTIO_VERSION_PIN "" "$vb" "$va"
	assert_output 1.30.5
	run config_merged_preamble "$va" "$vb"
	assert_output "$(printf '%s\n' ISTIO_VERSION=v1.30.5 ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_BY_CONTEXT=x=v1.30.5,y=v1.30.5 TAG=mixed:v1,1)"
	run config_input_value ISTIO_VERSION "" "$va" "$vb" "$vc"
	assert_output mixed:v1.30.5,v1.29.0
	run config_merged_preamble "$va" "$vc"
	assert_line "ISTIO_VERSION=mixed:v1.30.5,v1.29.0"
	assert_line "ISTIO_VERSION_BY_CONTEXT=mixed:x=v1.30.5,y=v1.30.5 | x=1.30.5,y=v1.29.0"
	# Keys older TSVs carry that no run writes any more are left out, so a pooled report never
	# shows one file's value as every input's.
	c="$(cfg old.tsv '# RUN_ID=r1' '# ISTIO_PROXY_VERSIONS=ci-a=1.30.5:30' '# ISTIO_NOTREADY_AT_START=none' \
		'# ISTIO_READY_WAITED_SEC=0' '# ISTIO_GENERATIONS=ci-a=2/2' $'timestamp\tx')"
	run config_merged_preamble "$c" "$(cfg new.tsv '# RUN_ID=r2' '# ISTIO_GENERATIONS=ci-a=2/2' $'timestamp\tx')"
	assert_success
	assert_output "$(printf '%s\n' RUN_ID=mixed:r1,r2 ISTIO_GENERATIONS=ci-a=2/2)"
}

# ---------------------------------------------------------------------------
# The examples and the up-front checks, every sweep (controlplane included)
# ---------------------------------------------------------------------------

@test "every configs/smoke.env runs each ci-dry-run script of its suite with the CI args" {
	cd "$ROOT"
	local c f args n=0
	for c in tests/*/configs/smoke.env; do
		for f in "${c%/configs/smoke.env}"/0*.sh; do
			grep -q '^# ci-dry-run:' "$f" || continue
			args="$(sed -n 's/^# ci-dry-run://p' "$f" | head -1)"
			# shellcheck disable=SC2086  # the annotation's words, as verify.sh passes them
			KUBECONFIG="$EK" run bash "$f" --dry-run --config "$c" $args
			[ "$status" -eq 0 ] || { echo "$f --dry-run --config $c$args: exit $status"; echo "$output" | tail -3; false; }
			n=$((n + 1))
		done
	done
	# Six suites ship an example; each has at least one annotated script.
	[ "$(find tests -path '*/configs/smoke.env' | wc -l)" -eq 6 ]
	((n >= 15))
}

@test "every sweep refuses a bad step-only knob from --config under --dry-run, before its first step" {
	local sweep key f
	# One knob per sweep, each one its step does not check itself or uses as a window.
	while read -r sweep key; do
		f="$(cfg "bad-${key}.env" "${key}=5m")"
		KUBECONFIG="$EK" run bash "${ROOT}/tests/${sweep}" --dry-run --config "$f" --contexts ci-a
		[ "$status" -eq 1 ] || { echo "${sweep} with ${key}=5m: exit ${status}"; echo "$output" | tail -3; false; }
		[[ "$output" == *"${key} (read by "*"5m"* ]] || { echo "${sweep}: no '${key} (read by' error"; echo "$output" | tail -3; false; }
		no_plan
	done <<'LIST'
dataplane/003-run-sweep.sh DATAPLANE_WAIT_TIMEOUT_SEC
churn/003-run-sweep.sh CHURN_POLL_INTERVAL_MS
churn-dataplane/004-run-sweep.sh COEXEC_CLEANUP_GRACE_SEC
propagation/006-run-sweep.sh PROPAGATION_DRAIN_TIMEOUT_SEC
controlplane/003-run-sweep.sh CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S
LIST
}

@test "a bad probe window from a flag, --config or the environment stops the probe, or its sweep before the first step, naming flag and key, before any cluster call" {
	local a f
	# dataplane 002 on its own: each window knob from its flag, then from --config and the
	# environment.
	for a in "--duration 0:--duration (or DATAPLANE_DURATION_SEC) must be a positive integer; got '0'" \
		"--duration 08:--duration (or DATAPLANE_DURATION_SEC) must be a positive integer; got '08'" \
		"--warmup-duration x:--warmup-duration (or DATAPLANE_WARMUP_DURATION_SEC) must be a non-negative integer; got 'x'" \
		"--connections 0:--connections (or DATAPLANE_NUM_CONNECTIONS) must be a positive integer; got '0'" \
		"--settle -1:--settle (or DATAPLANE_SETTLE_SEC) must be a non-negative integer; got '-1'"; do
		# shellcheck disable=SC2086  # the flag and its value
		PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr bash "$DP/002-run-latency-probe.sh" \
			--source-context ci-x ${a%%:*}
		assert_failure 1
		[[ "$stderr" == *"${a#*:}"* ]] || { echo "${a%%:*}: ${stderr}"; false; }
	done
	f="$(cfg bad.env 'DATAPLANE_DURATION_SEC=30s')"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr bash "$DP/002-run-latency-probe.sh" --config "$f" --source-context ci-x
	assert_failure 1
	[[ "$stderr" == *"--duration (or DATAPLANE_DURATION_SEC) must be a positive integer; got '30s'"* ]]
	DATAPLANE_SETTLE_SEC=abc PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr bash "$DP/002-run-latency-probe.sh" \
		--source-context ci-x --dry-run
	assert_failure 1
	[[ "$stderr" == *"--settle (or DATAPLANE_SETTLE_SEC) must be a non-negative integer; got 'abc'"* ]]
	[ ! -s "$STUB_LOG" ]
	# churn-dataplane's probes on their own.
	KUBECONFIG="$EK" run bash "$CD/002-run-baseline-probe.sh" --dry-run --source-context ci-dummy --duration 5m
	assert_failure 1
	assert_output --partial "--duration (or COEXEC_BASELINE_DURATION_SEC) must be a positive integer; got '5m'"
	COEXEC_QPS=abc KUBECONFIG="$EK" run bash "$CD/003-run-churn-probe.sh" --dry-run --source-context ci-dummy --churn-rate 5
	assert_failure 1
	assert_output --partial "--qps (or COEXEC_QPS) must be a positive integer; got 'abc'"
	# The sweeps check them up front, from --config or the flag, the settle between combos too.
	f="$(cfg bad-qps.env 'DATAPLANE_QPS_LEVELS=10,5m')"
	KUBECONFIG="$EK" run bash "$DP/003-run-sweep.sh" --dry-run --config "$f" --contexts ci-a
	assert_failure 1
	assert_output --partial "--qps-levels (or DATAPLANE_QPS_LEVELS): '5m' is not a positive integer"
	no_plan
	KUBECONFIG="$EK" run bash "$DP/003-run-sweep.sh" --dry-run --contexts ci-a --duration 5m
	assert_failure 1
	assert_output --partial "--duration"
	no_plan
	f="$(cfg bad-ics.env 'DATAPLANE_INTER_COMBO_SETTLE_SEC=5m')"
	KUBECONFIG="$EK" run bash "$DP/003-run-sweep.sh" --dry-run --config "$f" --contexts ci-a
	assert_failure 1
	assert_output --partial "DATAPLANE_INTER_COMBO_SETTLE_SEC must be a non-negative integer; got '5m'"
	no_plan
	f="$(cfg bad-cd.env 'COEXEC_CHURN_DURATION_SEC=5m')"
	KUBECONFIG="$EK" run bash "$CD/004-run-sweep.sh" --dry-run --config "$f" --contexts ci-a
	assert_failure 1
	assert_output --partial "--churn-duration (or COEXEC_CHURN_DURATION_SEC) must be a positive integer; got '5m'"
	no_plan
	KUBECONFIG="$EK" run bash "$CD/004-run-sweep.sh" --dry-run --contexts ci-a --qps abc
	assert_failure 1
	assert_output --partial "--qps"
	no_plan
}

# ---------------------------------------------------------------------------
# dataplane
# ---------------------------------------------------------------------------

@test "dataplane --config: its values reach 003's plan and 002's command line, 001's and 005's defaults, 002's and 005's dry runs; env loses, flags win; a bad value stops a step before any cluster call" {
	local f
	f="$(cfg dp.env 'SETUP_CONTEXTS=ci-x,ci-y' 'DATAPLANE_MESH_SIZES=1,2' 'DATAPLANE_QPS_LEVELS=5,6' 'DATAPLANE_SETTLE_SEC=10' \
		'DATAPLANE_WAIT_TIMEOUT_SEC=42' 'DATAPLANE_NS_DELETE_TIMEOUT_SEC=77' 'DATAPLANE_SERVER_REPLICAS=3')"
	DATAPLANE_SETTLE_SEC=99 KUBECONFIG="$EK" run --separate-stderr bash "$DP/003-run-sweep.sh" --dry-run --config "$f"
	assert_success
	assert_output --partial "Mesh sizes: 1 2"
	assert_output --partial "QPS levels: 5,6"
	assert_output --partial "Settle: 10s"
	assert_output --partial "Run config: ${f##*/} (sha256 "
	[[ "$stderr" == *"DATAPLANE_SETTLE_SEC=10 (overrides env '99')"* ]]
	[[ "$stderr" == *"--qps-levels 5,6 "*"--settle 10 "* ]]
	KUBECONFIG="$EK" run bash "$DP/003-run-sweep.sh" --dry-run --config "$f" --settle 7 --mesh-sizes 2
	assert_output --partial "Settle: 7s"
	assert_output --partial "Mesh sizes: 2"
	run bash "$DP/001-setup-dataplane-test.sh" --config "$f" --help
	assert_success
	help_shows_default 42 --wait-timeout DATAPLANE_WAIT_TIMEOUT_SEC
	help_shows_default 3 --server-replicas DATAPLANE_SERVER_REPLICAS
	PATH="${BIN}:${PATH}" run bash "$DP/002-run-latency-probe.sh" --dry-run --config "$f" --source-context ci-x
	assert_success
	assert_output --partial "QPS levels: 5 6"
	[ ! -s "$STUB_LOG" ]
	run bash "$DP/005-cleanup.sh" --config "$f" --help
	help_shows_default 77 --deletion-timeout DATAPLANE_NS_DELETE_TIMEOUT_SEC
	KUBECONFIG="$EK" run bash "$DP/005-cleanup.sh" --dry-run --config "$f"
	assert_success
	assert_output --partial "ci-x"
	assert_output --partial "ci-y"
	# A bad value from the file stops the step before any cluster call (PL32).
	f="$(cfg bad.env 'DATAPLANE_WAIT_TIMEOUT_SEC=0')"
	run bash "$DP/001-setup-dataplane-test.sh" --config "$f" --source-context ci-x --dry-run
	assert_failure 1
	assert_output --partial "--wait-timeout (or DATAPLANE_WAIT_TIMEOUT_SEC) must be a positive integer"
}

@test "dataplane 002 with --config (stub kubectl): its TSV, the reach TSV beside it and its summary name the config and its sha256" {
	local f res="${BATS_TEST_TMPDIR}/res"
	f="$(cfg probe.env "DATAPLANE_RESULTS_DIR=${res}" 'DATAPLANE_QPS_LEVELS=1000' \
		'DATAPLANE_SETTLE_SEC=0' 'DATAPLANE_WARMUP_DURATION_SEC=0' 'REACH_RETRY_SEC=0')"
	PATH="${BIN}:${PATH}" run bash "$DP/002-run-latency-probe.sh" --config "$f" \
		--source-context ctx-a --remote-contexts ctx-b
	assert_success
	grep -qx '# RUN_CONFIG=probe.env' "$res"/latency-*.tsv
	grep -qx "# RUN_CONFIG_SHA256=$(sum "$f")" "$res"/latency-*.tsv
	grep -qx '# RUN_CONFIG=probe.env' "$res"/reach-*.tsv
	grep -qx "# RUN_CONFIG_SHA256=$(sum "$f")" "$res"/reach-*.tsv
	grep -qxF "| Run config | \`probe.env\` (sha256 \`$(sum "$f")\`) |" "$res"/latency-*.md
}

@test "dataplane 003 with --config (no cluster): each failed cell is counted (exit 4) and its placeholder names the config; the snapshot is a byte copy; 004 refuses a dir with two sweeps and pools them only with --allow-multi-run" {
	local res="${BATS_TEST_TMPDIR}/res" f d
	f="$(cfg sweep.env 'SETUP_CONTEXTS=ci-a,ci-b' 'DATAPLANE_MESH_SIZES=1,2' \
		'DATAPLANE_INTER_COMBO_SETTLE_SEC=0' "DATAPLANE_RESULTS_DIR=${res}")"
	# Every setup fails against the empty kubeconfig: SETUP_FAILED placeholders, the
	# reports, then "2 of 2 cells failed" and exit 4.
	ISTIO_VERSION_CHECK=warn KUBECONFIG="$EK" run --separate-stderr bash "$DP/003-run-sweep.sh" --config "$f"
	assert_failure 4
	[[ "$stderr" == *"error: 2 of 2 cells failed: SETUP_FAILED x2."* ]]
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	cmp "$f" "$d"/run-config-*.env
	[ "$(grep -lx '# RUN_CONFIG=sweep.env' "$d"/latency-zzfail-*.tsv | wc -l)" -eq 2 ]
	grep -qx "# RUN_CONFIG_SHA256=$(sum "$f")" "$d"/latency-zzfail-ms1-*.tsv
	grep -qx "RUN_CONFIG_SHA256: \"$(sum "$f")\"" "$d"/sweep-*.md
	# A second sweep under the same base dir (a copy under another sweep-* name): the report
	# of the config's results dir stops and names the command for each sweep.
	cp -R "$d" "${res}/sweep-20990101T000000Z-1"
	run --separate-stderr bash "$DP/004-report-results.sh" --config "$f" --format json
	assert_failure 1
	[ -z "$output" ]
	[[ "$stderr" == *"error: ${res} holds 2 runs"* ]]
	[[ "$stderr" == *"  $(basename "$d"):"$'\n'"    ${DP}/004-report-results.sh --results-dir '${d}'"* ]]
	run --separate-stderr bash "$DP/004-report-results.sh" --results-dir "$res" --allow-multi-run --format json
	assert_success
	[ "$(jq -r '.pooled_runs | "\(.runs) \(.run_ids | length)"' <<<"$output")" = "2 2" ]
}

# ---------------------------------------------------------------------------
# churn
# ---------------------------------------------------------------------------

@test "churn 003 --dry-run --config: its intensities and mesh sizes reach the plan, env loses, flags win; without a list the singular count is the one intensity; the axes are checked before any step" {
	local f
	f="$(cfg ch.env 'SETUP_CONTEXTS=ci-a,ci-b' 'CHURN_MESH_SIZES=1,2' 'CHURN_INTENSITIES=2,4' 'CHURN_ITERATIONS=2')"
	CHURN_INTENSITIES=9 CHURN_MESH_SIZES=2 KUBECONFIG="$EK" run bash "$CH/003-run-sweep.sh" --dry-run --config "$f"
	assert_success
	assert_output --partial "Mesh sizes: 1 2"
	assert_output --partial "Churn intensities: 2 4"
	assert_output --partial "--iterations 2 "
	KUBECONFIG="$EK" run bash "$CH/003-run-sweep.sh" --dry-run --config "$f" --churn-intensities 3 --mesh-sizes 1
	assert_output --partial "Churn intensities: 3"
	assert_output --partial "Mesh sizes: 1"
	# Without a list key, the singular deployment count is the one intensity (PL7).
	CHURN_DEPLOYMENT_COUNT=7 KUBECONFIG="$EK" run bash "$CH/003-run-sweep.sh" --dry-run --contexts ci-a
	assert_output --partial "Churn intensities: 7"
	refute_output --partial "Run config:"
	# The axes are checked before any step: the config replayed on one context would
	# otherwise label single-cluster rows mesh_size=2.
	KUBECONFIG="$EK" run bash "$CH/003-run-sweep.sh" --dry-run --config "$f" --contexts ci-a
	assert_failure 1
	assert_output --partial "mesh-size 2 out of range (have 1 contexts)"
	refute_output --partial "002-run-churn-probe"
	KUBECONFIG="$EK" run bash "$CH/003-run-sweep.sh" --dry-run --contexts ci-a --churn-intensities 0
	assert_failure 1
	assert_output --partial "positive integer (--churn-intensities, CHURN_INTENSITIES or CHURN_DEPLOYMENT_COUNT): 0"
}

@test "churn 003 with --config (no cluster): the failed cell is counted (exit 4) and its placeholder names the config; 004 refuses a dir with two sweeps; 001 and 005 take the config, a flag wins" {
	local res="${BATS_TEST_TMPDIR}/res" f d
	f="$(cfg churn.env 'SETUP_CONTEXTS=ci-a' 'CHURN_INTENSITIES=2' 'CHURN_WAIT_TIMEOUT_SEC=44' "CHURN_RESULTS_DIR=${res}")"
	ISTIO_VERSION_CHECK=warn KUBECONFIG="$EK" run --separate-stderr bash "$CH/003-run-sweep.sh" --config "$f"
	# The only cell's setup failed: the reports are written, then exit 4 with the count.
	assert_failure 4
	[[ "$stderr" == *"error: 1 of 1 cells failed: SETUP_FAILED x1."* ]]
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	[ -s "$d"/sweep-charts-*.md ]
	cmp "$f" "$d"/run-config-*.env
	grep -qx '# RUN_CONFIG=churn.env' "$d"/churn-zzfail-*.tsv
	grep -qx "# RUN_CONFIG_SHA256=$(sum "$f")" "$d"/churn-zzfail-*.tsv
	cp -R "$d" "${res}/sweep-20990101T000000Z-1"
	run --separate-stderr bash "$CH/004-report-results.sh" --config "$f" --format csv
	assert_failure 1
	[[ "$stderr" == *"error: ${res} holds 2 runs"* ]]
	run bash "$CH/001-setup-churn-test.sh" --config "$f" --help
	help_shows_default 44 --wait-timeout CHURN_WAIT_TIMEOUT_SEC
	KUBECONFIG="$EK" run bash "$CH/005-cleanup.sh" --dry-run --config "$f" --contexts ci-z
	assert_output --partial "--context=ci-z delete"
	refute_output --partial "--context=ci-a"
}

# ---------------------------------------------------------------------------
# churn-dataplane
# ---------------------------------------------------------------------------

@test "churn-dataplane --config: its values reach 004's plan, env loses, flags win; 001's namespace wait is COEXEC_SETUP_NS_WAIT_SEC, else the cleanup bound, and --ns-delete-timeout sets both (PL37)" {
	local f
	f="$(cfg cd.env 'SETUP_CONTEXTS=ci-a' 'COEXEC_CHURN_RATES=1,2' 'COEXEC_QPS=50' 'COEXEC_SETUP_NS_WAIT_SEC=600')"
	COEXEC_QPS=999 KUBECONFIG="$EK" run --separate-stderr bash "$CD/004-run-sweep.sh" --dry-run --config "$f"
	assert_success
	assert_output --partial "Churn rates:    1 2 (ops/s)"
	assert_output --partial "QPS:            50"
	[[ "$stderr" == *"001 --source-context ci-a "*"--ns-wait-timeout 600"* ]]
	[[ "$stderr" == *"006 --contexts ci-a --wait-deletion --timeout 240"* ]]
	KUBECONFIG="$EK" run --separate-stderr bash "$CD/004-run-sweep.sh" --dry-run --config "$f" --ns-delete-timeout 99 --churn-rates 5
	assert_output --partial "Churn rates:    5 (ops/s)"
	[[ "$stderr" == *"--ns-wait-timeout 99"* ]]
	[[ "$stderr" == *"--wait-deletion --timeout 99"* ]]
	# Without the setup wait, the config's cleanup bound, in the sweep and in 001 on its own;
	# 006 takes the config's cleanup knobs.
	f="$(cfg d.env 'SETUP_CONTEXTS=ci-q' 'COEXEC_NS_DELETE_TIMEOUT_SEC=300' 'COEXEC_CLEANUP_GRACE_SEC=9')"
	KUBECONFIG="$EK" run --separate-stderr bash "$CD/004-run-sweep.sh" --dry-run --config "$f"
	[[ "$stderr" == *"--ns-wait-timeout 300"* ]]
	run bash "$CD/001-setup-coexec-test.sh" --config "$f" --help
	help_shows_default 300 --ns-wait-timeout COEXEC_SETUP_NS_WAIT_SEC
	COEXEC_SETUP_NS_WAIT_SEC=50 run bash "$CD/001-setup-coexec-test.sh" --config "$f" --help
	help_shows_default 50 --ns-wait-timeout COEXEC_SETUP_NS_WAIT_SEC
	KUBECONFIG="$EK" run bash "$CD/006-cleanup.sh" --dry-run --config "$f"
	assert_success
	assert_output --partial "ci-q"
	assert_output --partial "grace-period=9"
}

@test "churn-dataplane 004 and 003: --scale-to must exceed --base-replicas (as churn 003), before any step" {
	local f
	f="$(cfg eq.env 'SETUP_CONTEXTS=ci-a' 'CHURN_BASE_REPLICAS=2' 'CHURN_SCALE_TO_REPLICAS=2')"
	KUBECONFIG="$EK" run bash "$CD/004-run-sweep.sh" --dry-run --config "$f"
	assert_failure 1
	assert_output --partial "--scale-to (2) must be greater than --base-replicas (2)"
	refute_output --partial "[dry-run] 001"
	KUBECONFIG="$EK" run bash "$CD/003-run-churn-probe.sh" --dry-run --config "$f" --source-context ci-a --churn-rate 5
	assert_failure 1
	assert_output --partial "--scale-to (2) must be greater than --base-replicas (2)"
	KUBECONFIG="$EK" run bash "$CD/004-run-sweep.sh" --dry-run --config "$f" --scale-to 3
	assert_success
}

@test "churn-dataplane 004 with --config (stub kubectl): the failed cell is counted (exit 4), its TSV names the config and the setup wait it passed; 005 refuses a dir with two sweeps" {
	local res="${BATS_TEST_TMPDIR}/res" f d
	f="$(cfg cd.env 'SETUP_CONTEXTS=ci-a' 'COEXEC_CHURN_RATES=1' 'COEXEC_INTER_COMBO_SETTLE_SEC=0' \
		'COEXEC_SETUP_NS_WAIT_SEC=77' "COEXEC_RESULTS_DIR=${res}")"
	# The stub serves one istiod pod for the preflight; every setup then fails (SETUP_FAILED).
	STUB_ISTIOD=1 PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr bash "$CD/004-run-sweep.sh" --config "$f"
	assert_failure 4
	[[ "$stderr" == *"error: 1 of 1 cells failed: SETUP_FAILED x1."* ]]
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	cmp "$f" "$d"/run-config-*.env
	grep -qx '# RUN_CONFIG=cd.env' "$d"/churn-dataplane-*.tsv
	grep -qx "# RUN_CONFIG_SHA256=$(sum "$f")" "$d"/churn-dataplane-*.tsv
	# The setup wait the sweep passed to 001, next to the cleanup bound (PL37).
	grep -qx '# SETUP_NS_WAIT_SEC=77' "$d"/churn-dataplane-*.tsv
	grep -qx '# NS_DELETE_TIMEOUT_SEC=240' "$d"/churn-dataplane-*.tsv
	cp -R "$d" "${res}/sweep-20990101T000000Z-1"
	run --separate-stderr bash "$CD/005-report-results.sh" --results-dir "$res" --format json
	assert_failure 1
	[[ "$stderr" == *"error: ${res} holds 2 runs"* ]]
}

# ---------------------------------------------------------------------------
# propagation
# ---------------------------------------------------------------------------

@test "propagation 006 --dry-run --config: its mesh sizes and iterations reach the plan; env loses, flags win" {
	local f
	f="$(cfg p.env 'SETUP_CONTEXTS=ci-a,ci-b' 'PROPAGATION_MESH_SIZES=1,2' 'PROPAGATION_ITERATIONS=3')"
	PROPAGATION_ITERATIONS=9 KUBECONFIG="$EK" run --separate-stderr bash "$PR/006-run-sweep.sh" --dry-run --config "$f"
	assert_success
	[[ "$stderr" == *"Mesh sizes: 1 2"* ]]
	[[ "$stderr" == *"Total iterations: 6 (cap: 64)"* ]]
	[[ "$stderr" == *"Run config: ${f##*/} (sha256 "* ]]
	[[ "$stderr" == *"--iterations 3 "* ]]
	KUBECONFIG="$EK" run --separate-stderr bash "$PR/006-run-sweep.sh" --dry-run --config "$f" --iterations 2 --mesh-sizes 2
	[[ "$stderr" == *"Total iterations: 2 (cap: 64)"* ]]
}

@test "propagation 006 with --config (no cluster): TSVs without --tsv, the failed cell counted (exit 4) and its placeholder naming the config; 005 refuses a dir with two sweeps; 001 and 007 take the config" {
	local res="${BATS_TEST_TMPDIR}/res" f d
	f="$(cfg prop.env 'SETUP_CONTEXTS=ci-a,ci-b' 'PROPAGATION_SETTLE_SEC=0' "PROPAGATION_RESULTS_DIR=${res}")"
	ISTIO_VERSION_CHECK=warn KUBECONFIG="$EK" run --separate-stderr bash "$PR/006-run-sweep.sh" --config "$f" --mesh-sizes 1
	# The only cell's setup failed: the reports are written, then the sweep says so and exits 4.
	assert_failure 4
	[[ "$stderr" == *"error: 1 of 1 cells failed: SETUP_FAILED x1."* ]]
	[[ "$output" != *"Sweep complete"* ]]
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	[ -s "$d/sweep-summary.md" ]
	cmp "$f" "$d"/run-config-*.env
	grep -qx '# RUN_CONFIG=prop.env' "$d"/endpoint-zzfail-*.tsv
	cp -R "$d" "${res}/sweep-20990101T000000Z-1"
	run --separate-stderr bash "$PR/005-report-results.sh" --results-dir "$res" --format text
	assert_failure 1
	[[ "$stderr" == *"error: ${res} holds 2 runs"* ]]
	f="$(cfg p1.env 'PROPAGATION_WAIT_TIMEOUT_SEC=33' 'SETUP_CONTEXTS=ci-w')"
	run bash "$PR/001-setup-propagation-test.sh" --config "$f" --help
	help_shows_default 33 --wait-timeout PROPAGATION_WAIT_TIMEOUT_SEC
	KUBECONFIG="$EK" run bash "$PR/007-cleanup.sh" --dry-run --config "$f"
	assert_success
	assert_output --partial "ci-w"
}
