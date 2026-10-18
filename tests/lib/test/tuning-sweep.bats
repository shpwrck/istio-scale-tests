#!/usr/bin/env bats
# The tuning sweep's Istio CR checkpoints (tests/tuning/003): an edit by something else
# during the baseline pass, or during a pass whose profile leaves the Istio CR alone
# (istio_cr_patch: {}), is a problem (exit 4), named by the reads it fell between; the
# sweep's own apply and revert are none. A re-run of 002 after a revert that died after its
# patch is no foreign edit. The proxies are read after each pass's settle. A --resume's
# reads are named by when it started. The Istio version check leaves nothing in TMPDIR when
# it is interrupted; its proxy reads run at most ISTIO_PROXY_READ_PARALLEL members at once.
# Through the real scripts (PL33); no cluster: kubectl is a stub.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/preamble.sh"

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 METRICS_READY_TIMEOUT=0
}

# _need_yaml: the tuning lib needs python3 with PyYAML.
_need_yaml() {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed (tuning lib)"
}

# _tun_stub: a kubectl with a stateful Istio CR (files in TD): cr.json (its spec) and gen
# (its generation, and its IstioRevision's, which Sail raises with it). A merge patch
# applies (RFC 7386) and raises gen; a revert patch (istio-revert-*) also removes the
# applied marker. A profile's resources: a server-side apply creates them (res), a delete
# removes them. One istiod pod (istiod-a) whose /metrics names TUN_PROXY_VERSION (default
# 1.30.5) for 3 proxies. Every call is logged to KLOG; a `sleep` on PATH logs `SLEEP <sec>`
# there and returns at once (the settle). TUN_FOREIGN_WHEN: someone else edits the Istio CR
# once (gen + 1): `baseline` at an istiod pod list during the baseline pass (its dir exists,
# no profile's state dir yet), `applied` at one while a profile is applied, else at the
# first call that matches that glob. Any other call fails (the probes then fail:
# PROBE_FAILED).
_tun_stub() {
	export TD="${BATS_TEST_TMPDIR}/tun" KLOG="${BATS_TEST_TMPDIR}/kubectl.log" TUN_RES="${BATS_TEST_TMPDIR}/tres"
	mkdir -p "$TD"
	: > "$KLOG"
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$TD"
printf '%s\n' "$*" >> "$KLOG"
[ -f "$d/gen" ] || echo 2 > "$d/gen"
[ -f "$d/cr.json" ] || echo '{"spec":{"version":"v1.30-latest","values":{}}}' > "$d/cr.json"
if [ -n "${TUN_FOREIGN_WHEN:-}" ] && [ ! -e "$d/foreign-done" ]; then
	hit=""
	case "$TUN_FOREIGN_WHEN" in
	baseline)
		case "$*" in *" get pods -l app=istiod"*)
			for b in "$TUN_RES"/sweep-*/baseline; do [ ! -d "$b" ] || hit=1; done
			for s in "$TUN_RES"/sweep-*/*/state; do [ ! -d "$s" ] || hit=""; done ;;
		esac ;;
	applied)
		case "$*" in *" get pods -l app=istiod"*)
			if [ -f "$d/res" ] || [ -f "$d/applied" ]; then hit=1; fi ;;
		esac ;;
	*) case "$*" in $TUN_FOREIGN_WHEN) hit=1 ;; esac ;;
	esac
	[ -z "$hit" ] || { echo $(($(cat "$d/gen") + 1)) > "$d/gen"; : > "$d/foreign-done"; echo "FOREIGN EDIT" >> "$KLOG"; }
fi
g="$(cat "$d/gen")"
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	STUB_ISTIO_CR_GEN="$g" STUB_ISTIO_REV_GEN="$g" exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" patch istio.sailoperator.io default --type=merge --patch-file="*)
	f="${*##*--patch-file=}"; f="${f%% *}"
	jq --slurpfile p "$f" 'def mp($q): if ($q | type) == "object" then reduce ($q | keys_unsorted[]) as $k ((if type == "object" then . else {} end); if $q[$k] == null then del(.[$k]) else .[$k] = (.[$k] | mp($q[$k])) end) else $q end; mp($p[0])' "$d/cr.json" > "$d/cr.new" && mv "$d/cr.new" "$d/cr.json"
	case "$f" in
	*istio-revert-*) rm -f "$d/applied" ;;
	*) : > "$d/applied" ;;
	esac
	echo $((g + 1)) > "$d/gen" ;;
*" get istio.sailoperator.io default -o jsonpath={.metadata.generation}"*) echo "$g $g True default" ;;
*" get istio.sailoperator.io default -o jsonpath={.status.activeRevisionName}"*) echo default ;;
*" get istio.sailoperator.io default -o json")
	jq -c --argjson g "$g" '. + {metadata: {name: "default", generation: $g}}' "$d/cr.json" ;;
*" get istiorevision.sailoperator.io default -o jsonpath="*) echo "$g $g True" ;;
*" rollout status "*) exit 0 ;;
*" -n istio-system get deployment istiod -o json"*)
	jq -c '{spec: {template: {spec: {containers: [{name: "discovery", env: ((.spec.values.pilot.env // {}) | to_entries | map({name: .key, value: (.value | tostring)}))}]}}}}' "$d/cr.json" ;;
*" apply --server-side "*) : > "$d/res" ;;
*" delete --ignore-not-found -f "*) rm -f "$d/res" ;;
*" get --ignore-not-found -f "*) : ;;
*" tuning-connection-pool -o name"*) [ -f "$d/res" ] ;;
*" --request-timeout=5s -n istio-system get pods -l app=istiod "*) echo pod/istiod-a ;;
*" get --raw /api/v1/namespaces/istio-system/pods/istiod-a:15014/proxy/metrics"*)
	printf '# TYPE pilot_xds gauge\npilot_xds{version="%s"} 3\n' "${TUN_PROXY_VERSION:-1.30.5}" ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
	printf '#!/bin/sh\necho "SLEEP $*" >> "$KLOG"\n' > "${BIN}/sleep"
	chmod +x "${BIN}/sleep"
}

# tun_sweep <profiles> [<settle>]: tuning 003 over the churn suite on ci-a, baseline and
# <profiles>, no setup and no Argo CD pause; results under tres/. Sets TDIR.
tun_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite churn --contexts ci-a --no-gitops-pause --skip-setup --keep-workloads \
		--profiles "$1" --settle "${2:-0}" --output-dir "$TUN_RES"
	TDIR="$(find "$TUN_RES" -maxdepth 1 -name 'sweep-*' -type d)"
}

# _proxy_settle_order: the settles (SLEEP 7) and the sweep's own proxy reads in KLOG, in
# order, as one line ("P" a read, "S" a settle).
_proxy_settle_order() {
	awk '$0 == "SLEEP 7" { printf "S" } /--request-timeout=5s -n istio-system get pods -l app=istiod / { printf "P" } END { print "" }' "$KLOG"
}

@test "an Istio CR edit by something else during the baseline pass is a problem (exit 4), named by the reads it fell between; the proxies are read after each pass's settle" {
	_need_yaml
	_tun_stub
	TUN_FOREIGN_WHEN=baseline tun_sweep 01-push-throttling 7
	[ "$status" -eq 4 ]
	grep -qx 'FOREIGN EDIT' "$KLOG"
	local want="the Istio CR changed while the sweep changed nothing, between its read at the sweep's start and its read before the apply of pass 01-push-throttling: ci-a (Istio CR generation 2 -> 3, IstioRevision generation 2 -> 3); likely: a version changed and changed back, or a values change (an edit of the Istio CR); the passes run since that first read may have measured another configuration"
	[[ "$stderr" == *"WARNING: ${want}"$'\n'* ]] || { echo "$stderr"; false; }
	[[ "$stderr" == *"error: ${want}; exit 4."* ]]
	grep -qxF "PROBLEM=${want}" "${TDIR}/sweep-outcome.txt"
	[ "$(grep -c '^PROBLEM=' "${TDIR}/sweep-outcome.txt")" -eq 1 ]
	# The start's read, then each pass's settle followed by its proxy read (none right after
	# the apply, while old istiod pods may still be terminating).
	[ "$(_proxy_settle_order)" = PSPSP ]
	# Without the edit: no problem, the same reads.
	rm -rf "$TD" "$TUN_RES"
	_tun_stub
	tun_sweep 01-push-throttling 7
	[ "$status" -eq 4 ]
	! grep -q '^PROBLEM=' "${TDIR}/sweep-outcome.txt"
	[[ "$stderr" != *"changed while the sweep changed nothing"* ]]
	[ "$(_proxy_settle_order)" = PSPSP ]
}

@test "a profile that leaves the Istio CR alone (istio_cr_patch {}): its apply and revert are no problem; an edit by something else during its apply, its pass or its revert is one, once" {
	_need_yaml
	_tun_stub
	local p=04-connection-pools want
	tun_sweep "$p"
	[ "$status" -eq 4 ] || { echo "$stderr"; false; }
	[ "$(<"${TDIR}/${p}/state/patch.json")" = "{}" ]
	! grep -q '^PROBLEM=' "${TDIR}/sweep-outcome.txt"
	[[ "$stderr" != *"Istio CR changed"* ]]
	# During its apply: the read after the apply finds it (the profile raised nothing).
	rm -rf "$TD" "$TUN_RES"
	_tun_stub
	TUN_FOREIGN_WHEN='* apply --server-side *' tun_sweep "$p"
	[ "$status" -eq 4 ]
	want="PROBLEM=the Istio CR changed while the sweep changed nothing, between its read before the apply of pass ${p} and its read after the apply of pass ${p}: ci-a (Istio CR generation 2 -> 3, IstioRevision generation 2 -> 3); likely: "
	grep -qF "$want" "${TDIR}/sweep-outcome.txt" || { cat "${TDIR}/sweep-outcome.txt"; false; }
	[ "$(grep -c '^PROBLEM=' "${TDIR}/sweep-outcome.txt")" -eq 1 ]
	# During its pass: 002 finds it before its revert; the read after the revert does not
	# report it again.
	rm -rf "$TD" "$TUN_RES"
	_tun_stub
	TUN_FOREIGN_WHEN=applied tun_sweep "$p"
	[ "$status" -eq 4 ]
	grep -qF "PROBLEM=the Istio CR changed during pass ${p}, after its apply settled and not by its profile: ci-a (Istio CR generation 2 -> 3, IstioRevision generation 2 -> 3)" "${TDIR}/sweep-outcome.txt" \
		|| { cat "${TDIR}/sweep-outcome.txt"; false; }
	[ "$(grep -c '^PROBLEM=' "${TDIR}/sweep-outcome.txt")" -eq 1 ]
	# During its revert (after 002 compared): the read after the revert finds it.
	rm -rf "$TD" "$TUN_RES"
	_tun_stub
	TUN_FOREIGN_WHEN='* delete --ignore-not-found -f *' tun_sweep "$p"
	[ "$status" -eq 4 ]
	grep -qF "PROBLEM=the Istio CR changed while the sweep changed nothing, between its read after the apply of pass ${p} and its read after the revert of pass ${p}: ci-a (Istio CR generation 2 -> 3, IstioRevision generation 2 -> 3)" "${TDIR}/sweep-outcome.txt" \
		|| { cat "${TDIR}/sweep-outcome.txt"; false; }
	[ "$(grep -c '^PROBLEM=' "${TDIR}/sweep-outcome.txt")" -eq 1 ]
}

@test "002 run again after a revert that stopped after its patch notes that it cannot check, instead of reporting its own patch as a foreign edit; a finding of the first run is kept, and the next apply clears both" {
	_need_yaml
	_tun_stub
	local st="${BATS_TEST_TMPDIR}/state"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/001-apply-profile.sh" \
		--profile "${ROOT}/tests/tuning/profiles/01-push-throttling.yaml" --contexts ci-a --state-dir "$st"
	assert_success
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/002-revert-profile.sh" --state-dir "$st"
	assert_success
	[ -s "$st/revert-started" ]
	[ ! -e "$st/istio-edited-during-pass" ]
	# As if that run had stopped after its patch, before it removed active-profile: again.
	echo 01-push-throttling > "$st/active-profile"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/002-revert-profile.sh" --state-dir "$st"
	assert_success
	[[ "$output$stderr" == *"note: a revert of this apply started before ("*") and may have patched the Istio CR already: no check that it was left alone during the pass (that run's finding, if any, stays in istio-edited-during-pass)"* ]] \
		|| { echo "$output$stderr"; false; }
	[[ "$stderr" != *"WARNING: the Istio CR changed during the pass"* ]]
	[ ! -e "$st/istio-edited-during-pass" ]
	# A first run that found an edit: its finding stays through the re-run.
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/001-apply-profile.sh" \
		--profile "${ROOT}/tests/tuning/profiles/01-push-throttling.yaml" --contexts ci-a --state-dir "$st"
	assert_success
	[ ! -e "$st/revert-started" ]
	echo 9 > "${TD}/gen"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/002-revert-profile.sh" --state-dir "$st"
	assert_success
	[[ "$stderr" == *"WARNING: the Istio CR changed during the pass of 01-push-throttling"* ]]
	[ -s "$st/istio-edited-during-pass" ]
	echo 01-push-throttling > "$st/active-profile"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/002-revert-profile.sh" --state-dir "$st"
	assert_success
	[ -s "$st/istio-edited-during-pass" ]
	# The next apply into this state dir starts afresh.
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/001-apply-profile.sh" \
		--profile "${ROOT}/tests/tuning/profiles/01-push-throttling.yaml" --contexts ci-a --state-dir "$st"
	assert_success
	[ ! -e "$st/revert-started" ] && [ ! -e "$st/istio-edited-during-pass" ]
}

# _kc_stub: a kubectl for the Istio version reads: the Istio CR as fake-istio-cr.sh; two
# istiod pods per member, whose /metrics name KC_PROXY (default "1.30.5:3"; a+b for more
# versions, as version:count) ; each /metrics read is counted in flight under KC_DIR
# (conc: how many were in flight as each started) and lasts 0.2 s, or with KC_BARRIER
# until a second read is in flight (at most 5 s).
_kc_stub() {
	export KC_DIR="${BATS_TEST_TMPDIR}/kc"
	mkdir -p "$KC_DIR/inflight"
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
*" get pods -l app=istiod "*) printf 'pod/istiod-a\npod/istiod-b\n' ;;
*"/proxy/metrics"*)
	: > "$KC_DIR/inflight/$$"
	ls "$KC_DIR/inflight" | wc -l | tr -d ' ' >> "$KC_DIR/conc"
	if [ -n "${KC_BARRIER:-}" ]; then
		i=0
		while [ "$(ls "$KC_DIR/inflight" | wc -l)" -lt 2 ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
	else
		sleep 0.2
	fi
	echo '# TYPE pilot_xds gauge'
	printf '%s\n' "${KC_PROXY:-1.30.5:3}" | tr '+' '\n' | while IFS=: read -r v n; do printf 'pilot_xds{version="%s"} %s\n' "$v" "$n"; done
	rm -f "$KC_DIR/inflight/$$" ;;
*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
}

@test "the end recheck names a --resume's reads by when it started, and the proxies by the read they came from (after a pass's settle), in the problem and the note" {
	_kc_stub
	PATH="${BIN}:${PATH}" run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		export ISTIO_VERSION=v1.30.5
		istio_version_resolve --resumed-at 2026-06-01T00:04:00Z ci-a 0 kubectl 2>/dev/null
		# Proxies on another version than istiod, read when this --resume started.
		export ISTIO_PROXY_VERSIONS="ci-a=1.29.0:3+1.30.5:7"
		export STUB_ISTIO_CR_GEN=4 STUB_ISTIO_REV_GEN=4
		IV_END=(); istio_version_recheck IV_END kubectl 2>/dev/null
		printf "%s\n" "${IV_END[@]}"'
	assert_success
	assert_output --partial "its Istio CR default (generation 2 when this --resume started at 2026-06-01T00:04:00Z, 4 at the end)"
	assert_output --partial "proxies on another Istio version than their istiod were connected when this --resume started at 2026-06-01T00:04:00Z (ci-a (istiod 1.30.5): 3 on 1.29.0; ISTIO_PROXY_VERSIONS)"
	refute_output --partial "at the start of this run (the --resume"
	# The proxies read again after a pass's settle (as tuning 003 does): the note names that read.
	KC_PROXY="1.29.0:3+1.30.5:7" PATH="${BIN}:${PATH}" run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		export ISTIO_VERSION=v1.30.5
		KC_PROXY=1.30.5:3 istio_version_resolve ci-a 0 kubectl 2>/dev/null
		echo "start: ${ISTIO_PROXY_VERSIONS}"
		istio_version_refresh --proxies-only "after the settle of pass 02-x" ci-a kubectl
		echo "refreshed: ${ISTIO_PROXY_VERSIONS}"
		IV_END=(); istio_version_recheck IV_END kubectl 2>/dev/null
		printf "%s\n" "${IV_END[@]}"'
	assert_success
	assert_line "start: ci-a=1.30.5:6"
	assert_line "refreshed: ci-a=1.30.5:14+1.29.0:6"
	assert_output --partial "proxies on another Istio version than their istiod were connected after the settle of pass 02-x (ci-a (istiod 1.30.5): 6 on 1.29.0; ISTIO_PROXY_VERSIONS)"
}

@test "the proxy reads run at most ISTIO_PROXY_READ_PARALLEL members at once, and one member's istiod pods one at a time" {
	_kc_stub
	PATH="${BIN}:${PATH}" run bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		ISTIO_PROXY_READ_PARALLEL=1 istio_proxy_versions ci-a,ci-b,ci-c kubectl'
	assert_success
	assert_output "ci-a=1.30.5:6,ci-b=1.30.5:6,ci-c=1.30.5:6"
	[ "$(wc -l < "$KC_DIR/conc")" -eq 6 ]
	[ "$(sort -n "$KC_DIR/conc" | tail -n 1)" -eq 1 ]
	# Three at once: the members' reads overlap, a member's two pods never do.
	: > "$KC_DIR/conc"
	KC_BARRIER=1 PATH="${BIN}:${PATH}" run bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		ISTIO_PROXY_READ_PARALLEL=3 istio_proxy_versions ci-a,ci-b,ci-c kubectl'
	assert_success
	assert_output "ci-a=1.30.5:6,ci-b=1.30.5:6,ci-c=1.30.5:6"
	local max
	max="$(sort -n "$KC_DIR/conc" | tail -n 1)"
	[ "$max" -ge 2 ] && [ "$max" -le 3 ]
}

@test "an Istio version check interrupted by Ctrl-C (or a closed terminal) leaves nothing in TMPDIR; so does tuning 003's dry run stopped during its probe check" {
	[[ "$(bash -c 'trap "echo t" INT; kill -INT $$; echo n' 2>/dev/null)" == t* ]] || skip "SIGINT is ignored here"
	[[ "$(bash -c 'trap "echo t" HUP; kill -HUP $$; echo n' 2>/dev/null)" == t* ]] || skip "SIGHUP is ignored here (nohup)"
	local sig st t
	# The stub's first Istio CR read sends <sig> to its process group (the version check's
	# job, as a terminal does), once.
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
*" get istios.sailoperator.io default "*)
	if [ ! -e "$KC_SIG_SENT" ]; then : > "$KC_SIG_SENT"; kill -s "$KC_SIG" 0; sleep 1; fi ;;
esac
exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@"
STUB
	chmod +x "${BIN}/kubectl"
	for sig in INT:130 HUP:129; do
		IFS=: read -r sig st <<<"$sig"
		t="${BATS_TEST_TMPDIR}/tmp-${sig}"
		mkdir -p "$t"
		KC_SIG="$sig" KC_SIG_SENT="${BATS_TEST_TMPDIR}/sent-${sig}" TMPDIR="$t" PATH="${BIN}:${PATH}" \
			run bash -c 'set -m; bash -c "
				source \"\$ROOT/tests/lib/common.sh\"; source \"\$ROOT/tests/lib/preamble.sh\"
				export ISTIO_VERSION=v1.30.5
				istio_version_resolve ci-a 0 kubectl
				: > \"\$KC_SIG_SENT.resolved\"" & wait "$!"'
		[ -e "${BATS_TEST_TMPDIR}/sent-${sig}" ]
		[ "$status" -eq "$st" ] || { echo "${sig}: status ${status}: ${output}"; false; }
		[ ! -e "${BATS_TEST_TMPDIR}/sent-${sig}.resolved" ]
		run ls -A "$t"
		assert_output ""
	done
	# tuning 003 --dry-run: a SIGTERM while a probe checks its arguments (the probe's bash
	# sends it to 003) ends 003 once that probe returns, and its EXIT trap removes the
	# check's dir.
	_need_yaml
	local realbash
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
