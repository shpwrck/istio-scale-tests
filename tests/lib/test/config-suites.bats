#!/usr/bin/env bats
# `--config FILE` through the real scripts of dataplane, churn, churn-dataplane and
# propagation (PL33): the worked examples, precedence, provenance in every TSV writer
# (placeholders included, PL36) and in every report format (PL19/PL26), the sweep
# snapshot, and the shared report helpers; and, for every suite's sweep (controlplane
# included), the worked examples with the CI dry-run args and the up-front knob checks.
# No cluster: KUBECONFIG is an empty file, and the few runs past the preflight use a stub
# kubectl.

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
*" get pod -l app=dataplane-client "*) printf 'dataplane-client-0' ;;
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

# formats_show <report> <dir> <value> <format>...: every format names the value.
formats_show() {
	local report="$1" dir="$2" value="$3" fmt
	shift 3
	for fmt in "$@"; do
		run --separate-stderr bash "$report" --results-dir "$dir" --format "$fmt"
		assert_success
		[[ "$output" == *"$value"* ]] || { echo "$(basename "$report") --format $fmt lacks $value"; false; }
	done
}

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

@test "config_check_multi_run: one run per sweep dir, one per RUN_ID outside one; more than one dies" {
	local r="${BATS_TEST_TMPDIR}/r"
	mkdir -p "$r/sweep-1" "$r/sweep-2"
	# One sweep: its combos carry their own RUN_IDs, still one run.
	printf '# RUN_ID=c1\n# HARNESS_SHA=h1\n# ISTIO_VERSION=v1\nrun_id\nc1\n' > "$r/sweep-1/a.tsv"
	printf '# RUN_ID=c2\n# HARNESS_SHA=h1\n# ISTIO_VERSION=v1\nrun_id\nc2\n' > "$r/sweep-1/b.tsv"
	: > "$r/sweep-2/c.tsv"
	run --separate-stderr config_check_multi_run "$r" 0 "$r/sweep-1/a.tsv" "$r/sweep-1/b.tsv"
	assert_success
	[ -z "$stderr" ]
	config_check_multi_run "$r" 0 "$r/sweep-1/a.tsv" "$r/sweep-1/b.tsv"
	[ "$MULTI_RUN_N" = 1 ] && [ "$MULTI_RUN_IDS" = sweep-1 ]
	[ -z "$(config_multi_run_note)" ] && [ -z "$(config_multi_run_csv)" ]
	[ "$(config_multi_run_json)" = '{"runs":1,"run_ids":["sweep-1"],"harness_sha":["h1"],"istio_version":["v1"]}' ]
	# Two sweeps: dies, naming each sweep dir (newest first) and the command that reports
	# it alone, its path quoted.
	run --separate-stderr config_check_multi_run "$r" 0 "$r/sweep-1/a.tsv" "$r/sweep-2/c.tsv"
	assert_failure 1
	[[ "$stderr" == *"error: ${r} holds 2 runs"*"(newest first; add your other flags):"* ]]
	[[ "$stderr" == *"  sweep-2:"$'\n'"    "*" --results-dir '${r}/sweep-2'"$'\n'"  sweep-1:"$'\n'"    "*" --results-dir '${r}/sweep-1'"* ]]
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
	# Two standalone probes into one dir: two RUN_IDs (preamble, else the first data row),
	# and no --results-dir isolates them.
	printf '# RUN_ID=p1\nrun_id\tx\np1\t1\n' > "$r/latency-p1.tsv"
	printf 'run_id\tx\np2\t1\n' > "$r/churn-p2.tsv"
	run --separate-stderr config_check_multi_run "$r" 0 "$r/latency-p1.tsv" "$r/churn-p2.tsv"
	assert_failure 1
	[[ "$stderr" == *"holds 2 runs"* ]]
	# Each with the commands that give it a directory of its own, then its report:
	# its TSVs by path, then every file named after one of its ids.
	[[ "$stderr" == *"  p2 (its files are in ${r}, outside a sweep-* dir, with another run's files; move them into a directory of their own first):"$'\n'"    mkdir -p '${r}/run-p2'"$'\n'"    for f in '${r}/churn-p2.tsv'; do if [ -e \"\$f\" ]; then mv \"\$f\" '${r}/run-p2/'; fi; done"$'\n'"    find '${r}' -mindepth 1 -maxdepth 1 \\( -name '*p2*' \\) ! -name 'sweep-*' ! -name 'run-p2' -exec mv {} '${r}/run-p2/' \\;"$'\n'"    "*" --results-dir '${r}/run-p2'"$'\n'"  p1 ("* ]]
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
	[[ "$stderr" == *"    mkdir -p '${r}/run-empty'"$'\n'"    for f in '${r}/empty.tsv'; do if [ -e \"\$f\" ]; then mv \"\$f\" '${r}/run-empty/'; fi; done"$'\n'"    "*" --results-dir '${r}/run-empty'"* ]]
	# More than five runs: the five newest, then how many more.
	local i fs=()
	for i in 1 2 3 4 5 6 7; do mkdir -p "$r/sweep-x$i"; : > "$r/sweep-x$i/t.tsv"; fs+=("$r/sweep-x$i/t.tsv"); done
	run --separate-stderr config_check_multi_run "$r" 0 "${fs[@]}"
	assert_failure 1
	[[ "$stderr" == *"holds 7 runs"* && "$stderr" == *"  sweep-x7:"* && "$stderr" == *"  sweep-x3:"* && "$stderr" == *"  ... and 2 more"* ]]
	[[ "$stderr" != *"sweep-x2:"* && "$stderr" != *"sweep-x1:"* ]]
}

