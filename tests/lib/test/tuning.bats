#!/usr/bin/env bats
# The tuning suite's steps (tests/tuning/001-003, 005, 006), through the real scripts (PL33)
# against a stub kubectl, no cluster:
# - the profile marker (R6) that labels the members' results with the profile: tuning.py writes
#   and reads it, 002-revert-profile.sh deletes it last, and 005-cleanup.sh restores each
#   member's Istio CR from it and, with a hub context, removes an Argo CD pause no record names;
# - the refusals of a member or a profile that would share a file with another;
# - the check that nothing but a profile edited the Istio CR during a pass: 001 records the
#   generations once its apply settled, 002 compares them before its revert, and 003 makes each
#   finding one problem naming the pass.
# The report (004) is in tuning-compare.bats. The tests that load a profile skip without PyYAML.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/tests/lib/platform.sh"  # PLATFORM_TUNING_LABEL, PLATFORM_TUNING_JQ

HELPER="${ROOT}/tests/tuning/lib/tuning.py"
REVERT="${ROOT}/tests/tuning/002-revert-profile.sh"
CLEANUP="${ROOT}/tests/tuning/005-cleanup.sh"
PAUSE="${ROOT}/tests/tuning/006-gitops-pause.sh"
SWEEP="${ROOT}/tests/tuning/003-run-tuning-sweep.sh"

setup() {
	T="$BATS_TEST_TMPDIR"
	STUB_DIR="${T}/stub"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: one member per --context. Its Istio CR is live.<ctx>.json, which a merge patch
	# changes (null deletes) unless STUB_PATCH_NOOP names the context; the Sail operator reads as
	# reconciled and istiod as rolled out. Its markers are markers.<ctx>.json (an empty list when
	# absent; STUB_LIST_FAIL names a context whose list fails). A delete -f of a marker file
	# removes it, unless STUB_MARKER_STAYS names the context. The hub's Argo CD Applications are
	# apps.json and its AppProject default project.json, which a merge patch replaces (logged as
	# "project-patch"). Anything else fails.
	cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
ctx="" f=""
for a in "$@"; do
	case "$a" in
	--context=*) ctx="${a#--context=}" ;;
	--patch-file=*) f="${a#--patch-file=}" ;;
	esac
done
on() { [[ " ${1//,/ } " == *" ${ctx} "* ]]; }
args=" $* "
case "$args" in
*" patch istio.sailoperator.io default --type=merge "*)
	echo "patch ${ctx} $(jq -c . "$f")" >>"$STUB_LOG"
	on "${STUB_PATCH_NOOP:-}" && exit 0
	jq --argjson patch "$(cat "$f")" 'def mp($p): if ($p | type) == "object" then reduce ($p | keys_unsorted[]) as $k
		((if type == "object" then . else {} end); if $p[$k] == null then del(.[$k]) else .[$k] = (.[$k] | mp($p[$k])) end)
		else $p end; mp($patch)' "${STUB_DIR}/live.${ctx}.json" >"${STUB_DIR}/live.tmp" &&
		mv "${STUB_DIR}/live.tmp" "${STUB_DIR}/live.${ctx}.json" ;;
*" get istio.sailoperator.io default -o jsonpath="*) echo "2 2 True default" ;;
*" get istiorevision.sailoperator.io default -o jsonpath="*) echo "1 1 True" ;;
*" rollout status deployment/istiod "*) echo 'deployment "istiod" successfully rolled out' ;;
*" get istio.sailoperator.io default -o json "*) cat "${STUB_DIR}/live.${ctx}.json" ;;
*" get configmaps -A -l istio-scale-tests/tuning-profile -o json "*)
	if on "${STUB_LIST_FAIL:-}"; then
		echo "error: the server is unreachable" >&2
		exit 1
	fi
	cat "${STUB_DIR}/markers.${ctx}.json" 2>/dev/null || echo '{"kind":"List","items":[]}' ;;
*" delete configmaps "*" --ignore-not-found "*) ;;
*" delete --ignore-not-found -f "*/marker-*) on "${STUB_MARKER_STAYS:-}" || touch "${STUB_DIR}/gone.${ctx}" ;;
*" get --ignore-not-found -f "*/marker-*" -o name "*)
	[[ -e "${STUB_DIR}/gone.${ctx}" ]] || echo "configmap/tuning-profile-02-xds-cache-off" ;;
*" -A -l istio-scale-tests/tuning-profile --ignore-not-found "*) ;;
*" get applications.argoproj.io -o json "*) cat "${STUB_DIR}/apps.json" ;;
*" get appprojects.argoproj.io default -o json "*) cat "${STUB_DIR}/project.json" ;;
*" patch appprojects.argoproj.io default --type=merge "*)
	echo "project-patch ${ctx} $(jq -c . "$f")" >>"$STUB_LOG"
	jq --slurpfile p "$f" '.spec.syncWindows = $p[0].spec.syncWindows' "${STUB_DIR}/project.json" >"${STUB_DIR}/project.tmp" &&
		mv "${STUB_DIR}/project.tmp" "${STUB_DIR}/project.json" ;;
