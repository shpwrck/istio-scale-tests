#!/usr/bin/env bats
# The tuning profiles' marker (R6): tests/tuning/lib/tuning.py writes and reads it,
# 002-revert-profile.sh deletes it last, and 005-cleanup.sh restores each member's Istio CR
# from it and, with a hub context, removes an Argo CD pause no record names (006 --clear), all
# against a stub kubectl. No cluster and no PyYAML needed (the one test that loads a profile
# skips without it).

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/tests/lib/platform.sh"  # PLATFORM_TUNING_LABEL, PLATFORM_TUNING_JQ

HELPER="${ROOT}/tests/tuning/lib/tuning.py"
REVERT="${ROOT}/tests/tuning/002-revert-profile.sh"
CLEANUP="${ROOT}/tests/tuning/005-cleanup.sh"

setup() {
	T="$BATS_TEST_TMPDIR"
	STUB_DIR="${T}/stub"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: one member per --context. Its Istio CR is live.<ctx>.json, which a merge patch
	# changes (null deletes) unless STUB_PATCH_NOOP names the context; the Sail operator reads as
	# reconciled (never on a context STUB_NO_RECONCILE names) and istiod as rolled out. Its
	# markers are markers.<ctx>.json (an
	# empty list when absent; STUB_LIST_FAIL names a context whose list fails). A delete -f of
	# a marker file removes it, unless STUB_MARKER_STAYS names the context. The hub's Argo CD
	# Applications are apps.json and its AppProject default project.json, which a merge patch
	# replaces (logged as "project-patch"). Anything else fails.
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
*" get istio.sailoperator.io default -o jsonpath="*)
	if on "${STUB_NO_RECONCILE:-}"; then echo "3 2 False default"; else echo "2 2 True default"; fi ;;
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

# state_dir [<ctx>...]: a state dir of 02-xds-cache-off applied to those members (ctx-a and ctx-b
# unless named), as 001-apply-profile.sh leaves it (SD), with each member's Istio CR as the
# profile left it and a fresh stub log.
state_dir() {
	local ctx ctxs=("$@")
	((${#ctxs[@]})) || ctxs=(ctx-a ctx-b)
	SD="${T}/state"
	rm -rf "$SD" "${STUB_DIR}"/gone.*
	mkdir -p "$SD"
	: >"$STUB_LOG"
	(IFS=,; echo "${ctxs[*]}") >"${SD}/contexts"
	echo "02-xds-cache-off" >"${SD}/active-profile"
	: >"${SD}/applied-resources.yaml"
	for ctx in "${ctxs[@]}"; do
		echo '{"spec":{"values":{"pilot":{"env":{"PILOT_ENABLE_CDS_CACHE":null}}}}}' >"${SD}/istio-revert-${ctx}.json"
		echo '{"spec":{"values":{"pilot":{"env":{"PILOT_ENABLE_CDS_CACHE":"false","PILOT_PUSH_THROTTLE":"100"}}}}}' \
			>"${STUB_DIR}/live.${ctx}.json"
		python3 -I "$HELPER" marker 02-xds-cache-off "${T}/desc" "${SD}/istio-revert-${ctx}.json" \
			2026-10-19T10:00:00Z "${SD}/marker-${ctx}.json"
	done
}

@test "tuning.py marker (R6): names the profile, is labelled with it, and carries the member's revert patch; the platform record reads it as the profile's" {
	printf 'Disable the caches.\n  Two lines.\n' >"${T}/desc"
	mk_marker 02-xds-cache-off 2026-10-19T10:00:00Z '{"spec":{"values":{"pilot":{"env":{"A":null,"B":"1"}}}}}' "${T}/m.json"
	run jq -r '[.apiVersion, .kind, .metadata.namespace, .metadata.name, .metadata.labels["istio-scale-tests/tuning-profile"],
		.data.profile, .data.description, .data["applied-at"]] | join("|")' "${T}/m.json"
	assert_output "v1|ConfigMap|istio-system|tuning-profile-02-xds-cache-off|02-xds-cache-off|02-xds-cache-off|Disable the caches. Two lines.|2026-10-19T10:00:00Z"
	run jq -c '.data["istio-revert.json"] | fromjson' "${T}/m.json"
	assert_output '{"spec":{"values":{"pilot":{"env":{"A":null,"B":"1"}}}}}'
	# The label is the record's, and its read names the marker as the profile's object.
	[ "$(jq -r '.metadata.labels | keys[0]' "${T}/m.json")" = "$PLATFORM_TUNING_LABEL" ]
	run jq -r --arg label "$PLATFORM_TUNING_LABEL" "$PLATFORM_TUNING_JQ" < <(jq '{items: [.]}' "${T}/m.json")
	assert_output "02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off"
	# resources reads it without PyYAML (002-revert-profile.sh's dry-run, 001's apply).
	run python3 -I "$HELPER" resources "${T}/m.json"
	assert_output "ConfigMap tuning-profile-02-xds-cache-off istio-system"
}

@test "tuning.py markers (R6): newest first, each with its revert patch; a labelled ConfigMap that is no marker, or a patch that does not parse, has none" {
	local out="${T}/out"
	mkdir -p "$out"
	mk_marker 01-push-throttling 2026-10-19T09:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"100"}}}}}' "${T}/m1.json"
	mk_marker 02-xds-cache-off 2026-10-19T10:00:00Z '{}' "${T}/m2.json"
	jq '.data["istio-revert.json"] = "{not json"' "${T}/m2.json" | jq '.metadata.name = "tuning-profile-03-x"' >"${T}/m3.json"
	echo '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"hand-made","namespace":"default","labels":{"istio-scale-tests/tuning-profile":"09-x"}}}' >"${T}/m4.json"
	jq -s '{items: .}' "${T}/m1.json" "${T}/m4.json" "${T}/m2.json" "${T}/m3.json" >"${T}/list.json"
	run python3 -I "$HELPER" markers "${T}/list.json" "$out"
	assert_success
	# Same applied-at: by namespace and name, reversed; no applied-at (hand-made) sorts last.
	assert_output "istio-system tuning-profile-03-x 02-xds-cache-off -