@test "config_check_multi_run: the printed commands separate the runs, and the report then accepts each" {
	local r="${BATS_TEST_TMPDIR}/r2" cmd
	mkdir -p "$r/istiod-diag-20261016T100000Z-1"
	printf '# RUN_ID=20261016T100000Z-1\nrun_id\n' > "$r/latency-20261016T100000Z-1.tsv"
	: > "$r/latency-20261016T100000Z-1.md"
	printf '# RUN_ID=20261016T110000Z-2\nrun_id\n' > "$r/latency-20261016T110000Z-2.tsv"
	run --separate-stderr config_check_multi_run "$r" 0 "$r"/*.tsv
	assert_failure 1
	# Run each printed mkdir/for/find line as the operator would paste it, twice.
	local pass
	for pass in 1 2; do
		while IFS= read -r cmd; do
			bash -c "$cmd"
		done < <(sed -n 's/^    \(mkdir .*\|for f in .*\|find .*\)$/\1/p' <<<"$stderr")
	done
	[ -f "$r/run-20261016T100000Z-1/latency-20261016T100000Z-1.tsv" ]
	[ -f "$r/run-20261016T100000Z-1/latency-20261016T100000Z-1.md" ]
	[ -d "$r/run-20261016T100000Z-1/istiod-diag-20261016T100000Z-1" ]
	[ -f "$r/run-20261016T110000Z-2/latency-20261016T110000Z-2.tsv" ]
	[ -z "$(find "$r" -maxdepth 1 -type f)" ]
	run --separate-stderr config_check_multi_run "$r/run-20261016T100000Z-1" 0 "$r/run-20261016T100000Z-1"/*.tsv
	assert_success
}

@test "config_check_multi_run: --results-dir . inside a sweep dir, or sweep-X/ (find's sweep-X//file), is one run" {
	local r="${BATS_TEST_TMPDIR}/r3"
	mkdir -p "$r/sweep-20261016T100000Z-9"
	printf '# RUN_ID=c1\nrun_id\nc1\n' > "$r/sweep-20261016T100000Z-9/a.tsv"
	printf '# RUN_ID=c2\nrun_id\nc2\n' > "$r/sweep-20261016T100000Z-9/b.tsv"
	cd "$r/sweep-20261016T100000Z-9"
	run --separate-stderr config_check_multi_run . 0 ./a.tsv ./b.tsv
	assert_success
	run --separate-stderr config_check_multi_run . 0 a.tsv b.tsv
	assert_success
	cd "$r"
	run --separate-stderr config_check_multi_run sweep-20261016T100000Z-9/ 0 \
		sweep-20261016T100000Z-9//a.tsv sweep-20261016T100000Z-9//b.tsv
	assert_success
	config_check_multi_run . 0 sweep-20261016T100000Z-9//a.tsv sweep-20261016T100000Z-9//b.tsv
	[ "$MULTI_RUN_IDS" = sweep-20261016T100000Z-9 ]
}

@test "config_check_multi_run: a symlinked sweep dir keeps its sweep key, also with CDPATH set" {
	local r="${BATS_TEST_TMPDIR}/r4"
	mkdir -p "$r/store/data" "$r/res"
	printf '# RUN_ID=c1\nrun_id\nc1\n' > "$r/store/data/a.tsv"
	printf '# RUN_ID=c2\nrun_id\nc2\n' > "$r/store/data/b.tsv"
	ln -s "$r/store/data" "$r/res/sweep-20261016T100000Z-9"
	export CDPATH="$r/store"
	run --separate-stderr config_check_multi_run "$r/res/sweep-20261016T100000Z-9" 0 \
		"$r/res/sweep-20261016T100000Z-9/a.tsv" "$r/res/sweep-20261016T100000Z-9/b.tsv"
	assert_success
	config_check_multi_run "$r/res/sweep-20261016T100000Z-9" 0 \
		"$r/res/sweep-20261016T100000Z-9/a.tsv" "$r/res/sweep-20261016T100000Z-9/b.tsv"
	[ "$MULTI_RUN_IDS" = sweep-20261016T100000Z-9 ]
	cd "$r/res/sweep-20261016T100000Z-9"
	config_check_multi_run . 0 ./a.tsv b.tsv
	[ "$MULTI_RUN_IDS" = sweep-20261016T100000Z-9 ]
}

@test "config_check_multi_run: newest first by timestamp across sweeps and standalone runs; a run alone in its dir only gets its report" {
	local r="${BATS_TEST_TMPDIR}/r5"
	mkdir -p "$r/sweep-20261015T100000Z-1" "$r/run-20261014T100000Z-3"
	printf '# RUN_ID=c1\nrun_id\nc1\n' > "$r/sweep-20261015T100000Z-1/a.tsv"
	printf '# RUN_ID=20261016T100000Z-2\nrun_id\n' > "$r/latency-20261016T100000Z-2.tsv"
	printf '# RUN_ID=20261014T100000Z-3\nrun_id\n' > "$r/run-20261014T100000Z-3/latency-20261014T100000Z-3.tsv"
	run --separate-stderr config_check_multi_run "$r" 0 "$r/sweep-20261015T100000Z-1/a.tsv" \
		"$r/latency-20261016T100000Z-2.tsv" "$r/run-20261014T100000Z-3/latency-20261014T100000Z-3.tsv"
	assert_failure 1
	[[ "$stderr" == *"  20261016T100000Z-2 ("*"  sweep-20261015T100000Z-1:"*"  20261014T100000Z-3 ("* ]]
	# The run already in run-<id>/ is never told to nest into run-<id>/run-<id>/.
	[[ "$stderr" == *"  20261014T100000Z-3 (alone in ${r}/run-20261014T100000Z-3):"$'\n'"    "*" --results-dir '${r}/run-20261014T100000Z-3'"* ]]
	[[ "$stderr" != *"run-20261014T100000Z-3/run-"* ]]
	# The standalone run beside the sweep dir and run-<id>/ moves; the find never takes them.
	# Its directory holds no other run's file, only their directories below (the refusal says so).
	[[ "$stderr" == *"  20261016T100000Z-2 (its files are in ${r}, outside a sweep-* dir, above another run's directory (sweep-20261015T100000Z-1); move them"* ]]
	[[ "$stderr" == *"    mkdir -p '${r}/run-20261016T100000Z-2'"* ]]
	[[ "$stderr" == *"! -name 'sweep-*' ! -name 'run-20261016T100000Z-2'"* ]]
}

@test "config_check_multi_run: a symlink such as latest -> sweep-X is that sweep; a sweep-Y symlink to any directory keeps its own key" {
	local r="${BATS_TEST_TMPDIR}/r6"
	mkdir -p "$r/res/sweep-20261016T100000Z-7" "$r/store/data"
	# Three per-probe TSVs of one sweep, each with its own RUN_ID.
	printf '# RUN_ID=p1\nrun_id\np1\n' > "$r/res/sweep-20261016T100000Z-7/a.tsv"
	printf '# RUN_ID=p2\nrun_id\np2\n' > "$r/res/sweep-20261016T100000Z-7/b.tsv"
	printf '# RUN_ID=p3\nrun_id\np3\n' > "$r/res/sweep-20261016T100000Z-7/c.tsv"
	ln -s sweep-20261016T100000Z-7 "$r/res/latest"
	run --separate-stderr config_check_multi_run "$r/res/latest" 0 "$r/res/latest/a.tsv" "$r/res/latest/b.tsv" "$r/res/latest/c.tsv"
	assert_success
	config_check_multi_run "$r/res/latest" 0 "$r/res/latest/a.tsv" "$r/res/latest/b.tsv" "$r/res/latest/c.tsv"
	[ "$MULTI_RUN_N" = 1 ] && [ "$MULTI_RUN_IDS" = sweep-20261016T100000Z-7 ]
	cd "$r/res/latest"
	config_check_multi_run . 0 ./a.tsv b.tsv c.tsv
	[ "$MULTI_RUN_IDS" = sweep-20261016T100000Z-7 ]
	cd "$r"
	# sweep-Y -> a directory not named sweep-*: the link's own name is the key.
	printf '# RUN_ID=q1\nrun_id\nq1\n' > "$r/store/data/a.tsv"
	printf '# RUN_ID=q2\nrun_id\nq2\n' > "$r/store/data/b.tsv"
	ln -s "$r/store/data" "$r/res/sweep-20261016T100000Z-8"
	config_check_multi_run "$r/res/sweep-20261016T100000Z-8" 0 "$r/res/sweep-20261016T100000Z-8/a.tsv" "$r/res/sweep-20261016T100000Z-8/b.tsv"
	[ "$MULTI_RUN_N" = 1 ] && [ "$MULTI_RUN_IDS" = sweep-20261016T100000Z-8 ]
	# A plain directory (no sweep-* on either side) still counts its ids.
	run --separate-stderr config_check_multi_run "$r/store/data" 0 "$r/store/data/a.tsv" "$r/store/data/b.tsv"
	assert_failure 1
	[[ "$stderr" == *"holds 2 runs"* ]]
}


@test "config_input_value and config_merged_preamble: every input, never the first or last file's (PL26)" {
	local a b
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
	run config_merged_preamble "$a" "$b"
	assert_success
	# First-seen key order; a value with a comma joins with " | "; an empty value reads
	# (empty) in a mixed list; a key only one file has keeps its value; nothing after the
	# header line is preamble.
	[ "$output" = "$(printf '%s\n' 'RUN_ID=mixed:r1,r2' 'QPS=10' 'KUBE_VERSIONS=mixed:a=1.30,b=1.30 | a=1.31' 'HOSTS=mixed:(empty),h' 'ONLY_A=x' 'K[c]=1')" ]
}

@test "config_input_value and config_merged_preamble: an ISTIO_VERSION* value is one value whatever its leading v" {
	local a b c
	a="$(cfg va.tsv '# ISTIO_VERSION=v1.30.5' '# ISTIO_VERSION_PIN=v1.30.5' '# ISTIO_VERSION_BY_CONTEXT=x=v1.30.5,y=v1.30.5' '# TAG=v1' 'run_id')"
	b="$(cfg vb.tsv '# ISTIO_VERSION=1.30.5' '# ISTIO_VERSION_PIN=1.30.5' '# ISTIO_VERSION_BY_CONTEXT=x=1.30.5,y=1.30.5' '# TAG=1' 'run_id')"
	c="$(cfg vc.tsv '# ISTIO_VERSION=mixed:1.30.5/v1.29.0' '# ISTIO_VERSION_PIN=1.30.5' '# ISTIO_VERSION_BY_CONTEXT=x=1.30.5,y=v1.29.0' '# TAG=1' 'run_id')"
	run config_input_value ISTIO_VERSION "" "$a" "$b"
	assert_output v1.30.5
	run config_input_value ISTIO_VERSION_PIN "" "$b" "$a"
	assert_output 1.30.5
	run config_merged_preamble "$a" "$b"
	assert_output "$(printf '%s\n' ISTIO_VERSION=v1.30.5 ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_BY_CONTEXT=x=v1.30.5,y=v1.30.5 TAG=mixed:v1,1)"
	# A real difference still reads mixed, each version once.
	run config_input_value ISTIO_VERSION "" "$a" "$b" "$c"
	assert_output mixed:v1.30.5,v1.29.0
	run config_merged_preamble "$a" "$c"
	assert_line "ISTIO_VERSION=mixed:v1.30.5,v1.29.0"
	assert_line "ISTIO_VERSION_BY_CONTEXT=mixed:x=v1.30.5,y=v1.30.5 | x=1.30.5,y=v1.29.0"
}

@test "config_snapshot: a no-op without a config; a byte copy with one" {
	local d="${BATS_TEST_TMPDIR}/snap" f
	RUN_CONFIG=none run config_snapshot "$d" rid
	assert_success
	[ ! -e "$d" ]
	f="$(cfg s.env 'DATAPLANE_SETTLE_SEC=1')"
	RUN_CONFIG=s.env RUN_CONFIG_PATH="$f" run --separate-stderr config_snapshot "$d" rid
	assert_success
	cmp "$f" "$d/run-config-rid.env"
	[[ "$stderr" == *"Run config snapshot: $d/run-config-rid.env"* ]]
}

# ---------------------------------------------------------------------------
# dataplane
# ---------------------------------------------------------------------------

@test "dataplane 003 --dry-run --config: the example's axes and the Run config line; env loses, flags win" {
	cd "$ROOT"
	KUBECONFIG="$EK" run --separate-stderr bash tests/dataplane/003-run-sweep.sh --dry-run \
		--config tests/dataplane/configs/smoke.env --contexts ci-a,ci-b
	assert_success
	assert_output --partial "Mesh sizes: 1 2"
	assert_output --partial "QPS levels: 10,100"
	assert_output --partial "Matrix: 4 combos (cap: 64)"
	assert_output --partial "Settle: 10s | Warmup: 2s | Inter-combo settle: 5s"
	assert_output --partial "Sweep output dir: ${ROOT}/tests/dataplane/results/smoke/sweep-"
	assert_output --partial "Run config: tests/dataplane/configs/smoke.env (sha256 "
	[[ "$stderr" == *"--qps-levels 10,100 --duration 10 --connections 4 --settle 10 --warmup-duration 2"* ]]
	[[ "$stderr" == *"--reach-requests 5"* ]]
	DATAPLANE_SETTLE_SEC=99 KUBECONFIG="$EK" run --separate-stderr bash tests/dataplane/003-run-sweep.sh \
		--dry-run --config tests/dataplane/configs/smoke.env --contexts ci-a,ci-b
	assert_output --partial "Settle: 10s"
	[[ "$stderr" == *"DATAPLANE_SETTLE_SEC=10 (overrides env '99')"* ]]
	KUBECONFIG="$EK" run --separate-stderr bash tests/dataplane/003-run-sweep.sh --dry-run \
		--config tests/dataplane/configs/smoke.env --contexts ci-a,ci-b --settle 7 --mesh-sizes 2
	assert_output --partial "Settle: 7s"
	assert_output --partial "Mesh sizes: 2"
	assert_output --partial "Matrix: 2 combos"
}

@test "dataplane 001/002/005: --help and --dry-run take the config's values" {
	local f
	f="$(cfg dp.env 'SETUP_CONTEXTS=ci-x,ci-y' 'DATAPLANE_WAIT_TIMEOUT_SEC=42' \
		'DATAPLANE_NS_DELETE_TIMEOUT_SEC=77' 'DATAPLANE_QPS_LEVELS=5,6' 'DATAPLANE_SERVER_REPLICAS=3')"
	run bash "$DP/001-setup-dataplane-test.sh" --config "$f" --help
	assert_success
	assert_output --partial "--wait-timeout N         Seconds to wait for pods (default: 42)."
	assert_output --partial "(default: 3)."
	PATH="${BIN}:${PATH}" run bash "$DP/002-run-latency-probe.sh" --dry-run --config "$f" --source-context ci-x
	assert_success
	assert_output --partial "QPS levels: 5 6"
	[ ! -s "$STUB_LOG" ]
	run bash "$DP/005-cleanup.sh" --config "$f" --help
	assert_output --partial "(default: 77)."
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

@test "dataplane 002 with --config: RUN_CONFIG in the preamble; 004 repeats it in every format" {
	local f res="${BATS_TEST_TMPDIR}/res" tsv
	f="$(cfg probe.env "DATAPLANE_RESULTS_DIR=${res}" 'DATAPLANE_QPS_LEVELS=1000' \
		'DATAPLANE_SETTLE_SEC=0' 'DATAPLANE_WARMUP_DURATION_SEC=0' 'REACH_RETRY_SEC=0')"
	PATH="${BIN}:${PATH}" run bash "$DP/002-run-latency-probe.sh" --config "$f" \
		--source-context ctx-a --remote-contexts ctx-b
	assert_success
	tsv="$(ls "$res"/latency-*.tsv)"
	grep -qx '# RUN_CONFIG=probe.env' "$tsv"
	grep -qx "# RUN_CONFIG_SHA256=$(sum "$f")" "$tsv"
	# The reach file next to it carries the same provenance (PL36).
	grep -qx '# RUN_CONFIG=probe.env' "$res"/reach-*.tsv
	grep -qx "# RUN_CONFIG_SHA256=$(sum "$f")" "$res"/reach-*.tsv
	# So does the markdown summary next to it (PL19).
	grep -qxF "| Run config | \`probe.env\` (sha256 \`$(sum "$f")\`) |" "$res"/latency-*.md
	formats_show "$DP/004-report-results.sh" "$res" "probe.env" text csv markdown charts
	run --separate-stderr bash "$DP/004-report-results.sh" --results-dir "$res" --format json
	[ "$(jq -r '.metadata.RUN_CONFIG + " " + .metadata.RUN_CONFIG_SHA256' <<<"$output")" = "probe.env $(sum "$f")" ]
	# A file from before the key existed, next to it: mixed, never credited to the config.
	sed '/^# RUN_CONFIG/d; s/^# RUN_ID=.*/# RUN_ID=old/' "$tsv" > "$res/latency-old.tsv"
	run --separate-stderr bash "$DP/004-report-results.sh" --results-dir "$res" --allow-multi-run --format json
	assert_success
	[ "$(jq -r '.metadata.RUN_CONFIG' <<<"$output")" = "mixed:probe.env,unknown" ]
	[[ "$stderr" == *"input TSVs disagree on RUN_CONFIG (probe.env,unknown)"* ]]
	# Two standalone runs in the config's results dir: the report stops (PL6), and names
	# where each run's files are.
	run --separate-stderr bash "$DP/004-report-results.sh" --config "$f" --format json
	assert_failure 1
	[[ "$stderr" == *"error: ${res} holds 2 runs"* ]]
	[[ "$stderr" == *"  old (its files are in ${res}, outside a sweep-* dir"* ]]
	# Without --config the probe records none.
	rm "$res"/latency-*.tsv
	PATH="${BIN}:${PATH}" DATAPLANE_RESULTS_DIR="$res" run bash "$DP/002-run-latency-probe.sh" \
		--source-context ctx-a --qps-levels 1000 --settle 0 --warmup-duration 0
	assert_success
	grep -qx '# RUN_CONFIG=none' "$res"/latency-*.tsv
}