*)
	echo "stub kubectl: unexpected call: $*" >&2
	exit 1 ;;
esac
EOF
	chmod +x "${STUB_DIR}/bin/kubectl"
	export PATH="${STUB_DIR}/bin:${PATH}"
	echo "A profile." >"${T}/desc"
}

# mk_marker <profile> <applied-at> <revert patch JSON> <out>: a marker as 001-apply-profile.sh
# writes it.
mk_marker() {
	printf '%s\n' "$3" >"${T}/revert.json"
	python3 -I "$HELPER" marker "$1" "${T}/desc" "${T}/revert.json" "$2" "$4"
}

# markers_on <ctx> <marker.json>...: the ConfigMap list the stub answers on <ctx>.
markers_on() {
	local ctx="$1"
	shift
	jq -s '{kind: "List", items: .}' "$@" >"${STUB_DIR}/markers.${ctx}.json"
}

# state_dir: a state dir of 02-xds-cache-off applied to ctx-a and ctx-b, as 001-apply-profile.sh
# leaves it (SD), with each member's Istio CR as the profile left it and a fresh stub log.
state_dir() {
	local ctx
	SD="${T}/state"
	rm -rf "$SD" "${STUB_DIR}"/gone.*
	mkdir -p "$SD"
	: >"$STUB_LOG"
	echo "ctx-a,ctx-b" >"${SD}/contexts"
	echo "02-xds-cache-off" >"${SD}/active-profile"
	: >"${SD}/applied-resources.yaml"
	for ctx in ctx-a ctx-b; do
		echo '{"spec":{"values":{"pilot":{"env":{"PILOT_ENABLE_CDS_CACHE":null}}}}}' >"${SD}/istio-revert-${ctx}.json"
		echo '{"spec":{"values":{"pilot":{"env":{"PILOT_ENABLE_CDS_CACHE":"false","PILOT_PUSH_THROTTLE":"100"}}}}}' \
			>"${STUB_DIR}/live.${ctx}.json"
		python3 -I "$HELPER" marker 02-xds-cache-off "${T}/desc" "${SD}/istio-revert-${ctx}.json" \
			2026-10-19T10:00:00Z "${SD}/marker-${ctx}.json"
	done
}

# gen_stub: skips without PyYAML (001 loads the profile); else a kubectl (in BIN, first on PATH
# in step and sweep) holding a stateful Istio CR (files in TD): cr.json (its spec) and gen (its
# generation, and its IstioRevision's; 2 at first). A merge patch applies (RFC 7386) and raises
# gen by 1; a profile's patch marks it applied, its revert patch (istio-revert-*) unmarks it.
# Each istiod pod list logs the ISTIO_GENERATIONS its caller was handed to gens-seen; with
# TUN_EDIT set, the first one while a profile is applied is an edit by someone else (gen + 1;
# TUN_EDIT=spec also sets a key no profile sets; TUN_EDIT=baseline: the first one, the baseline
# pass's; TUN_EDIT=json: the first read of the Istio CR as JSON instead, the sweep's before its
# first pass). TUN_GEN_FAIL: the Istio version reader's reads fail. A profile's resources apply
# and delete (res: they exist); the members hold no tuning profile objects. Any other call fails
# (the probes then fail: PROBE_FAILED).
gen_stub() {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed (tuning lib)"
	EK="${T}/kubeconfig"
	: >"$EK"
	BIN="${T}/bin"
	mkdir -p "$BIN"
	export ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 METRICS_READY_TIMEOUT=0
	export TD="${T}/tun" ST="${T}/state"
	mkdir -p "$TD"
	cat >"${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$TD"
[ -f "$d/gen" ] || echo 2 > "$d/gen"
[ -f "$d/cr.json" ] || echo '{"spec":{"version":"v1.30-latest","values":{}}}' > "$d/cr.json"
case "$*" in *" get pods -l app=istiod"*)
	echo "${ISTIO_GENERATIONS:-none}" >> "$d/gens-seen"
	if [ -n "${TUN_EDIT:-}" ] && [ "$TUN_EDIT" != json ] && { [ -f "$d/applied" ] || [ "$TUN_EDIT" = baseline ]; } && [ ! -f "$d/edited" ]; then
		: > "$d/edited"
		echo $(( $(cat "$d/gen") + 1 )) > "$d/gen"
		[ "$TUN_EDIT" != spec ] || { jq -c '.spec.values.global.logging.level = "default:debug"' "$d/cr.json" > "$d/cr.new" && mv "$d/cr.new" "$d/cr.json"; }
	fi ;;