istio-system tuning-profile-02-xds-cache-off 02-xds-cache-off ${out}/2.json
istio-system tuning-profile-01-push-throttling 01-push-throttling ${out}/0.json
default hand-made 09-x -"
	[ "$(jq -c . "${out}/0.json")" = '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"100"}}}}}' ]
	[ "$(jq -c . "${out}/2.json")" = '{}' ]
	# An empty list: nothing.
	echo '{"kind":"List","items":[]}' >"${T}/empty.json"
	run python3 -I "$HELPER" markers "${T}/empty.json" "$out"
	assert_success
	assert_output ""
}

@test "tuning.py load (R6): a profile name that cannot label its objects or name its marker is refused; every shipped profile loads" {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 without PyYAML"
	local p long ok
	for p in Bad_Name 02.x -lead trail-; do
		cp "${ROOT}/tests/tuning/profiles/02-xds-cache-off.yaml" "${T}/${p}.yaml"
		run python3 -I "$HELPER" load "${T}/${p}.yaml" "${T}/out"
		assert_failure
		assert_output --partial "a profile's name ('${p}') must be lowercase letters, digits and '-', at most 48 characters: it labels the profile's objects and names its marker ConfigMap"
	done
	# M6-N4: nor baseline, tuning 003's pass without a profile.
	for p in none mixed baseline; do
		cp "${ROOT}/tests/tuning/profiles/02-xds-cache-off.yaml" "${T}/${p}.yaml"
		run python3 -I "$HELPER" load "${T}/${p}.yaml" "${T}/out"
		assert_failure
		assert_output --partial "a profile's name ('${p}') must not be one of none, unknown, mixed, unlabelled, baseline: the platform record uses none, unknown, mixed, unlabelled for itself, and baseline names a tuning sweep's pass without a profile"
	done
	long="$(printf 'a%.0s' {1..49})"
	ok="$(printf 'a%.0s' {1..48})"
	cp "${ROOT}/tests/tuning/profiles/02-xds-cache-off.yaml" "${T}/${long}.yaml"
	cp "${ROOT}/tests/tuning/profiles/02-xds-cache-off.yaml" "${T}/${ok}.yaml"
	run python3 -I "$HELPER" load "${T}/${long}.yaml" "${T}/out"
	assert_failure
	mkdir -p "${T}/out"
	run python3 -I "$HELPER" load "${T}/${ok}.yaml" "${T}/out"
	assert_success
	for p in "${ROOT}"/tests/tuning/profiles/*.yaml; do
		rm -rf "${T}/out" && mkdir -p "${T}/out"
		run python3 -I "$HELPER" load "$p" "${T}/out"
		assert_success
	done
}

@test "002-revert-profile (R6): deletes each member's marker last, once the revert checks out; a failed check or a marker that stays exits 3" {
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
	# A member whose Istio CR is not back: no marker is touched, and the state stays active.
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
	# A state dir from before the markers reverts as it did.
	state_dir
	rm "${SD}"/marker-*.json
	run "$REVERT" --state-dir "$SD"
	assert_success
	refute_output --partial "profile marker"
	# --dry-run names them and touches nothing.
	state_dir
	run "$REVERT" --state-dir "$SD" --dry-run
	assert_success
	assert_output --partial "--- Markers to delete once the check passes ---
ctx-a: ConfigMap istio-system/tuning-profile-02-xds-cache-off
ctx-b: ConfigMap istio-system/tuning-profile-02-xds-cache-off"
	[ ! -s "$STUB_LOG" ]
}

@test "005-cleanup (R6): restores each member's Istio CR from its markers, newest first, checks it, then deletes them; the resource sweep leaves markers alone" {
	local d1 d2
	mk_marker 01-push-throttling 2026-10-19T09:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"100"}}}}}' "${T}/m1.json"
	mk_marker 02-xds-cache-off 2026-10-19T10:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_ENABLE_CDS_CACHE":null}}}}}' "${T}/m2.json"
	mk_marker 04-connection-pools 2026-10-19T10:00:00Z '{}' "${T}/m4.json"
	markers_on ctx-a "${T}/m1.json" "${T}/m2.json"
	markers_on ctx-b "${T}/m4.json"
	echo '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"10","PILOT_ENABLE_CDS_CACHE":"false"}}}}}' >"${STUB_DIR}/live.ctx-a.json"
	run --separate-stderr "$CLEANUP" --contexts ctx-a,ctx-b,ctx-c --results-dir "${T}/results"
	assert_success
	assert_output --partial "  ctx-a: profile 02-xds-cache-off (marker istio-system/tuning-profile-02-xds-cache-off)"
	assert_output --partial "PASS  ctx-b: marker istio-system/tuning-profile-04-connection-pools removed"
	assert_output --partial "  ctx-c: none"
	# U6-B1: markers restored, no pause recorded and no hub given: Argo CD is not known to be resumed.
	[[ "$stderr" == *"warning: the markers restored above were left by a run whose results are not under ${T}/results; if it paused Argo CD, its deny sync window is still on the hub and the Istio CR Applications do not sync: run this again with --gitops-context <hub> (or --results-dir <that run's --output-dir>), or list the windows with ./tests/tuning/006-gitops-pause.sh --gitops-context <hub> --status"* ]]
	assert_output --partial "=== Cleanup complete on the members; Argo CD not checked (see the warning above) ==="
	# ctx-a: 02's patch, then 01's; its Istio CR is back to before both.
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
	# The sweep by label deletes the profile kinds only: never a marker.
	run grep -- " -A -l istio-scale-tests/tuning-profile --ignore-not-found" "$STUB_LOG"
	assert_output --partial "--context=ctx-a delete destinationrules.networking.istio.io,sidecars.networking.istio.io,envoyfilters.networking.istio.io,telemetries.telemetry.istio.io -A"
	refute_output --partial configmaps
	# Nothing restored: no warning, but without a hub its last line still says what it did not
	# check (U7-S2: a run stopped before its first profile leaves a pause and no marker).
	echo '{"kind":"List","items":[]}' >"${STUB_DIR}/markers.ctx-a.json"
	echo '{"kind":"List","items":[]}' >"${STUB_DIR}/markers.ctx-b.json"
	run --separate-stderr "$CLEANUP" --contexts ctx-a,ctx-b,ctx-c --results-dir "${T}/results"
	assert_success
	[[ "$stderr" != *"Argo CD"* ]]
	assert_output --partial "  The hub was not checked for a pause that no record here names (a run stopped before its first profile leaves one and no marker): pass --gitops-context <hub> (or set TUNING_GITOPS_CONTEXT) to check it"
	assert_line "=== Cleanup complete; Argo CD checked only for the pauses recorded under ${T}/results (no --gitops-context) ==="
	refute_line "=== Cleanup complete ==="
}

@test "005-cleanup (SC6-S1): each round patches every member's next marker before it waits for any rollout" {
	local first_wait last_patch
	mk_marker 01-push-throttling 2026-10-19T09:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"100"}}}}}' "${T}/m1.json"
	mk_marker 02-xds-cache-off 2026-10-19T10:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_ENABLE_CDS_CACHE":null}}}}}' "${T}/m2.json"
	markers_on ctx-a "${T}/m1.json" "${T}/m2.json"
	markers_on ctx-b "${T}/m2.json"
	markers_on ctx-c "${T}/m2.json"
	for c in ctx-a ctx-b ctx-c; do
		echo '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"10","PILOT_ENABLE_CDS_CACHE":"false"}}}}}' >"${STUB_DIR}/live.${c}.json"
	done
	run "$CLEANUP" --contexts ctx-a,ctx-b,ctx-c --results-dir "${T}/results"
	assert_success
	# Round 1: 02's patch on all three members, then the rollouts; round 2: ctx-a's 01 alone.
	run grep -o '^patch ctx-[a-c]' "$STUB_LOG"
	assert_output $'patch ctx-a\npatch ctx-b\npatch ctx-c\npatch ctx-a'
	last_patch="$(grep -n -- "--context=ctx-c patch istio.sailoperator.io" "$STUB_LOG" | cut -d: -f1)"
	first_wait="$(grep -n " rollout status deployment/istiod " "$STUB_LOG" | head -n 1 | cut -d: -f1)"
	[ -n "$last_patch" ] && [ -n "$first_wait" ] && [ "$last_patch" -lt "$first_wait" ]
	# ctx-a's older marker waits for its newer one's delete.
	[ "$(grep -n -- "--context=ctx-a -n istio-system delete configmaps tuning-profile-02-xds-cache-off" "$STUB_LOG" | cut -d: -f1)" -lt \
		"$(grep -n -- "--context=ctx-a patch istio.sailoperator.io" "$STUB_LOG" | tail -n 1 | cut -d: -f1)" ]
	for c in ctx-a ctx-b ctx-c; do
		grep -q -- "--context=${c} -n istio-system delete configmaps tuning-profile-02-xds-cache-off --ignore-not-found" "$STUB_LOG"
	done
	[ "$(jq -c .spec.values.pilot.env "${STUB_DIR}/live.ctx-a.json")" = '{"PILOT_PUSH_THROTTLE":"100"}' ]
	[ "$(jq -c .spec.values.pilot.env "${STUB_DIR}/live.ctx-b.json")" = '{"PILOT_PUSH_THROTTLE":"10"}' ]
}

@test "002-revert-profile and 005-cleanup (SC7-S1, SC8-N1): members that never reconcile share the round's deadline, so each after the first is checked once" {
	local c
	# 002 patches all three, then waits with one deadline: the first member's wait runs it out,
	# and each later one is checked once and fails (a deadline each would poll it again 5 s on).
	state_dir ctx-a ctx-b ctx-c
	STUB_NO_RECONCILE=ctx-a,ctx-b,ctx-c run --separate-stderr "$REVERT" --state-dir "$SD" --rollout-timeout 2
	[ "$status" -eq 3 ]
	for c in ctx-a ctx-b ctx-c; do
		[[ "$stderr" == *"${c}: Sail operator did not reconcile within 2s"* ]] || { echo "${c}: ${stderr}"; false; }
	done
	[ "$(grep -c -- "--context=ctx-a get istio.sailoperator.io default -o jsonpath=" "$STUB_LOG")" -ge 1 ]
	[ "$(grep -c -- "--context=ctx-b get istio.sailoperator.io default -o jsonpath=" "$STUB_LOG")" -eq 1 ]
	[ "$(grep -c -- "--context=ctx-c get istio.sailoperator.io default -o jsonpath=" "$STUB_LOG")" -eq 1 ]
	! grep -q "/marker-" "$STUB_LOG" || false
	# 005's round, the same; every marker stays.
	: >"$STUB_LOG"
	mk_marker 02-xds-cache-off 2026-10-19T10:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_ENABLE_CDS_CACHE":null}}}}}' "${T}/m2.json"
	for c in ctx-a ctx-b ctx-c; do markers_on "$c" "${T}/m2.json"; done
	STUB_NO_RECONCILE=ctx-a,ctx-b,ctx-c run --separate-stderr "$CLEANUP" --contexts ctx-a,ctx-b,ctx-c \
		--results-dir "${T}/results" --rollout-timeout 2
	assert_failure
	for c in ctx-a ctx-b ctx-c; do
		[[ "$stderr" == *"${c}: Sail operator did not reconcile within 2s"* ]] || { echo "${c}: ${stderr}"; false; }
		[[ "$stderr" == *"FAIL  ${c}: the Istio CR is not back to its state before 02-xds-cache-off; the marker istio-system/tuning-profile-02-xds-cache-off stays"* ]]
	done
	[ "$(grep -c -- "--context=ctx-a get istio.sailoperator.io default -o jsonpath=" "$STUB_LOG")" -ge 1 ]
	[ "$(grep -c -- "--context=ctx-b get istio.sailoperator.io default -o jsonpath=" "$STUB_LOG")" -eq 1 ]
	[ "$(grep -c -- "--context=ctx-c get istio.sailoperator.io default -o jsonpath=" "$STUB_LOG")" -eq 1 ]
	! grep -q " delete configmaps tuning-profile-" "$STUB_LOG" || false
}

@test "005-cleanup (C8-B1, SC8-S1, C9-S1): a member listed twice is cleaned once, every marker restored newest first, with a note naming five at most" {
	mk_marker 01-push-throttling 2026-10-19T09:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"100"}}}}}' "${T}/m1.json"
	mk_marker 02-xds-cache-off 2026-10-19T10:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_ENABLE_CDS_CACHE":null}}}}}' "${T}/m2.json"
	mk_marker 03-gateway-cluster-filter 2026-10-19T11:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_FILTER_GATEWAY_CLUSTER_CONFIG":null}}}}}' "${T}/m3.json"
	markers_on ctx-a "${T}/m1.json" "${T}/m2.json" "${T}/m3.json"
	echo '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"10","PILOT_ENABLE_CDS_CACHE":"false","PILOT_FILTER_GATEWAY_CLUSTER_CONFIG":"true"}}}}}' \
		>"${STUB_DIR}/live.ctx-a.json"
	run --separate-stderr "$CLEANUP" --contexts ctx-a,ctx-a --results-dir "${T}/results"
	assert_success
	[[ "$stderr" == *"note: ctx-a listed more than once in the contexts; each member is cleaned once"* ]]
	# Twice in a round, the middle marker was skipped and the cleanup still read complete.
	run grep '^patch ' "$STUB_LOG"
	assert_output 'patch ctx-a {"spec":{"values":{"pilot":{"env":{"PILOT_FILTER_GATEWAY_CLUSTER_CONFIG":null}}}}}
patch ctx-a {"spec":{"values":{"pilot":{"env":{"PILOT_ENABLE_CDS_CACHE":null}}}}}
patch ctx-a {"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"100"}}}}}'
	[ "$(jq -c .spec.values.pilot.env "${STUB_DIR}/live.ctx-a.json")" = '{"PILOT_PUSH_THROTTLE":"100"}' ]
	for p in 03-gateway-cluster-filter 02-xds-cache-off 01-push-throttling; do
		[ "$(grep -c -- "--context=ctx-a -n istio-system delete configmaps tuning-profile-${p} --ignore-not-found" "$STUB_LOG")" -eq 1 ]
	done
	# m01,m02,m01 with two markers on m01 (round 2 read past the end of m01's list and died):
	# both are restored, m02 has none, and the steps after the markers run.
	: >"$STUB_LOG"
	markers_on m01 "${T}/m1.json" "${T}/m2.json"
	echo '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"10","PILOT_ENABLE_CDS_CACHE":"false"}}}}}' >"${STUB_DIR}/live.m01.json"
	run --separate-stderr "$CLEANUP" --contexts m01,m02,m01 --results-dir "${T}/results"
	assert_success
	[[ "$stderr" == *"note: m01 listed more than once in the contexts; each member is cleaned once"* ]]
	assert_output --partial "PASS  m01: marker istio-system/tuning-profile-02-xds-cache-off removed"
	assert_output --partial "PASS  m01: marker istio-system/tuning-profile-01-push-throttling removed"
	assert_output --partial "  m02: none"
	assert_output --partial "--- Leftover profile resources (label istio-scale-tests/tuning-profile) ---"
	[ "$(jq -c .spec.values.pilot.env "${STUB_DIR}/live.m01.json")" = '{"PILOT_PUSH_THROTTLE":"100"}' ]
	[ "$(grep -c -- "--context=m01 delete destinationrules" "$STUB_LOG")" -eq 1 ]
	# 500 members each listed twice: five named, then how many more (C9-S1, SC9-N1).
	local ctxs
	ctxs="$(seq -f 'member-%03g' 1 500 | paste -sd, -)"
	run --separate-stderr "$CLEANUP" --contexts "${ctxs},${ctxs}" --results-dir "${T}/results" --dry-run
	assert_success
	[[ "$stderr" == *"note: member-001, member-002, member-003, member-004, member-005 and 495 more listed more than once in the contexts; each member is cleaned once"* ]]
	awk 'length > 300 { bad = 1 } END { exit bad }' <<<"$stderr"
	# Without a working python3 (a dry-run needs none): every member, by name (C10-B1).
	mkdir -p "${T}/nopy"
	printf '#!/bin/sh\nexit 127\n' > "${T}/nopy/python3"
	chmod +x "${T}/nopy/python3"
	PATH="${T}/nopy:${PATH}" run --separate-stderr "$CLEANUP" --contexts ci-a,ci-a,ci-b,ci-b --results-dir "${T}/results" --dry-run
	assert_success
	[[ "$stderr" == *"note: ci-a, ci-b listed more than once in the contexts; each member is cleaned once"* ]]
}

@test "ctx_keys_distinct (C8-S1, SC8-S2): a context listed twice, or two with one state file name, dies; 003 refuses either before its sweep, in --dry-run too" {
	source "${ROOT}/tests/tuning/lib/tuning.sh"
	run ctx_keys_distinct ctx-a ctx-b team/a team.a
	assert_success
	run ctx_keys_distinct ctx-a ctx-b ctx-a
	assert_failure
	assert_output --partial "context ctx-a is listed twice; list each member once"
	run ctx_keys_distinct team/a team_a
	assert_failure
	assert_output --partial "contexts team/a and team_a have one state file name (team_a: a context name keeps only letters, digits, '.', '_' and '-' there); list each member once, under names that differ there"
	# 001 refuses either for every profile pass; 003 refuses it before the setup and the baseline
	# pass run, and before --dry-run prints its plan.
	run "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" --dry-run --suite churn --no-gitops-pause --contexts ci-a,ci-a
	assert_failure
	assert_output --partial "context ci-a is listed twice; list each member once"
	refute_output --partial "--- Plan ---"
	run "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" --dry-run --suite churn --no-gitops-pause --contexts ci-a/x,ci-a_x
	assert_failure
	assert_output --partial "contexts ci-a/x and ci-a_x have one state file name"
	! grep -q . "$STUB_LOG" || false
}

@test "005-cleanup (U6-B1, U7-S3, U8-S4): with a hub context it removes the deny window a pause adds, recorded or not, keeps every other window, and fails on one of its shape for other *-ossm Applications, naming its index; --status prints that one whole and its own pause on one line" {
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
	assert_output --partial "--- Argo CD pause on hub, recorded or not ---"
	assert_output --partial "Resumed auto-sync (removed this tool's deny sync window from AppProject default)"
	assert_output --partial "=== Cleanup complete ==="
	[[ "$stderr" != *"Argo CD not checked"* && "$stderr" != *"warning: the markers restored above"* ]]
	# The patch keeps the other window and the project's resourceVersion.
	run grep '^project-patch ' "$STUB_LOG"
	assert_output 'project-patch hub {"metadata":{"resourceVersion":"7"},"spec":{"syncWindows":[{"kind":"allow","schedule":"0 22 * * *","duration":"1h","applications":["*"]}]}}'
	# Again, from TUNING_GITOPS_CONTEXT: the window is gone, so nothing to patch, and no failure.
	: >"$STUB_LOG"
	TUNING_GITOPS_CONTEXT=hub run "$CLEANUP" --contexts ctx-a --results-dir "${T}/results"
	assert_success
	assert_output --partial "AppProject default: no deny sync window of this tool left"
	assert_line "=== Cleanup complete ==="
	! grep -q '^project-patch ' "$STUB_LOG" || false
	# Another team's window of the same recipe, for Applications not named as the ApplicationSet
	# names them (*-ossm), is not this tool's (U8-S4): it stays, unnamed, and the cleanup passes.
	: >"$STUB_LOG"
	team='{"kind":"deny","schedule":"* * * * *","duration":"1h","applications":["other-app"],"manualSync":true}'
	jq -n --argjson w "$win" --argjson t "$team" '{metadata: {name: "default", resourceVersion: "8"}, spec: {syncWindows: [$w, $t]}}' \
		>"${STUB_DIR}/project.json"
	run --separate-stderr "$CLEANUP" --contexts ctx-a --results-dir "${T}/results" --gitops-context hub
	assert_success
	assert_output --partial "Resumed auto-sync (removed this tool's deny sync window from AppProject default)"
	[[ "$stderr" != *"other-app"* && "$stderr" != *"warning: AppProject default holds"* ]]
	run grep '^project-patch ' "$STUB_LOG"
	assert_output "project-patch hub {\"metadata\":{\"resourceVersion\":\"8\"},\"spec\":{\"syncWindows\":[${team}]}}"
	# A window of this tool's shape for other *-ossm Applications (a pause from before ctx-b was
	# added) is not this tool's to remove by value (U7-S3): its own window goes, that one stays,
	# named on stderr with its index in the list the patch leaves (U8-S4: --status shows that
	# list), and the cleanup fails until it is removed by hand.
	: >"$STUB_LOG"
	jq -n --argjson w "$win" --argjson t "$team" '{metadata: {name: "default", resourceVersion: "9"}, spec: {syncWindows: [
		$w, $t, {kind: "deny", schedule: "* * * * *", duration: "1h", applications: ["ctx-a-ossm"], manualSync: true}]}}' >"${STUB_DIR}/project.json"
	run --separate-stderr "$CLEANUP" --contexts ctx-a --results-dir "${T}/results" --gitops-context hub
	assert_failure
	assert_output --partial "Resumed auto-sync (removed this tool's deny sync window from AppProject default)"
	refute_output --partial "no deny sync window of this tool left"
	[[ "$stderr" == *"warning: AppProject default holds a deny sync window of this tool's shape for other Applications (ctx-a-ossm; index 1 in its sync windows): a pause from before a member was added or removed, which --clear does not remove; those Applications do not sync until it is removed by hand (--status lists the windows; tests/tuning/README.md, \"After a killed run\")"* ]]
	[[ "$stderr" != *"other-app"* ]]
	[[ "$stderr" == *"error: a deny sync window of this tool's shape is still on hub (see the warnings above)"* ]]
	[[ "$stderr" == *"=== Cleanup finished with errors (see above) ==="* ]]
	run grep '^project-patch ' "$STUB_LOG"
	assert_output "project-patch hub {\"metadata\":{\"resourceVersion\":\"9\"},\"spec\":{\"syncWindows\":[${team},{\"kind\":\"deny\",\"schedule\":\"* * * * *\",\"duration\":\"1h\",\"applications\":[\"ctx-a-ossm\"],\"manualSync\":true}]}}"
	# --status lists the windows the patch left with their index, and marks the stale one only:
	# the other team's has the same shape but not *-ossm Applications. The stale one's window is
	# whole on the line under it, as the hand removal's JSON patch tests it (U9-S5).
	run "${ROOT}/tests/tuning/006-gitops-pause.sh" --gitops-context hub --status
	assert_success
	assert_line "Applications: ctx-a-ossm ctx-b-ossm"
	assert_line "AppProject default sync windows (index: window, the index a JSON patch's /spec/syncWindows/<index> takes):"
	assert_line '  0: {"applications": ["other-app"], "duration": "1h", "kind": "deny", "manualSync": true, "schedule": "* * * * *"}'
	assert_line "  1: a stale pause of this tool's, for other *-ossm Applications (ctx-a-ossm: from before a member was added or removed), which --clear does not remove; remove it by hand (tests/tuning/README.md, \"After a killed run\"), its JSON patch testing this window:"
	assert_line '     {"applications": ["ctx-a-ossm"], "duration": "1h", "kind": "deny", "manualSync": true, "schedule": "* * * * *"}'
	[ "$(sed -n 's/^     //p' <<<"$output" | jq -cS .)" = "$(jq -cS '.spec.syncWindows[1]' "${STUB_DIR}/project.json")" ]
	# This tool's own pause of the Applications listed: one line, without them (SC9-N2).
	jq -n --argjson w "$win" '{metadata: {name: "default", resourceVersion: "10"}, spec: {syncWindows: [$w]}}' >"${STUB_DIR}/project.json"
	run "${ROOT}/tests/tuning/006-gitops-pause.sh" --gitops-context hub --status
	assert_success
	assert_line "  0: this tool's pause of the Applications above (--resume removes it with its pause record, --clear without one)"
	refute_output --partial '"applications"'
	# No window at all: none (U9-N2).
	jq -n '{metadata: {name: "default", resourceVersion: "11"}, spec: {}}' >"${STUB_DIR}/project.json"
	run "${ROOT}/tests/tuning/006-gitops-pause.sh" --gitops-context hub --status
	assert_success
	assert_line "  none"
	# The README section that warning names exists.
	grep -qx '## After a killed run' "${ROOT}/tests/tuning/README.md"
	# --dry-run names the call and touches nothing.
	: >"$STUB_LOG"
	run "$CLEANUP" --contexts ctx-a --results-dir "${T}/results" --gitops-context hub --dry-run
	assert_success
	assert_output --partial "[dry-run] tests/tuning/006-gitops-pause.sh --gitops-context hub --clear"
	[ ! -s "$STUB_LOG" ]
	run "${ROOT}/tests/tuning/006-gitops-pause.sh" --gitops-context hub --clear --dry-run
	assert_success
	assert_output "[dry-run] hub: remove the deny sync window this tool adds for the Applications owned by ApplicationSet spoke-ossm, recorded or not"
	run "${ROOT}/tests/tuning/006-gitops-pause.sh" --gitops-context hub --clear --status
	assert_failure
	assert_output --partial "use only one of --pause, --resume, --status, --clear"
	# --resume without its pause record points at --clear, which removes a pause it did not
	# record (U10-N3).
	run "${ROOT}/tests/tuning/006-gitops-pause.sh" --gitops-context hub --resume --state-file "${T}/no-pause-record.json"
	assert_failure
	assert_output --partial "no pause record at ${T}/no-pause-record.json, so nothing for --resume to remove; a pause of this tool's without its record (--status marks it) is removed with --clear"
}

@test "005-cleanup (R6): a restore that does not check out, a ConfigMap with no patch, or a list that fails keeps the markers and exits 1" {
	mk_marker 01-push-throttling 2026-10-19T09:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"100"}}}}}' "${T}/m1.json"
	mk_marker 02-xds-cache-off 2026-10-19T10:00:00Z '{"spec":{"values":{"pilot":{"env":{"PILOT_ENABLE_CDS_CACHE":null}}}}}' "${T}/m2.json"
	markers_on ctx-a "${T}/m1.json" "${T}/m2.json"
	echo '{"spec":{"values":{"pilot":{"env":{"PILOT_PUSH_THROTTLE":"10","PILOT_ENABLE_CDS_CACHE":"false"}}}}}' >"${STUB_DIR}/live.ctx-a.json"
	# The newest does not check out: it stays, and the older one is not tried.
	STUB_PATCH_NOOP=ctx-a run "$CLEANUP" --contexts ctx-a --results-dir "${T}/results"
	assert_failure
	assert_output --partial "FAIL  ctx-a: the Istio CR is not back to its state before 02-xds-cache-off; the marker istio-system/tuning-profile-02-xds-cache-off stays (fix it, then run this again)"
	assert_output --partial "=== Cleanup finished with errors (see above) ==="
	[ "$(grep -c '^patch ' "$STUB_LOG")" -eq 1 ]
	! grep -q " delete configmaps " "$STUB_LOG" || false
	# A labelled ConfigMap that is no marker: what to do by hand.
	: >"$STUB_LOG"
	echo '{"kind":"List","items":[{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"hand-made","namespace":"default","labels":{"istio-scale-tests/tuning-profile":"09-x"}}}]}' \
		>"${STUB_DIR}/markers.ctx-a.json"
	run "$CLEANUP" --contexts ctx-a --results-dir "${T}/results"
	assert_failure
	assert_output --partial "FAIL  ctx-a: default/hand-made holds no revert patch to restore the Istio CR from; restore the settings tests/tuning/profiles/09-x.yaml changes by hand, then delete it: kubectl --context=ctx-a -n default delete configmaps hand-made"
	! grep -q " delete configmaps " "$STUB_LOG" || false
	# A member whose markers cannot be listed; the others are still restored.
	: >"$STUB_LOG"
	markers_on ctx-a "${T}/m2.json"
	STUB_LIST_FAIL=ctx-b run "$CLEANUP" --contexts ctx-a,ctx-b --results-dir "${T}/results"
	assert_failure
	assert_output --partial "FAIL  ctx-b: the profile markers could not be listed; the next tuning run refuses to start until they can"
	grep -q -- "--context=ctx-a -n istio-system delete configmaps tuning-profile-02-xds-cache-off --ignore-not-found" "$STUB_LOG"
	# --dry-run lists nothing on the members.
	: >"$STUB_LOG"
	run "$CLEANUP" --contexts ctx-a --results-dir "${T}/results" --dry-run
	assert_success
	assert_output --partial "[dry-run] ctx-a: restore the Istio CR from each profile marker, newest first, check it, then delete the marker"
	[ ! -s "$STUB_LOG" ]
}