@test "dataplane 003 with --config, no cluster: snapshot, placeholder provenance, report; multi-run guard" {
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
	# A second sweep under the same base dir: a report of the base dir stops, with or
	# without --config and --results-dir, and names the command for each sweep.
	ISTIO_VERSION_CHECK=warn KUBECONFIG="$EK" run bash "$DP/003-run-sweep.sh" --config "$f" --mesh-sizes 1
	assert_failure 4
	local fmt
	run --separate-stderr bash "$DP/004-report-results.sh" --config "$f" --format json
	assert_failure 1
	[ -z "$output" ]
	[[ "$stderr" == *"error: ${res} holds 2 runs"* ]]
	[[ "$stderr" == *"  $(basename "$d"):"$'\n'"    ${DP}/004-report-results.sh --results-dir '${d}'"* ]]
	run --separate-stderr bash "$DP/004-report-results.sh" --config "$f" --results-dir "$res" --format json
	assert_failure 1
	run --separate-stderr bash "$DP/004-report-results.sh" --results-dir "$res" --format json
	assert_failure 1
	[[ "$stderr" == *"holds 2 runs"* ]]
	# One sweep reports alone.
	run --separate-stderr bash "$DP/004-report-results.sh" --results-dir "$d" --format json
	assert_success
	[ "$(jq -r '.pooled_runs.runs' <<<"$output")" = 1 ]
	# --allow-multi-run pools them, and every format says so (PL19).
	run --separate-stderr bash "$DP/004-report-results.sh" --results-dir "$res" --allow-multi-run --format json
	assert_success
	[ "$(jq -r '.pooled_runs | "\(.runs) \(.run_ids | length) \(.harness_sha | length)"' <<<"$output")" = "2 2 1" ]
	for fmt in text markdown charts csv; do
		run --separate-stderr bash "$DP/004-report-results.sh" --results-dir "$res" --allow-multi-run --format "$fmt"
		assert_success
		[[ "$output" == *"This report pools 2 runs (--allow-multi-run): sweep-"* ]] || { echo "--format $fmt lacks the pooled-runs sentence"; false; }
	done
	assert_line "# POOLED_RUNS=2"
}