esac
g="$(cat "$d/gen")"
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	[ -z "${TUN_GEN_FAIL:-}" ] || { echo 'error: the server is currently unable to handle the request' >&2; exit 1; }
	STUB_ISTIO_CR_GEN="$g" STUB_ISTIO_REV_GEN="$g" exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" patch istio.sailoperator.io default --type=merge --patch-file="*)
	args="$*"; f="${args##*--patch-file=}"; f="${f%% *}"
	jq --slurpfile p "$f" 'def mp($q): if ($q | type) == "object" then reduce ($q | keys_unsorted[]) as $k ((if type == "object" then . else {} end); if $q[$k] == null then del(.[$k]) else .[$k] = (.[$k] | mp($q[$k])) end) else $q end; mp($p[0])' "$d/cr.json" > "$d/cr.new" && mv "$d/cr.new" "$d/cr.json"
	case "$f" in *istio-revert-*) rm -f "$d/applied" ;; *) : > "$d/applied" ;; esac
	echo $((g + 1)) > "$d/gen" ;;
*" get istio.sailoperator.io default -o jsonpath={.metadata.generation}"*) echo "$g $g True default" ;;
*" get istio.sailoperator.io default -o jsonpath={.status.activeRevisionName}"*) echo default ;;
*" get istio.sailoperator.io default -o json")
	if [ "${TUN_EDIT:-}" = json ] && [ ! -f "$d/edited" ]; then : > "$d/edited"; g=$((g + 1)); echo "$g" > "$d/gen"; fi
	jq -c --argjson g "$g" '. + {metadata: {name: "default", generation: $g}}' "$d/cr.json" ;;
*" get istiorevision.sailoperator.io default -o jsonpath="*) echo "$g $g True" ;;
*" rollout status "*) exit 0 ;;
*" -n istio-system get deployment istiod -o json"*)
	jq -c '{spec: {template: {spec: {containers: [{name: "discovery", env: ((.spec.values.pilot.env // {}) | to_entries | map({name: .key, value: (.value | tostring)}))}]}}}}' "$d/cr.json" ;;
*" apply --server-side "*) : > "$d/res" ;;
*" delete --ignore-not-found -f "*) rm -f "$d/res" ;;
*" get --ignore-not-found -f "*) : ;;
*" tuning-connection-pool -o name"*|*" -n istio-system get ConfigMap tuning-profile-"*) [ -f "$d/res" ] ;;
*" -l istio-scale-tests/tuning-profile"*) echo '{"kind":"List","items":[]}' ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
}

# step <script> <args...>: a tuning step (001 or 002) on ci-a with gen_stub's kubectl.
step() {
	local s="$1"
	shift
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/${s}" "$@"
}

# apply: 001 with 01-push-throttling into ST. revert: 002 on ST.
apply() { step 001-apply-profile.sh --profile "${ROOT}/tests/tuning/profiles/01-push-throttling.yaml" --contexts ci-a --state-dir "$ST"; }
revert() { step 002-revert-profile.sh --state-dir "$ST"; }

# sweep [profiles]: tuning 003 over the churn suite on ci-a with gen_stub's kubectl, from a fresh
# Istio CR: the baseline, then 01-push-throttling and 02-xds-cache-off (or those profiles), no
# setup and no Argo CD pause. Sets TDIR and OUT (its outcome).
sweep() {
	rm -rf "$TD" "${T}/tres"
	mkdir -p "$TD"
	[[ -z "${TUN_RES:-}" ]] || : >"${TD}/res"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "$SWEEP" \
		--suite churn --contexts ci-a --no-gitops-pause --skip-setup --keep-workloads \
		--profiles "${1:-01-push-throttling,02-xds-cache-off}" --settle 0 --output-dir "${T}/tres"
	TDIR="$(find "${T}/tres" -maxdepth 1 -name 'sweep-*' -type d)"
	OUT="${TDIR}/sweep-outcome.txt"
}

