#!/usr/bin/env bats
# The tuning profiles' marker (R6): tests/tuning/lib/tuning.py writes and reads it,
# 002-revert-profile.sh deletes it last, and 005-cleanup.sh restores each member's Istio CR
# from it, all against a stub kubectl. No cluster and no PyYAML needed (the one test that
# loads a profile skips without it).

load test_helper
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
	# changes (null deletes) unless STUB_PATCH_NOOP names the context; the Sail operator and
	# istiod always read as reconciled and rolled out. Its markers are markers.<ctx>.json (an
	# empty list when absent; STUB_LIST_FAIL names a context whose list fails). A delete -f of
	# a marker file removes it, unless STUB_MARKER_STAYS names the context. Anything else fails.
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
	for p in none mixed; do
		cp "${ROOT}/tests/tuning/profiles/02-xds-cache-off.yaml" "${T}/${p}.yaml"
		run python3 -I "$HELPER" load "${T}/${p}.yaml" "${T}/out"
		assert_failure
		assert_output --partial "a profile's name ('${p}') must not be one of none, unknown, mixed, unlabelled: the platform record uses these words for itself"
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
	run "$CLEANUP" --contexts ctx-a,ctx-b,ctx-c --results-dir "${T}/results"
	assert_success
	assert_output --partial "  ctx-a: profile 02-xds-cache-off (marker istio-system/tuning-profile-02-xds-cache-off)"
	assert_output --partial "PASS  ctx-b: marker istio-system/tuning-profile-04-connection-pools removed"
	assert_output --partial "  ctx-c: none"
	assert_output --partial "=== Cleanup complete ==="
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