@test "dataplane: another suite's key or an environment-only key rejects the file before any step" {
	local f
	f="$(cfg x.env 'COEXEC_QPS=5')"
	KUBECONFIG="$EK" run bash "$DP/005-cleanup.sh" --dry-run --config "$f" --contexts ci-a
	assert_failure 1
	assert_output --partial "unknown key COEXEC_QPS for the dataplane suite"
	refute_output --partial "[dry-run]"
	f="$(cfg ns.env 'DATAPLANE_TEST_NAMESPACE=istio-system')"
	KUBECONFIG="$EK" run bash "$DP/005-cleanup.sh" --dry-run --config "$f" --contexts ci-a
	assert_failure 1
	assert_output --partial "DATAPLANE_TEST_NAMESPACE is not settable from --config"
}

# ---------------------------------------------------------------------------
# churn
# ---------------------------------------------------------------------------

@test "churn 003 --dry-run --config: intensities and mesh sizes from the example; env loses, flags win" {
	cd "$ROOT"
	KUBECONFIG="$EK" run bash tests/churn/003-run-sweep.sh --dry-run \
		--config tests/churn/configs/smoke.env --contexts ci-a,ci-b
	assert_success
	assert_output --partial "Mesh sizes: 1 2"
	assert_output --partial "Churn intensities: 2 4"
	assert_output --partial "Run config: tests/churn/configs/smoke.env (sha256 "
	assert_output --partial "--deployment-count 4 --scale-to 2 --iterations 2 --timeout 60"
	CHURN_INTENSITIES=9 CHURN_MESH_SIZES=2 KUBECONFIG="$EK" run bash tests/churn/003-run-sweep.sh --dry-run \
		--config tests/churn/configs/smoke.env --contexts ci-a,ci-b
	assert_output --partial "Churn intensities: 2 4"
	assert_output --partial "Mesh sizes: 1 2"
	KUBECONFIG="$EK" run bash tests/churn/003-run-sweep.sh --dry-run \
		--config tests/churn/configs/smoke.env --contexts ci-a,ci-b --churn-intensities 3 --mesh-sizes 1
	assert_output --partial "Churn intensities: 3"
	assert_output --partial "Mesh sizes: 1"
	# Without a list key, the singular deployment count is the one intensity (PL7).
	CHURN_DEPLOYMENT_COUNT=7 KUBECONFIG="$EK" run bash tests/churn/003-run-sweep.sh --dry-run --contexts ci-a
	assert_output --partial "Churn intensities: 7"
	refute_output --partial "Run config:"
	# The axes are checked before any step: the example replayed on one context would
	# otherwise label single-cluster rows mesh_size=2.
	KUBECONFIG="$EK" run bash tests/churn/003-run-sweep.sh --dry-run \
		--config tests/churn/configs/smoke.env --contexts ci-a
	assert_failure 1
	assert_output --partial "mesh-size 2 out of range (have 1 contexts)"
	refute_output --partial "002-run-churn-probe"
	CHURN_INTENSITIES=x KUBECONFIG="$EK" run bash tests/churn/003-run-sweep.sh --dry-run --contexts ci-a
	assert_failure 1
	assert_output --partial "churn intensity must be a positive integer"
	KUBECONFIG="$EK" run bash tests/churn/003-run-sweep.sh --dry-run --contexts ci-a --churn-intensities 0
	assert_failure 1
	assert_output --partial "positive integer (--churn-intensities, CHURN_INTENSITIES or CHURN_DEPLOYMENT_COUNT): 0"
}