@test "tuning.py marker and markers (R6): a marker names its profile under the label the platform record reads and carries the member's revert patch; markers lists them newest first, with no patch for a labelled ConfigMap that is no marker or a patch that does not parse" {
	local out="${T}/out"
	mkdir -p "$out"
	mk_marker 02-xds-cache-off 2026-10-19T10:00:00Z '{"spec":{"values":{"pilot":{"env":{"A":null,"B":"1"}}}}}' "${T}/m.json"
	run jq -r '[.metadata.namespace, .metadata.name, .data.profile, .data["applied-at"]] | join("|")' "${T}/m.json"
	assert_output "istio-system|tuning-profile-02-xds-cache-off|02-xds-cache-off|2026-10-19T10:00:00Z"
	run jq -c '.data["istio-revert.json"] | fromjson' "${T}/m.json"
	assert_output '{"spec":{"values":{"pilot":{"env":{"A":null,"B":"1"}}}}}'
	# The platform record's read names the marker as the profile's object.
	run jq -r --arg label "$PLATFORM_TUNING_LABEL" "$PLATFORM_TUNING_JQ" < <(jq '{items: [.]}' "${T}/m.json")
	assert_output "02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off"
	# resources reads it without PyYAML (002-revert-profile.sh's dry-run, 001's apply).
	run python3 -I "$HELPER" resources "${T}/m.json"
	assert_output "ConfigMap tuning-profile-02-xds-cache-off istio-system"
	# markers: newest first; at one applied-at, by namespace and name, reversed; a ConfigMap with
	# no applied-at (hand-made) last; "-" where there is no patch to restore from.
	mk_marker 01-push-throttling 2026-10-19T09:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"100"}}}}}' "${T}/m1.json"
	mk_marker 02-xds-cache-off 2026-10-19T10:00:00Z '{}' "${T}/m2.json"
	jq '.data["istio-revert.json"] = "{not json"' "${T}/m2.json" | jq '.metadata.name = "tuning-profile-03-x"' >"${T}/m3.json"
	echo '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"hand-made","namespace":"default","labels":{"istio-scale-tests/tuning-profile":"09-x"}}}' >"${T}/m4.json"
	jq -s '{items: .}' "${T}/m1.json" "${T}/m4.json" "${T}/m2.json" "${T}/m3.json" >"${T}/list.json"
	run python3 -I "$HELPER" markers "${T}/list.json" "$out"
	assert_success
	assert_output "istio-system tuning-profile-03-x 02-xds-cache-off -
istio-system tuning-profile-02-xds-cache-off 02-xds-cache-off ${out}/2.json
istio-system tuning-profile-01-push-throttling 01-push-throttling ${out}/0.json
default hand-made 09-x -"
	[ "$(jq -c . "${out}/0.json")" = '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"100"}}}}}' ]
	[ "$(jq -c . "${out}/2.json")" = '{}' ]
	echo '{"kind":"List","items":[]}' >"${T}/empty.json"
	run python3 -I "$HELPER" markers "${T}/empty.json" "$out"
	assert_success
	assert_output ""
}

@test "tuning.py load (R6): a profile name that cannot label its objects, name its marker or be told from the record's own values is refused; every shipped profile loads" {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 without PyYAML"
	local p
	mkdir -p "${T}/out"
	# Not a label value or a name (49 characters is one too many); none and mixed are the
	# platform record's, baseline tuning 003's pass without a profile.
	for p in Bad_Name trail- "$(printf 'a%.0s' {1..49})" none mixed baseline; do
		cp "${ROOT}/tests/tuning/profiles/02-xds-cache-off.yaml" "${T}/${p}.yaml"
		run python3 -I "$HELPER" load "${T}/${p}.yaml" "${T}/out"
		assert_failure
		assert_output --partial "a profile's name ('${p}') must"
	done
	p="$(printf 'a%.0s' {1..48})"
	cp "${ROOT}/tests/tuning/profiles/02-xds-cache-off.yaml" "${T}/${p}.yaml"
	run python3 -I "$HELPER" load "${T}/${p}.yaml" "${T}/out"
	assert_success
	for p in "${ROOT}"/tests/tuning/profiles/*.yaml; do
		rm -rf "${T}/out" && mkdir -p "${T}/out"
		run python3 -I "$HELPER" load "$p" "${T}/out"
		assert_success
	done
}

@test "002-revert-profile (R6): deletes each member's marker last, once the revert checks out; a failed check or a marker that stays exits 3 and keeps the profile active; --dry-run names the markers and touches nothing" {
	local last_get first_del
	state_dir
	run "$REVERT" --state-dir "$SD"
	assert_success
	assert_output --partial "PASS  ctx-a: profile marker removed"
	assert_output --partial "PASS  ctx-b: profile marker removed"
	[ ! -e "${SD}/active-profile" ]
	# After the post-revert check's last read of the Istio CR.
	last_get="$(grep -n " get istio.sailoperator.io default -o json" "$STUB_LOG" | tail -1 | cut -d: -f1)"
	first_del="$(grep -n " delete --ignore-not-found -f .*/marker-" "$STUB_LOG" | head -1 | cut -d: -f1)"
	[ "$first_del" -gt "$last_get" ]
	# A member whose Istio CR is not back: no marker is touched.
	state_dir
	STUB_PATCH_NOOP=ctx-b run "$REVERT" --state-dir "$SD"
	[ "$status" -eq 3 ]
	! grep -q "/marker-" "$STUB_LOG" || false
	[ -e "${SD}/active-profile" ]
	# A marker still there after its delete.
	state_dir
	STUB_MARKER_STAYS=ctx-a run "$REVERT" --state-dir "$SD"
	[ "$status" -eq 3 ]
	assert_output --partial "FAIL  ctx-a: profile marker still present: configmap/tuning-profile-02-xds-cache-off"
	assert_output --partial "PASS  ctx-b: profile marker removed"
	[ -e "${SD}/active-profile" ]
	state_dir
	run "$REVERT" --state-dir "$SD" --dry-run
	assert_success
	assert_output --partial "ctx-a: ConfigMap istio-system/tuning-profile-02-xds-cache-off"
	assert_output --partial "ctx-b: ConfigMap istio-system/tuning-profile-02-xds-cache-off"
	[ ! -s "$STUB_LOG" ]
}

@test "005-cleanup (R6): restores each member's Istio CR from its markers, newest first, and deletes each once its restore checks out; a restore that does not, a ConfigMap with no patch or a list that fails keeps the markers and exits 1; without a hub it never reports Argo CD clean; --dry-run touches nothing, without python3 too" {
	local d1 d2
	mk_marker 01-push-throttling 2026-10-19T09:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"100"}}}}}' "${T}/m1.json"
	mk_marker 02-xds-cache-off 2026-10-19T10:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_ENABLE_CDS_CACHE":null}}}}}' "${T}/m2.json"
	mk_marker 04-connection-pools 2026-10-19T10:00:00Z '{}' "${T}/m4.json"
	markers_on ctx-a "${T}/m1.json" "${T}/m2.json"
	markers_on ctx-b "${T}/m4.json"
	echo '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"10","PILOT_ENABLE_CDS_CACHE":"false"}}}}}' >"${STUB_DIR}/live.ctx-a.json"
	run --separate-stderr "$CLEANUP" --contexts ctx-a,ctx-b,ctx-c --results-dir "${T}/results"
	assert_success
	# U6-B1: markers restored, and no pause recorded or hub given: Argo CD is not known to be
	# resumed, and the cleanup says what to run.
	[[ "$stderr" == *"if it paused Argo CD, its deny sync window is still on the hub"*"--gitops-context <hub>"* ]]
	refute_line "=== Cleanup complete ==="
	# ctx-a: 02's patch, then 01's; its Istio CR is back to before both, and 02's marker goes first.
	run grep '^patch ' "$STUB_LOG"
	assert_output 'patch ctx-a {"spec":{"values":{"pilot":{"env":{"PILOT_ENABLE_CDS_CACHE":null}}}}}
patch ctx-a {"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"100"}}}}}'
	[ "$(jq -c .spec.values.pilot.env "${STUB_DIR}/live.ctx-a.json")" = '{"PILOT_PUSH_THROTTLE":"100"}' ]
	d2="$(grep -n -- "--context=ctx-a -n istio-system delete configmaps tuning-profile-02-xds-cache-off --ignore-not-found" "$STUB_LOG" | cut -d: -f1)"
	d1="$(grep -n -- "--context=ctx-a -n istio-system delete configmaps tuning-profile-01-push-throttling --ignore-not-found" "$STUB_LOG" | cut -d: -f1)"
	[ -n "$d2" ] && [ -n "$d1" ] && [ "$d2" -lt "$d1" ]
	# ctx-b: a profile without an Istio CR change has nothing to patch; its marker goes.
	grep -q -- "--context=ctx-b -n istio-system delete configmaps tuning-profile-04-connection-pools --ignore-not-found" "$STUB_LOG"
	! grep -q '^patch ctx-b' "$STUB_LOG" || false
	# The sweep by label deletes the profile kinds only, never a marker.
	run grep -- " -A -l istio-scale-tests/tuning-profile --ignore-not-found" "$STUB_LOG"
	assert_success
	refute_output --partial configmaps
	# U7-S2: nothing restored, still no hub: a run stopped before its first profile leaves a pause
	# and no marker, so the hub is still not reported clean.
	echo '{"kind":"List","items":[]}' >"${STUB_DIR}/markers.ctx-a.json"
	echo '{"kind":"List","items":[]}' >"${STUB_DIR}/markers.ctx-b.json"
	run --separate-stderr "$CLEANUP" --contexts ctx-a,ctx-b,ctx-c --results-dir "${T}/results"
	assert_success
	assert_output --partial "pass --gitops-context <hub>"
	refute_line "=== Cleanup complete ==="
	# The newest marker does not check out: it stays, and the older one is not tried.
	: >"$STUB_LOG"
	markers_on ctx-a "${T}/m1.json" "${T}/m2.json"
	echo '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"10","PILOT_ENABLE_CDS_CACHE":"false"}}}}}' >"${STUB_DIR}/live.ctx-a.json"
	STUB_PATCH_NOOP=ctx-a run "$CLEANUP" --contexts ctx-a --results-dir "${T}/results"
	assert_failure
	assert_output --partial "FAIL  ctx-a: the Istio CR is not back to its state before 02-xds-cache-off"
	[ "$(grep -c '^patch ' "$STUB_LOG")" -eq 1 ]
	! grep -q " delete configmaps " "$STUB_LOG" || false
	# A labelled ConfigMap that is no marker: what to do by hand.
	: >"$STUB_LOG"
	echo '{"kind":"List","items":[{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"hand-made","namespace":"default","labels":{"istio-scale-tests/tuning-profile":"09-x"}}}]}' \
		>"${STUB_DIR}/markers.ctx-a.json"
	run "$CLEANUP" --contexts ctx-a --results-dir "${T}/results"
	assert_failure
	assert_output --partial "FAIL  ctx-a: default/hand-made holds no revert patch"
	assert_output --partial "tests/tuning/profiles/09-x.yaml"
	assert_output --partial "kubectl --context=ctx-a -n default delete configmaps hand-made"
	! grep -q " delete configmaps " "$STUB_LOG" || false
	# A member whose markers cannot be listed; the others are still restored.
	: >"$STUB_LOG"
	markers_on ctx-a "${T}/m2.json"
	STUB_LIST_FAIL=ctx-b run "$CLEANUP" --contexts ctx-a,ctx-b --results-dir "${T}/results"
	assert_failure
	assert_output --partial "FAIL  ctx-b: the profile markers could not be listed"
	grep -q -- "--context=ctx-a -n istio-system delete configmaps tuning-profile-02-xds-cache-off --ignore-not-found" "$STUB_LOG"
	# --dry-run calls nothing on the members and needs no working python3 (C10-B1).
	: >"$STUB_LOG"
	mkdir -p "${T}/nopy"
	printf '#!/bin/sh\nexit 127\n' >"${T}/nopy/python3"
	chmod +x "${T}/nopy/python3"
	PATH="${T}/nopy:${PATH}" run --separate-stderr "$CLEANUP" --contexts ctx-a,ctx-b --results-dir "${T}/results" --dry-run
	assert_success
	[ ! -s "$STUB_LOG" ]
}