@test "churn 003 with --config, no cluster: snapshot, placeholder provenance, every 004 format; exit 4" {
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
	# No Istio CR answered: ISTIO_VERSION_CHECK=warn records that, never the pin.
	[[ "$stderr" == *"warning: cannot read the running Istio version on 1 of 1 members:"*"  ci-a: "*"reproduce: "* ]]
	grep -qx '# ISTIO_VERSION=unknown' "$d"/churn-zzfail-*.tsv
	grep -qx "# ISTIO_VERSION_PIN=$(bash -c 'source "$1"; echo "$ISTIO_VERSION"' _ "${ROOT}/config/versions.env")" "$d"/churn-zzfail-*.tsv
	grep -qx '# ISTIO_VERSION_SOURCE=live' "$d"/churn-zzfail-*.tsv
	formats_show "$CH/004-report-results.sh" "$d" "$(sum "$f")" text csv md charts
	run --separate-stderr bash "$CH/004-report-results.sh" --results-dir "$d" --format md
	assert_output --partial 'run_config: "churn.env"'
	# 001/005 take the config's contexts; a flag still wins.
	run bash "$CH/001-setup-churn-test.sh" --config "$f" --help
	assert_output --partial "--wait-timeout N       Seconds to wait for pods (default: 44)."
	KUBECONFIG="$EK" run bash "$CH/005-cleanup.sh" --dry-run --config "$f" --contexts ci-z
	assert_output --partial "--context=ci-z delete"
	refute_output --partial "--context=ci-a"
}

# ---------------------------------------------------------------------------
# churn-dataplane
# ---------------------------------------------------------------------------

@test "churn-dataplane 004 --dry-run --config: the example's axes and windows; env loses, flags win" {
	cd "$ROOT"
	KUBECONFIG="$EK" run bash tests/churn-dataplane/004-run-sweep.sh --dry-run \
		--config tests/churn-dataplane/configs/smoke.env --contexts ci-a,ci-b
	assert_success
	assert_output --partial "Mesh sizes:     1 2"
	assert_output --partial "Churn rates:    1 2 (ops/s)"
	assert_output --partial "Baseline dur:   20s | Churn dur: 20s"
	assert_output --partial "Run config:     tests/churn-dataplane/configs/smoke.env (sha256 "
	assert_output --partial "--deployment-count 3 --base-replicas 1 --scale-to 2"
	COEXEC_QPS=999 KUBECONFIG="$EK" run bash tests/churn-dataplane/004-run-sweep.sh --dry-run \
		--config tests/churn-dataplane/configs/smoke.env --contexts ci-a,ci-b --churn-rates 5
	assert_output --partial "QPS:            50"
	assert_output --partial "Churn rates:    5 (ops/s)"
}

@test "churn-dataplane 004: 001's namespace wait is COEXEC_SETUP_NS_WAIT_SEC unless --ns-delete-timeout" {
	local f
	f="$(cfg w.env 'SETUP_CONTEXTS=ci-a' 'COEXEC_SETUP_NS_WAIT_SEC=600')"
	KUBECONFIG="$EK" run --separate-stderr bash "$CD/004-run-sweep.sh" --dry-run --config "$f"
	assert_success
	[[ "$stderr" == *"001 --source-context ci-a "*"--ns-wait-timeout 600"* ]]
	[[ "$stderr" == *"006 --contexts ci-a --wait-deletion --timeout 240"* ]]
	# The flag sets both bounds (PL37).
	KUBECONFIG="$EK" run --separate-stderr bash "$CD/004-run-sweep.sh" --dry-run --config "$f" --ns-delete-timeout 99
	[[ "$stderr" == *"--ns-wait-timeout 99"* ]]
	[[ "$stderr" == *"--wait-deletion --timeout 99"* ]]
	# Without either, the cleanup bound (options.env).
	f="$(cfg d.env 'SETUP_CONTEXTS=ci-a' 'COEXEC_NS_DELETE_TIMEOUT_SEC=300')"
	KUBECONFIG="$EK" run --separate-stderr bash "$CD/004-run-sweep.sh" --dry-run --config "$f"
	[[ "$stderr" == *"--ns-wait-timeout 300"* ]]
}