@test "005-cleanup (U6-B1, U7-S3, U8-S4): with a hub context it removes the deny window a pause adds, recorded or not, and keeps every other window; one of its shape for other *-ossm Applications stays and fails the cleanup, named by the index --status shows it under; --resume without a record points at --clear" {
	local win team
	export TUNING_GITOPS_NAMESPACE=argocd
	mk_marker 02-xds-cache-off 2026-10-19T10:00:00Z '{}' "${T}/m2.json"
	markers_on ctx-a "${T}/m2.json"
	jq -n '{items: [
		{metadata: {name: "ctx-b-ossm", ownerReferences: [{kind: "ApplicationSet", name: "spoke-ossm"}]}, spec: {project: "default"}},
		{metadata: {name: "ctx-a-ossm", ownerReferences: [{kind: "ApplicationSet", name: "spoke-ossm"}]}, spec: {project: "default"}},
		{metadata: {name: "other-app"}, spec: {project: "default"}}]}' >"${STUB_DIR}/apps.json"
	win='{"kind":"deny","schedule":"* * * * *","duration":"1h","applications":["ctx-a-ossm","ctx-b-ossm"],"manualSync":true}'
	jq -n --argjson w "$win" '{metadata: {name: "default", resourceVersion: "7"}, spec: {syncWindows: [
		{kind: "allow", schedule: "0 22 * * *", duration: "1h", applications: ["*"]}, $w]}}' >"${STUB_DIR}/project.json"
	run --separate-stderr "$CLEANUP" --contexts ctx-a --results-dir "${T}/results" --gitops-context hub
	assert_success
	assert_line "=== Cleanup complete ==="
	[[ "$stderr" != *"warning: the markers restored above"* ]]
	# The patch keeps the other window and tests the project's resourceVersion.
	run grep '^project-patch ' "$STUB_LOG"
	assert_output 'project-patch hub {"metadata":{"resourceVersion":"7"},"spec":{"syncWindows":[{"kind":"allow","schedule":"0 22 * * *","duration":"1h","applications":["*"]}]}}'
	# Again, from TUNING_GITOPS_CONTEXT: the window is gone, so nothing to patch.
	: >"$STUB_LOG"
	TUNING_GITOPS_CONTEXT=hub run "$CLEANUP" --contexts ctx-a --results-dir "${T}/results"
	assert_success
	assert_line "=== Cleanup complete ==="
	! grep -q '^project-patch ' "$STUB_LOG" || false
	# Another team's window of the same recipe, for Applications not named as the ApplicationSet
	# names them (*-ossm), is not this tool's (U8-S4): it stays, and the cleanup passes.
	: >"$STUB_LOG"
	team='{"kind":"deny","schedule":"* * * * *","duration":"1h","applications":["other-app"],"manualSync":true}'
	jq -n --argjson w "$win" --argjson t "$team" '{metadata: {name: "default", resourceVersion: "8"}, spec: {syncWindows: [$w, $t]}}' \
		>"${STUB_DIR}/project.json"
	run --separate-stderr "$CLEANUP" --contexts ctx-a --results-dir "${T}/results" --gitops-context hub
	assert_success
	[[ "$stderr" != *"other-app"* ]]
	run grep '^project-patch ' "$STUB_LOG"
	assert_output "project-patch hub {\"metadata\":{\"resourceVersion\":\"8\"},\"spec\":{\"syncWindows\":[${team}]}}"
	# A window of this tool's shape for other *-ossm Applications (a pause from before ctx-b was
	# added) is not this tool's to remove by value (U7-S3): its own window goes, that one stays,
	# named on stderr with its index in the list the patch leaves, and the cleanup fails.
	: >"$STUB_LOG"
	jq -n --argjson w "$win" --argjson t "$team" '{metadata: {name: "default", resourceVersion: "9"}, spec: {syncWindows: [
		$w, $t, {kind: "deny", schedule: "* * * * *", duration: "1h", applications: ["ctx-a-ossm"], manualSync: true}]}}' >"${STUB_DIR}/project.json"
	run --separate-stderr "$CLEANUP" --contexts ctx-a --results-dir "${T}/results" --gitops-context hub
	assert_failure
	[[ "$stderr" == *"for other Applications (ctx-a-ossm; index 1 in its sync windows)"* ]]
	[[ "$stderr" != *"other-app"* ]]
	run grep '^project-patch ' "$STUB_LOG"
	assert_output "project-patch hub {\"metadata\":{\"resourceVersion\":\"9\"},\"spec\":{\"syncWindows\":[${team},{\"kind\":\"deny\",\"schedule\":\"* * * * *\",\"duration\":\"1h\",\"applications\":[\"ctx-a-ossm\"],\"manualSync\":true}]}}"
	# --status shows the window under that index whole, as a hand removal's JSON patch tests it
	# (U9-S5), and marks the stale one only: the other team's has the same shape.
	run "$PAUSE" --gitops-context hub --status
	assert_success
	assert_line --partial "  1: a stale pause of this tool's"
	refute_line --partial "  0: a stale pause"
	[ "$(sed -n 's/^     //p' <<<"$output" | jq -cS .)" = "$(jq -cS '.spec.syncWindows[1]' "${STUB_DIR}/project.json")" ]
	# --dry-run touches nothing; one action at a time; --resume without its pause record points
	# at --clear (U10-N3).
	: >"$STUB_LOG"
	run "$CLEANUP" --contexts ctx-a --results-dir "${T}/results" --gitops-context hub --dry-run
	assert_success
	run "$PAUSE" --gitops-context hub --clear --dry-run
	assert_success
	[ ! -s "$STUB_LOG" ]
	run "$PAUSE" --gitops-context hub --clear --status
	assert_failure
	assert_output --partial "use only one of"
	run "$PAUSE" --gitops-context hub --resume --state-file "${T}/no-pause-record.json"
	assert_failure
	assert_output --partial "is removed with --clear"
}

@test "a member or a profile that would share a file is refused: ctx_keys_distinct on a context listed twice or two with one state file name; tuning 003 on a profile listed twice (also as <name>.yaml), with and without --dry-run, before any kubectl call or result dir" {
	local dry
	local -a args
	source "${ROOT}/tests/tuning/lib/tuning.sh"
	run ctx_keys_distinct ctx-a ctx-b team/a team.a
	assert_success
	run ctx_keys_distinct ctx-a ctx-b ctx-a
	assert_failure
	assert_output --partial "context ctx-a is listed twice"
	run ctx_keys_distinct team/a team_a
	assert_failure
	assert_output --partial "contexts team/a and team_a have one state file name (team_a"
	: >"${T}/kubeconfig"
	for dry in 1 0; do
		args=()
		if ((dry)); then args=(--dry-run); fi
		KUBECONFIG="${T}/kubeconfig" run --separate-stderr "$SWEEP" --suite churn --contexts ci-a --no-gitops-pause \
			--output-dir "${T}/tres" --profiles 01-push-throttling,02-xds-cache-off,01-push-throttling.yaml ${args[@]+"${args[@]}"}
		[ "$status" -eq 1 ] || { echo "dry=${dry} status ${status}: ${stderr}"; false; }
		[[ "$stderr" == *"profile listed twice in --profiles: 01-push-throttling "* ]] || { echo "dry=${dry}: ${stderr}"; false; }
	done
	[ ! -s "$STUB_LOG" ]
	[ ! -e "${T}/tres" ]
	# Each profile once still passes the parser.
	KUBECONFIG="${T}/kubeconfig" run --separate-stderr "$SWEEP" --suite churn --contexts ci-a --no-gitops-pause \
		--output-dir "${T}/tres" --profiles 01-push-throttling,02-xds-cache-off --dry-run
	assert_success
}