@test "churn-dataplane 004 and 003: --scale-to must exceed --base-replicas (as churn 003)" {
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

@test "churn-dataplane 004 with --config (stub kubectl): preamble, snapshot, every 005 format" {
	local res="${BATS_TEST_TMPDIR}/res" f d
	f="$(cfg cd.env 'SETUP_CONTEXTS=ci-a' 'COEXEC_CHURN_RATES=1' 'COEXEC_INTER_COMBO_SETTLE_SEC=0' \
		'COEXEC_SETUP_NS_WAIT_SEC=77' "COEXEC_RESULTS_DIR=${res}")"
	# The stub serves one istiod pod for the preflight; every setup then fails (SETUP_FAILED).
	STUB_ISTIOD=1 PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr bash "$CD/004-run-sweep.sh" --config "$f"
	# Every combo failed (SETUP_FAILED): the reports are written, then exit 4.
	assert_failure 4
	[[ "$stderr" == *"error: 1 of 1 cells failed: SETUP_FAILED x1."* ]]
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	cmp "$f" "$d"/run-config-*.env
	grep -qx '# RUN_CONFIG=cd.env' "$d"/churn-dataplane-*.tsv
	grep -qx "# RUN_CONFIG_SHA256=$(sum "$f")" "$d"/churn-dataplane-*.tsv
	# The setup wait the sweep passed to 001, next to the cleanup bound (PL37).
	grep -qx '# SETUP_NS_WAIT_SEC=77' "$d"/churn-dataplane-*.tsv
	grep -qx '# NS_DELETE_TIMEOUT_SEC=240' "$d"/churn-dataplane-*.tsv
	formats_show "$CD/005-report-results.sh" "$d" "$(sum "$f")" text csv md charts
	run --separate-stderr bash "$CD/005-report-results.sh" --results-dir "$d" --format json
	[ "$(jq -r '.metadata.run_config' <<<"$output")" = "cd.env" ]
	# 006 takes the config's cleanup knobs.
	f="$(cfg c6.env 'SETUP_CONTEXTS=ci-q' 'COEXEC_CLEANUP_GRACE_SEC=9' 'COEXEC_NS_DELETE_TIMEOUT_SEC=600')"
	KUBECONFIG="$EK" run bash "$CD/006-cleanup.sh" --dry-run --config "$f"
	assert_success
	assert_output --partial "ci-q"
	assert_output --partial "grace-period=9"
	# PL37: 001's wait for a terminating namespace follows the config's cleanup bound...
	run bash "$CD/001-setup-coexec-test.sh" --config "$f" --help
	assert_output --partial "run to disappear before applying (default: 600)."
	# ...unless the setup wait itself is set.
	COEXEC_SETUP_NS_WAIT_SEC=50 run bash "$CD/001-setup-coexec-test.sh" --config "$f" --help
	assert_output --partial "(default: 50)."
}

# ---------------------------------------------------------------------------
# propagation
# ---------------------------------------------------------------------------

@test "propagation 006 --dry-run --config: the example's mesh sizes and iterations; flags win" {
	cd "$ROOT"
	KUBECONFIG="$EK" run --separate-stderr bash tests/propagation/006-run-sweep.sh --dry-run --tsv \
		--config tests/propagation/configs/smoke.env --contexts ci-a,ci-b
	assert_success
	[[ "$stderr" == *"Mesh sizes: 1 2"* ]]
	[[ "$stderr" == *"Total iterations: 6 (cap: 64)"* ]]
	[[ "$stderr" == *"Run config: tests/propagation/configs/smoke.env (sha256 "* ]]
	[[ "$stderr" == *"--iterations 3 --timeout 60 --settle-sec 3"* ]]
	# The no-op --tsv says so, once.
	[ "$(grep -c 'note: --tsv is the default now' <<<"$stderr")" = 1 ]
	KUBECONFIG="$EK" run --separate-stderr bash tests/propagation/006-run-sweep.sh --dry-run \
		--config tests/propagation/configs/smoke.env --contexts ci-a,ci-b --iterations 2 --mesh-sizes 2
	[[ "$stderr" == *"Total iterations: 2 (cap: 64)"* ]]
	[[ "$stderr" != *"--tsv is the default"* ]]
}

@test "propagation 006 with --config, no cluster: TSVs without --tsv, every 005 format, then exit 4" {
	local res="${BATS_TEST_TMPDIR}/res" f d
	f="$(cfg prop.env 'SETUP_CONTEXTS=ci-a,ci-b' 'PROPAGATION_SETTLE_SEC=0' "PROPAGATION_RESULTS_DIR=${res}")"
	ISTIO_VERSION_CHECK=warn KUBECONFIG="$EK" run --separate-stderr bash "$PR/006-run-sweep.sh" --config "$f" --mesh-sizes 1
	# The only cell's setup failed: the reports are written, then the sweep says so and exits 4.
	assert_failure 4
	[[ "$stderr" == *"error: 1 of 1 cells failed: SETUP_FAILED x1."* ]]
	[[ "$output" != *"Sweep complete"* ]]
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	[ -s "$d/sweep-summary.md" ]
	[ -s "$d/sweep-charts.md" ]
	cmp "$f" "$d"/run-config-*.env
	grep -qx '# RUN_CONFIG=prop.env' "$d"/endpoint-zzfail-*.tsv
	formats_show "$PR/005-report-results.sh" "$d" "$(sum "$f")" text csv markdown json charts
	run --separate-stderr bash "$PR/005-report-results.sh" --results-dir "$d" --format json
	[ "$(jq -r '.metadata.RUN_CONFIG' <<<"$output")" = "prop.env" ]
	# 001 and 007 take the config.
	f="$(cfg p1.env 'PROPAGATION_WAIT_TIMEOUT_SEC=33' 'SETUP_CONTEXTS=ci-w')"
	run bash "$PR/001-setup-propagation-test.sh" --config "$f" --help
	assert_output --partial "Ready (default: 33)."
	KUBECONFIG="$EK" run bash "$PR/007-cleanup.sh" --dry-run --config "$f"
	assert_success
	assert_output --partial "ci-w"
}

# ---------------------------------------------------------------------------
# Every suite's sweep (controlplane included): the worked examples with the CI dry-run
# args, and the knobs only the steps read, checked before the first step.
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

@test "every sweep rejects a bad step-only knob from --config under --dry-run, before any step" {
	local sweep key f
	while read -r sweep key; do
		f="$(cfg "bad-${key}.env" "${key}=5m")"
		KUBECONFIG="$EK" run bash "${ROOT}/tests/${sweep}" --dry-run --config "$f" --contexts ci-a
		[ "$status" -eq 1 ] || { echo "${sweep} with ${key}=5m: exit ${status}"; echo "$output" | tail -3; false; }
		[[ "$output" == *"${key} (read by "*"5m"* ]] || { echo "${sweep}: no '${key} (read by' error"; echo "$output" | tail -3; false; }
		[[ "$output" != *"Dry-run complete"* && "$output" != *"[dry-run] 001"* ]]
	done <<'LIST'
dataplane/003-run-sweep.sh DATAPLANE_WAIT_TIMEOUT_SEC
dataplane/003-run-sweep.sh DATAPLANE_NS_DELETE_TIMEOUT_SEC
churn/003-run-sweep.sh CHURN_WAIT_TIMEOUT_SEC
churn/003-run-sweep.sh CHURN_SETTLE_SEC
churn/003-run-sweep.sh CHURN_POLL_INTERVAL_MS
churn-dataplane/004-run-sweep.sh COEXEC_WAIT_TIMEOUT_SEC
churn-dataplane/004-run-sweep.sh COEXEC_SETUP_NS_WAIT_SEC
churn-dataplane/004-run-sweep.sh COEXEC_CLEANUP_GRACE_SEC
churn-dataplane/004-run-sweep.sh COEXEC_SERVICE_PORT
propagation/006-run-sweep.sh PROPAGATION_WAIT_TIMEOUT_SEC
propagation/006-run-sweep.sh PROPAGATION_POLL_INTERVAL_MS
propagation/006-run-sweep.sh PROPAGATION_DRAIN_TIMEOUT_SEC
controlplane/003-run-sweep.sh CONTROLPLANE_WAIT_TIMEOUT_SEC
controlplane/003-run-sweep.sh CONTROLPLANE_SETUP_NS_WAIT_SEC
controlplane/003-run-sweep.sh CONTROLPLANE_APPLY_ATTEMPTS
controlplane/003-run-sweep.sh CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S
controlplane/003-run-sweep.sh CONTROLPLANE_NS_DELETE_TIMEOUT_SEC
controlplane/003-run-sweep.sh CONTROLPLANE_CLEANUP_GRACE_SEC
LIST
}

@test "dataplane and churn-dataplane sweeps reject a bad probe-window knob under --dry-run, from --config or the flag" {
	local sweep key flag val f
	# no_plan: the run stopped before the plan's first step.
	no_plan() { [[ "$output" != *"Dry-run complete"* && "$output" != *"[dry-run] 001"* && "$output" != *"001-setup"* ]]; }
	while read -r sweep key flag val; do
		f="$(cfg "bad-${key}.env" "${key}=${val}")"
		KUBECONFIG="$EK" run bash "${ROOT}/tests/${sweep}" --dry-run --config "$f" --contexts ci-a
		[ "$status" -eq 1 ] || { echo "${sweep} with ${key}=${val}: exit ${status}"; echo "$output" | tail -3; false; }
		[[ "$output" == *"${flag} (or ${key})"*"'${val}'"* ]] || { echo "${sweep}: no '${flag} (or ${key})' error naming '${val}'"; echo "$output" | tail -3; false; }
		no_plan
		KUBECONFIG="$EK" run bash "${ROOT}/tests/${sweep}" --dry-run --contexts ci-a "$flag" "$val"
		[ "$status" -eq 1 ] || { echo "${sweep} ${flag} ${val}: exit ${status}"; echo "$output" | tail -3; false; }
		[[ "$output" == *"${flag}"* ]]
		no_plan
	done <<'LIST'
dataplane/003-run-sweep.sh DATAPLANE_DURATION_SEC --duration 5m
dataplane/003-run-sweep.sh DATAPLANE_NUM_CONNECTIONS --connections x
dataplane/003-run-sweep.sh DATAPLANE_SETTLE_SEC --settle 5m
dataplane/003-run-sweep.sh DATAPLANE_WARMUP_DURATION_SEC --warmup-duration 5m
dataplane/003-run-sweep.sh DATAPLANE_REPETITIONS --repetitions 0
dataplane/003-run-sweep.sh DATAPLANE_QPS_LEVELS --qps-levels 10,5m
churn-dataplane/004-run-sweep.sh COEXEC_BASELINE_DURATION_SEC --baseline-duration 5m
churn-dataplane/004-run-sweep.sh COEXEC_CHURN_DURATION_SEC --churn-duration 5m
churn-dataplane/004-run-sweep.sh COEXEC_QPS --qps abc
churn-dataplane/004-run-sweep.sh COEXEC_NUM_CONNECTIONS --connections x
churn-dataplane/004-run-sweep.sh COEXEC_SETTLE_SEC --settle-sec 5m
churn-dataplane/004-run-sweep.sh COEXEC_INTER_COMBO_SETTLE_SEC --inter-combo-settle 5m
churn-dataplane/004-run-sweep.sh COEXEC_CHURN_SEED --seed -1
churn-dataplane/004-run-sweep.sh COEXEC_REPETITIONS --repetitions 5m
LIST
	# No flag for these two; DATAPLANE_MAX_MATRIX is environment-only.
	f="$(cfg bad-ics.env 'DATAPLANE_INTER_COMBO_SETTLE_SEC=5m')"
	KUBECONFIG="$EK" run bash "${ROOT}/tests/dataplane/003-run-sweep.sh" --dry-run --config "$f" --contexts ci-a
	[ "$status" -eq 1 ]
	[[ "$output" == *"DATAPLANE_INTER_COMBO_SETTLE_SEC must be a non-negative integer; got '5m'"* ]]
	no_plan
	DATAPLANE_MAX_MATRIX=lots KUBECONFIG="$EK" run bash "${ROOT}/tests/dataplane/003-run-sweep.sh" --dry-run --contexts ci-a
	[ "$status" -eq 1 ]
	[[ "$output" == *"DATAPLANE_MAX_MATRIX must be a positive integer; got 'lots'"* ]]
	no_plan
	# The probe steps check their own window too, for a standalone run.
	KUBECONFIG="$EK" run bash "$CD/002-run-baseline-probe.sh" --dry-run --source-context ci-dummy --duration 5m
	[ "$status" -eq 1 ]
	[[ "$output" == *"--duration (or COEXEC_BASELINE_DURATION_SEC) must be a positive integer; got '5m'"* ]]
	COEXEC_QPS=abc KUBECONFIG="$EK" run bash "$CD/003-run-churn-probe.sh" --dry-run --source-context ci-dummy --churn-rate 5
	[ "$status" -eq 1 ]
	[[ "$output" == *"--qps (or COEXEC_QPS) must be a positive integer; got 'abc'"* ]]
}

# ---------------------------------------------------------------------------
# PL36: every TSV writer of these suites emits RUN_CONFIG* through config_preamble_lines,
# and every report reads it over all inputs.
# ---------------------------------------------------------------------------

# in_block <file> <start-regex> <end-regex> [text]: text (default config_preamble_lines)
# appears between the first line matching start and the next line matching end.
in_block() {
	# The regexes go through ENVIRON, not -v, so awk does not eat their backslashes.
	S="$2" E="$3" N="${4:-config_preamble_lines}" awk '$0 ~ ENVIRON["S"] { on = 1; next }
		on && $0 ~ ENVIRON["E"] { exit }
		on && index($0, ENVIRON["N"]) { found = 1 } END { exit !found }' "$1" \
		|| { echo "$(basename "$1"): no '${4:-config_preamble_lines}' between /$2/ and /$3/"; return 1; }
}

# The Run config row of every per-run markdown summary (PL19).
# shellcheck disable=SC2016  # the literal row as the scripts write it
MD_ROW='echo "| Run config | \`${RUN_CONFIG:-none}\` (sha256 \`${RUN_CONFIG_SHA256:-none}\`) |"'

@test "PL36, PL39: every results writer, placeholders included, records the Istio version keys through istio_version_kv" {
	local CP="${ROOT}/tests/controlplane" IV=istio_version_kv
	in_block "$DP/002-run-latency-probe.sh" 'echo "# RUN_ID=' '^\} > "\$TSV_FILE"' "$IV"
	in_block "$DP/003-run-sweep.sh" '^emit_dataplane_placeholder\(\)' 'printf .run_id' "$IV"
	in_block "$CH/002-run-churn-probe.sh" '^cat > "\$TSV_FILE" <<EOF' 'run_id mesh_size churn_intensity' "$IV"
	in_block "$CH/003-run-sweep.sh" '^emit_churn_placeholder\(\)' 'run_id mesh_size churn_intensity' "$IV"
	in_block "$PR/002-run-endpoint-probe.sh" 'echo "# Endpoint propagation latency test"' '^[[:space:]]*\} > "\$TSV_FILE"' "$IV"
	in_block "$PR/006-run-sweep.sh" '^emit_propagation_placeholder\(\)' 'PROP_TSV_HEADER' "$IV"
	in_block "$CP/002-collect-resource-metrics.sh" 'echo "# Control-plane resource metrics' '\} > "\$TSV_FILE"' "$IV"
	in_block "$CP/003-run-sweep.sh" '^precreate_tsv_preamble\(\)' '^\}' "$IV"
	in_block "$CP/003-run-sweep.sh" 'ns_lifecycle_init "\$LIFECYCLE_FILE"' 'printf .timestamp' '"${_iv_kv[@]}"'
	in_block "${ROOT}/tests/lib/preamble.sh" '^ns_lifecycle_init\(\)' '^\}' "$IV"
	in_block "${ROOT}/tests/gateway-api/001-run-ingress-check.sh" '^emit_preamble\(\)' '^\}' "$IV"
	in_block "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" '^mkdir -p "\$SWEEP_DIR"' 'sweep-metadata.txt' "$IV"
	local f
	for f in "$CD/002-run-baseline-probe.sh" "$CD/003-run-churn-probe.sh" "$CD/004-run-sweep.sh"; do
		grep -q '^mapfile -t IV_KV < <(istio_version_kv)$' "$f"
		in_block "$f" 'write_preamble "churn-dataplane' 'printf .run_id' '"${IV_KV[@]}"'
	done
	# No writer spells the key itself (a second spelling is how one drifts from the others);
	# the reports echo what they read, and istio_version_kv is the one spelling.
	run bash -c 'grep -nE "echo \"# ISTIO_VERSION(_PIN|_SOURCE|_BY_CONTEXT)?=|\"ISTIO_VERSION(_PIN|_SOURCE|_BY_CONTEXT)?=\\$" "$@" | grep -vE "report-results\.sh:|/lib/preamble\.sh:"' _ \
		"${ROOT}"/tests/*/0*.sh "${ROOT}"/tests/lib/*.sh
	assert_output ""
	# Each run resolves the version once, before its first change (PL39: every suite).
	for f in "$DP/002-run-latency-probe.sh" "$DP/003-run-sweep.sh" "$CH/002-run-churn-probe.sh" "$CH/003-run-sweep.sh" \
		"$CD/002-run-baseline-probe.sh" "$CD/003-run-churn-probe.sh" "$CD/004-run-sweep.sh" \
		"$PR/002-run-endpoint-probe.sh" "$PR/006-run-sweep.sh" "$CP/002-collect-resource-metrics.sh" \
		"$CP/003-run-sweep.sh" "${ROOT}/tests/tuning/003-run-tuning-sweep.sh"; do
		grep -q '^[[:space:]]*istio_version_resolve ' "$f" || { echo "$(basename "$f") never resolves the Istio version"; false; }
	done
	# The check fires on a writer without it.
	sed '/istio_version_kv/d' "$DP/003-run-sweep.sh" > "${BATS_TEST_TMPDIR}/003.sh"
	run in_block "${BATS_TEST_TMPDIR}/003.sh" '^emit_dataplane_placeholder\(\)' 'printf .run_id' "$IV"
	assert_failure
}

@test "PL36: every preamble writer (placeholders included) calls config_preamble_lines" {
	in_block "$DP/002-run-latency-probe.sh" 'echo "# RUN_ID=' '^\} > "\$TSV_FILE"'
	in_block "$DP/003-run-sweep.sh" '^emit_dataplane_placeholder\(\)' 'printf .run_id'
	in_block "$CH/002-run-churn-probe.sh" '^cat > "\$TSV_FILE" <<EOF' 'run_id mesh_size churn_intensity'
	in_block "$CH/003-run-sweep.sh" '^emit_churn_placeholder\(\)' 'run_id mesh_size churn_intensity'
	in_block "$CD/002-run-baseline-probe.sh" 'write_preamble "churn-dataplane' 'printf .run_id'
	in_block "$CD/003-run-churn-probe.sh" 'write_preamble "churn-dataplane' 'printf .run_id'
	in_block "$CD/004-run-sweep.sh" 'write_preamble "churn-dataplane' 'printf .run_id'
	in_block "$PR/002-run-endpoint-probe.sh" 'echo "# Endpoint propagation latency test"' '^[[:space:]]*\} > "\$TSV_FILE"'
	in_block "$PR/006-run-sweep.sh" '^emit_propagation_placeholder\(\)' 'PROP_TSV_HEADER'
	# reach-<RUN_ID>.tsv (dataplane and churn-dataplane 002) through its one writer.
	in_block "${ROOT}/tests/lib/reach.sh" 'echo "# Remote reachability check' 'printf .run_id'
	# The check fires on a writer without it.
	sed '/config_preamble_lines/d' "$DP/003-run-sweep.sh" > "${BATS_TEST_TMPDIR}/003.sh"
	run in_block "${BATS_TEST_TMPDIR}/003.sh" '^emit_dataplane_placeholder\(\)' 'printf .run_id'
	assert_failure
	local r
	for r in "$DP/004-report-results.sh" "$CH/004-report-results.sh" "$CD/005-report-results.sh" "$PR/005-report-results.sh"; do
		grep -q 'config_report_value RUN_CONFIG ' "$r"
		grep -q 'config_report_value RUN_CONFIG_SHA256 ' "$r"
	done
	# Every report runs the multi-run guard (PL39), controlplane's included.
	for r in "$DP/004-report-results.sh" "$CH/004-report-results.sh" "$CD/005-report-results.sh" "$PR/005-report-results.sh" \
		"${ROOT}/tests/controlplane/004-report-results.sh"; do
		grep -q '^config_check_multi_run "\$RESULTS_DIR" "\$ALLOW_MULTI_RUN" ' "$r"
		grep -q '^POOLED_NOTE="\$(config_multi_run_note)"' "$r"
		grep -q -- '--allow-multi-run)' "$r"
	done
	# The markdown summary each probe writes next to its TSV names the config too (PL19).
	in_block "$DP/002-run-latency-probe.sh" '^write_run_md\(\)' '^\}$' "$MD_ROW"
	in_block "$CH/002-run-churn-probe.sh" '^MD_FILE=.*/churn-' '^\} > "\$MD_FILE"' "$MD_ROW"
	in_block "$PR/002-run-endpoint-probe.sh" '^MD_FILE=.*/endpoint-' '^\} > "\$MD_FILE"' "$MD_ROW"
	in_block "${ROOT}/tests/controlplane/002-collect-resource-metrics.sh" 'MD_FILE=.*/controlplane-' '\} > "\$MD_FILE"' "$MD_ROW"
	run in_block "$CH/002-run-churn-probe.sh" '^MD_FILE=.*/churn-' '^\} > "\$MD_FILE"' 'no such row'
	assert_failure
}