@test "001 records each member's Istio CR generations once its apply settled (unknown, with one warning, when unreadable); 002 warns when they moved and writes istio-edited-during-pass; a re-run of a revert that started keeps that finding; the next apply clears it" {
	gen_stub
	apply
	assert_success
	[ "$(<"$ST/istio-generations-applied")" = ci-a=3/3 ]
	[[ "$stderr" != *"could not record"* ]]
	revert
	assert_success
	[[ "$stderr" != *"WARNING"* ]]
	[ ! -e "$ST/istio-edited-during-pass" ]
	# Someone else's edit during the pass.
	apply
	echo 9 >"${TD}/gen"
	revert
	assert_success
	[[ "$stderr" == *"WARNING: the Istio CR changed during the pass of 01-push-throttling, not by the profile: ci-a (5/5 -> 9/9)"* ]]
	[ "$(<"$ST/istio-edited-during-pass")" = "ci-a (5/5 -> 9/9)" ]
	# As if that revert had stopped after its patch: run again, its own patch is no edit.
	echo 01-push-throttling >"$ST/active-profile"
	revert
	assert_success
	[[ "$stderr" != *"WARNING"* ]]
	[ "$(<"$ST/istio-edited-during-pass")" = "ci-a (5/5 -> 9/9)" ]
	apply
	[ ! -e "$ST/istio-edited-during-pass" ]
	[ ! -e "$ST/revert-started" ]
	# Generations it cannot read: unknown, one warning.
	rm -rf "$ST" "$TD"
	mkdir -p "$TD"
	TUN_GEN_FAIL=1 apply
	assert_success
	[ "$(<"$ST/istio-generations-applied")" = ci-a=unknown/unknown ]
	[ "$(grep -c "^warn: could not record every member's Istio CR generations after the apply settled (ci-a=unknown/unknown)" <<<"$stderr")" -eq 1 ]
}

@test "tuning 003: an edit of the Istio CR during a pass is one problem naming the pass, the baseline pass too, which no apply brackets; the profiles' own patches are none; an edit that stays to the end is the spec problem; when no apply changed anything, the end compares the generations" {
	gen_stub
	# An edit during the baseline pass: the one problem. The probes fail (the stub has no istiod
	# pod): exit 4 for that reason too.
	TUN_EDIT=baseline sweep
	[ "$status" -eq 4 ] || { echo "$stderr"; false; }
	[ "$(grep -c '^PROBLEM=' "$OUT")" -eq 1 ] || { cat "$OUT"; false; }
	grep -qxF "PROBLEM=pass baseline: the Istio CR changed during the pass: ci-a (2/2 -> 3/3); its probes may have measured another configuration" "$OUT" \
		|| { cat "$OUT"; false; }
	# Each pass's probes were handed the generations it ran on: the baseline's before the edit,
	# each profile's after its apply.
	run sort -u "${TD}/gens-seen"
	assert_output $'ci-a=2/2\nci-a=4/4\nci-a=6/6'
	cmp "${TDIR}/istio-spec/start-ci-a.json" "${TDIR}/istio-spec/end-ci-a.json"
	# An edit during a profile's pass that sets a key no profile sets: that pass's problem, and the
	# spec problem at the end, since no revert undoes it.
	TUN_EDIT=spec sweep
	[ "$status" -eq 4 ]
	[ "$(grep -c '^PROBLEM=' "$OUT")" -eq 2 ] || { cat "$OUT"; false; }
	grep -qF "PROBLEM=pass 01-push-throttling: the Istio CR changed during the pass, after its apply settled and not by its profile: ci-a (3/3 -> 4/4)" "$OUT" \
		|| { cat "$OUT"; false; }
	grep -q "^PROBLEM=ci-a's Istio CR spec after the last revert differs from the sweep's start .*: values.global.logging.level; " "$OUT"
	# 04-connection-pools' DestinationRule already exists: 001 refuses before it changes anything,
	# and an edit before the first pass is found at the end.
	TUN_EDIT=json TUN_RES=1 sweep 04-connection-pools
	[ "$status" -eq 4 ]
	[ -f "${TDIR}/04-connection-pools/SETUP_FAILED" ]
	grep -qF "PROBLEM=the Istio CR or its active IstioRevision on ci-a changed during the sweep (generations 2/2 -> 3/3)" "$OUT" \
		|| { cat "$OUT"; false; }
}
