#!/usr/bin/env bats
# tuning 004-compare-profiles through its real entrypoint: histogram p99 rows show the
# worst bucket (or overflow) instead of a mean of interpolated values, labels carry the
# right units (Mi, m, KiB, "peak"), and counts print as integers.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr

COMPARE="${ROOT}/tests/tuning/004-compare-profiles.sh"
CP_HDR=$'timestamp\tistiod_restarted\tistiod_mem_mi\tgo_heap_inuse_mi\tistiod_cpu_m_delta\tconvergence_p99_ms\txds_pushes_delta\tsidecar_config_bytes_avg\tconnected_proxies'

setup() {
	S="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "${S}/baseline" "${S}/01-x"
	printf '# SUITE=controlplane\n# PASSES=baseline,01-x\n' > "${S}/sweep-metadata.txt"
	# baseline: convergence p99 99 and 600 average to ~350 ("100-500"), a bucket no row hit.
	{
		echo "$CP_HDR"
		printf 't\t0\t512\t300\t250\t99\t438\t20480\t10\n'
		printf 't\t0\t512\t300\t250\t600\t438\t20480\t10\n'
		# A restarted row is not valid and never counts.
		printf 't\t1\t9999\t9999\t9999\toverflow\t9999\t9999\t9999\n'
	} > "${S}/baseline/controlplane-r1.tsv"
	# profile: one row's convergence p99 overflowed.
	{
		echo "$CP_HDR"
		printf 't\t0\t256\t300\t250\t100\t400\t10240\t10\n'
		printf 't\t0\t256\t300\t250\toverflow\t400\t10240\t11\n'
	} > "${S}/01-x/controlplane-r2.tsv"
}

@test "tuning 004: histogram p99 is the worst bucket or overflow, never a mean" {
	run "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Convergence p99 worst bucket (ms) | 500-1000 | overflow (1 row) |"
	refute_output --partial "349.50"
	run "$COMPARE" --results-dir "$S"
	assert_output --regexp 'Convergence p99 worst bucket \(ms\) +500-1000 +overflow \(1 row\)'
}

@test "tuning 004: units are Mi, m and KiB with peak stated; counts print as integers" {
	run "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Valid / total rows | 2/3 | 2/2 |"
	assert_output --partial "| istiod memory peak (Mi) | 512 | 256 (-50.0%) |"
	assert_output --partial "| Go heap in use (Mi) | 300 | 300 (+0.0%) |"
	assert_output --partial "| istiod CPU peak (m) | 250 | 250 (+0.0%) |"
	assert_output --partial "| xDS pushes | 438 | 400 (-8.7%) |"
	assert_output --partial "| Sidecar config (KiB) | 20.0 | 10.0 (-50.0%) |"
	# A mean that is not whole keeps one decimal.
	assert_output --partial "| Connected proxies / istiod replica | 10 | 10.5 (+5.0%) |"
	refute_output --partial "MiB"
	refute_output --partial "millicores"
	refute_output --partial "(bytes)"
	refute_output --partial "438.00"
}

# tsv_record [sed program]: the preamble lines a suite TSV of a tuning pass carries, edited by
# the sed program: each member's Kubernetes version (tests/lib/preamble.sh), then the platform
# record (members ctx-a,ctx-b unless PLATFORM_FIXTURE_CTXS names others).
tsv_record() {
	local ctx kv=""
	local -a ctxs=()
	split_csv "${PLATFORM_FIXTURE_CTXS:-ctx-a,ctx-b}" ctxs
	for ctx in "${ctxs[@]}"; do kv+="${kv:+,}${ctx}=v1.33.1"; done
	{ echo "# KUBE_VERSIONS=${kv}"; platform_fixture_lines; } | sed "${1:-}"
}

# with_record <pass> [sed program]: put the lines tsv_record makes (edited by the sed program) at
# the top of that pass's TSV, and, unless the pass has one, the drift file of a read at its end
# that found nothing changed (003 always leaves one; a pass without it was not read again).
with_record() {
	local f
	f="$(ls "${S}/$1"/controlplane-*.tsv)"
	{ tsv_record "${2:-}"; cat "$f"; } > "${f}.new"
	mv "${f}.new" "$f"
	[[ -e "${S}/$1/platform-drift.txt" ]] || echo '# DRIFT_READ_AT=2026-01-01T00:00:00Z' > "${S}/$1/platform-drift.txt"
}

# digest <two hex digits>: a sha256 digest of that pair repeated, as the record holds one.
digest() { printf 'sha256:'; printf "${1}%.0s" {1..32}; }

# profile_state <pass> [env] [object...]: what tuning 001 leaves in a profile pass's state dir:
# patch.json (setting istiod's env <env> when given, else {}: no Istio CR patch) and objects (its
# marker, then each <object>, as Kind/ns/name).
profile_state() {
	local p="$1" env="${2:-}"
	shift
	[[ $# -eq 0 ]] || shift
	mkdir -p "${S}/${p}/state"
	if [[ -n "$env" ]]; then
		printf '{"spec":{"values":{"pilot":{"env":{"%s":"x"}}}}}\n' "$env" > "${S}/${p}/state/patch.json"
	else
		echo '{}' > "${S}/${p}/state/patch.json"
	fi
	printf '%s\n' "ConfigMap/istio-system/tuning-profile-${p}" "$@" > "${S}/${p}/state/objects"
}

# own_objects <pass>: its state/objects as its record names them (<pass>:<Kind>/<ns>/<name>, "+"-joined).
own_objects() {
	local o v=""
	while IFS= read -r o; do v+="${v:++}${1}:${o}"; done < "${S}/${1}/state/objects"
	printf '%s\n' "$v"
}

# profile_pass <pass> [env] [object...]: profile_state, then all of those objects on every member
# whose TUNING_OBJECTS_BY_CONTEXT reads none in the pass's record (as on a pass that kept its profile).
profile_pass() {
	local f v
	profile_state "$@"
	v="$(own_objects "$1")"
	for f in "${S}/${1}"/controlplane-*.tsv; do
		sed -i "/^# TUNING_OBJECTS_BY_CONTEXT=/s#=none#=${v}#g" "$f"
	done
}

# five_passes: a baseline and four profiles whose records carry full digests: 01-same as the
# baseline, 02-state only another operator state, 03-proxy another gateway proxy build,
# 04-legacy from before the record. Sets digests (the sed program that adds them).
five_passes() {
	local p
	rm -rf "$S"
	mkdir -p "$S"
	printf '# SUITE=controlplane\n# PASSES=baseline,01-same,02-state,03-proxy,04-legacy\n' > "${S}/sweep-metadata.txt"
	for p in baseline 01-same 02-state 03-proxy 04-legacy; do
		mkdir -p "${S}/${p}"
		printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10' > "${S}/${p}/controlplane-${p}.tsv"
	done
	digests="s/sail-operator:1.31.1/sail-operator:1.31.1@$(digest ab)/g; s/pilot:1.30.5/pilot:1.30.5@$(digest cd)/g; s/proxyv2:1.30.5/proxyv2:1.30.5@$(digest ef)/g"
	with_record baseline "$digests"
	with_record 01-same "$digests"
	with_record 02-state "${digests}; s#/Available#/Unavailable#g"
	with_record 03-proxy "${digests}; s/proxyv2:1.30.5@$(digest ef)/proxyv2:1.30.6@$(digest 01)/g"
	for p in 01-same 02-state 03-proxy 04-legacy; do profile_pass "$p"; done
}

@test "tuning 004 (S-B2): a record of 500 members compares in both formats; the one member that differs is named, not all 500" {
	local last=scale-campaign-region-a-member-500.example.invalid
	PLATFORM_FIXTURE_CTXS="$(wide_ctxs 500)" with_record baseline
	PLATFORM_FIXTURE_CTXS="$(wide_ctxs 500)" with_record 01-x "s/${last}=proxyv2:1.30.5/${last}=proxyv2:1.30.6/"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | differs (see notes) |"
	assert_output --partial "- PROXY_IMAGE_BY_CONTEXT: \`${last}=proxyv2:1.30.6 (1 of 500 members; the other 499 match)\`"
	refute_output --partial "member-499.example.invalid"
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp "  PROXY_IMAGE_BY_CONTEXT +${last}=proxyv2:1.30.6 \(1 of 500 members; the other 499 match\)"
}

@test "tuning 004 (H3): one Platform record row keeps the table narrow; a differing pass is flagged, a state-only operator difference is not" {
	five_passes
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | same | differs (see notes) | unknown (see notes) |"
	# Every table row stays well below 200 characters (it was 542 with six rows of full digests).
	local line widest=0
	while IFS= read -r line; do
		[[ "$line" == '|'* ]] || continue
		((${#line} <= widest)) || widest="${#line}"
	done <<<"$output"
	[ "$widest" -gt 0 ]
	[ "$widest" -lt 120 ]
	# The record once, after the table, digests shortened to 12 hex digits.
	assert_output --partial "### Platform record"
	assert_output --partial "- MESH_OPERATOR_BY_CONTEXT: \`sail-operator:1.31.1@sha256:abababababab/Available\`"
	assert_output --partial "- PROXY_IMAGE_BY_CONTEXT: \`proxyv2:1.30.5@sha256:efefefefefef\`"
	refute_output --partial "$(digest ef)"
	# The differing pass: its keys and values, a warning in the notes and on stderr.
	assert_output --partial "Pass 03-proxy, differs on PROXY_IMAGE_BY_CONTEXT:"
	assert_output --partial "- PROXY_IMAGE_BY_CONTEXT: \`proxyv2:1.30.6@sha256:010101010101\`"
	assert_output --partial "- **Warning:** pass 03-proxy differs from the baseline on PROXY_IMAGE_BY_CONTEXT (its values follow the table), so its change against the baseline is not the profile's alone"
	[[ "$stderr" == *"warning: pass 03-proxy differs from the baseline on PROXY_IMAGE_BY_CONTEXT"* ]]
	# A pass from before the record cannot be compared (unknown, not "differs"): one line after
	# the table, not a list of unknowns.
	assert_output --partial "Pass 04-legacy: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read)."
	refute_output --partial "Pass 04-legacy, cannot be compared on"
	assert_output --partial "- **Warning:** pass 04-legacy: no key of its platform record can be compared with the baseline (its TSVs predate the record, or nothing could be read), nor its Kubernetes versions, so whether it ran on the same platform and builds is not known"
	refute_output --partial "04-legacy differs"
	# The baseline's record shows its Kubernetes version too.
	assert_output --partial "- KUBE_VERSIONS: \`v1.33.1\`"
	# Available vs Unavailable is the same operator build: no warning, no block entry.
	refute_output --partial "02-state"$'\n'
	[[ "$output" != *"pass 02-state"* && "$output" != *"Pass 02-state"* ]]
	[[ "$stderr" != *"02-state"* ]]
	# Text: the same row, the block after the table, every table line narrow.
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp 'Platform record +baseline +same +same +differs \(see notes\) +unknown \(see notes\)'
	assert_output --partial "WARNING: pass 03-proxy differs from the baseline on PROXY_IMAGE_BY_CONTEXT"
	assert_output --partial "Platform record of the baseline, digests shortened to 12 hex digits (the TSVs keep them in full):"
	assert_output --regexp '  PROXY_IMAGE_BY_CONTEXT +proxyv2:1.30.5@sha256:efefefefefef'
	assert_output --partial "Pass 04-legacy: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read)."
	refute_output --partial "Pass 04-legacy, cannot be compared on"
	widest=0
	while IFS= read -r line; do
		[[ "$line" != "Platform record of"* ]] || break
		((${#line} <= widest)) || widest="${#line}"
	done < <(sed -n '/^Metric/,$p' <<<"$output")
	[ "$widest" -gt 0 ]
	[ "$widest" -lt 120 ]
}

@test "tuning 004: without a baseline, the first pass with data is the reference" {
	five_passes
	rm -rf "${S}/baseline"
	printf '# SUITE=controlplane\n# PASSES=01-same,02-state,03-proxy,04-legacy\n' > "${S}/sweep-metadata.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | reference | same | differs (see notes) | unknown (see notes) |"
	assert_output --partial "The record of the reference pass (01-same, the first with data), digests shortened"
	assert_output --partial "- **Warning:** pass 03-proxy differs from the reference pass (01-same, the first with data) on PROXY_IMAGE_BY_CONTEXT (its values follow the table), so its difference from the reference pass (01-same, the first with data) is not the profiles' alone"
	refute_output --partial "so its change against the baseline"
}

@test "tuning 004 (H25, H2): istiod's settings are not compared (a profile changes them); a digest @unknown is not read, never another build" {
	five_passes
	# 01-same ran with its profile's istiod env (on both members); 02-state's istiod had not
	# started when it was read.
	sed -i '/^# ISTIOD_ENV_BY_CONTEXT=/s/0123456789ab/fedcba987654/g' "${S}/01-same/controlplane-01-same.tsv"
	grep -qx '# ISTIOD_ENV_BY_CONTEXT=ctx-a=fedcba987654,ctx-b=fedcba987654' "${S}/01-same/controlplane-01-same.tsv"
	profile_state 01-same PILOT_DEBOUNCE_AFTER
	sed -i "s/pilot:1.30.5@$(digest cd)/pilot:1.30.5@unknown/g" "${S}/02-state/controlplane-02-state.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | unknown (see notes) | differs (see notes) | unknown (see notes) |"
	refute_output --partial "pass 01-same"
	refute_output --partial "Pass 01-same"
	[[ "$stderr" != *ISTIOD_ENV_BY_CONTEXT* ]]
	# The baseline's record still shows it (the TSVs keep it), and every pass's digest has a row (R6).
	assert_output --partial "- ISTIOD_ENV_BY_CONTEXT: \`0123456789ab\`"
	assert_output --partial "| istiod env | 0123456789ab | fedcba987654 | 0123456789ab | 0123456789ab | unknown |"
	assert_output --partial "Pass 02-state, cannot be compared on ISTIOD_IMAGE_BY_CONTEXT:"
	assert_output --partial "- **Warning:** pass 02-state: ISTIOD_IMAGE_BY_CONTEXT could not be compared with the baseline (not read, or not recorded, in one of them)"
	refute_output --partial "02-state differs"
}

@test "tuning 004: a pass with one value not read names that key and its value after the table" {
	five_passes
	printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10' > "${S}/01-same/controlplane-01-same.tsv"
	with_record 01-same "${digests}; s/pilot:1.30.5@$(digest cd)/unknown/g"
	profile_pass 01-same
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | unknown (see notes) | same | differs (see notes) | unknown (see notes) |"
	assert_output --partial "Pass 01-same, cannot be compared on ISTIOD_IMAGE_BY_CONTEXT:"
	assert_output --partial "- ISTIOD_IMAGE_BY_CONTEXT: \`unknown\`"
	assert_output --partial "- **Warning:** pass 01-same: ISTIOD_IMAGE_BY_CONTEXT could not be compared with the baseline (not read, or not recorded, in one of them)"
	refute_output --partial "Pass 01-same: every value"
}

@test "tuning 004 (M7-N2): a pass whose TSVs disagree within it reads mixed, not another build than the baseline's" {
	five_passes
	# A second TSV in 01-same, on another istiod build: the pass's own record is mixed.
	{
		tsv_record "${digests}; s/pilot:1.30.5@$(digest cd)/pilot:1.30.6@$(digest 23)/g; s#=none#=$(own_objects 01-same)#g"
		printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10'
	} > "${S}/01-same/controlplane-second.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | mixed (see notes) | same | differs (see notes) | unknown (see notes) |"
	assert_output --partial "Pass 01-same, its TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT:"
	# Both members hold both builds: the value they share, once.
	assert_output --partial "- ISTIOD_IMAGE_BY_CONTEXT: \`mixed: pilot:1.30.5@sha256:cdcdcdcdcdcd and pilot:1.30.6@sha256:232323232323\`"
	assert_output --partial "- **Warning:** pass 01-same: its TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT (or one of them did not read or record a value; the values follow the table), so part of it may have run on another platform, build, Kubernetes version, tuning lever, istiod limit or istiod replica count, and then its change against the baseline is not the profile's alone"
	refute_output --partial "pass 01-same differs"
	# Only 004's own warnings on stderr: none of the library's for a sweep's report (U7-S4).
	[[ "$stderr" == *"warning: pass 01-same: its TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT"* ]]
	! grep -v '^warning: pass' <<<"$stderr" || false
	# In the baseline: its cell says so, and no pass is compared with it on that key.
	mv "${S}/01-same/controlplane-second.tsv" "${S}/baseline/controlplane-second.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | same (see notes) | same (see notes) | differs (see notes) | unknown (see notes) |"
	assert_output --partial "- ISTIOD_IMAGE_BY_CONTEXT, where the baseline ran more than one value, one of those: \`pilot:1.30.5@sha256:cdcdcdcdcdcd on ctx-a, ctx-b\`"
	assert_output --partial "- **Warning:** pass baseline: its TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT (or one of them did not read or record a value; the values follow the table), so part of it may have run on another platform, build, Kubernetes version, tuning lever, istiod limit or istiod replica count, and then no profile's change against it is the profile's alone"
	assert_output --partial "Pass baseline, its TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT:"
	assert_output --partial "- ISTIOD_IMAGE_BY_CONTEXT: \`mixed: pilot:1.30.5@sha256:cdcdcdcdcdcd and pilot:1.30.6@sha256:232323232323 on ctx-a, ctx-b\`"
	# One member's TSVs disagree, by a build the baseline also ran: that member is shown, not
	# hidden behind "every member recorded matches".
	rm "${S}/baseline/controlplane-second.tsv"
	{
		tsv_record "${digests}; /^# ISTIOD_IMAGE_BY_CONTEXT=/s/ctx-a=pilot:1.30.5@$(digest cd)/ctx-a=pilot:1.30.6@$(digest 23)/; s#=none#=$(own_objects 01-same)#g"
		printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10'
	} > "${S}/01-same/controlplane-second.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | mixed (see notes) | same | differs (see notes) | unknown (see notes) |"
	assert_output --partial "- ISTIOD_IMAGE_BY_CONTEXT: \`ctx-a=mixed: pilot:1.30.5@sha256:cdcdcdcdcdcd and pilot:1.30.6@sha256:232323232323 (1 of 2 members; the other 1 match)\`"
	refute_output --partial "every member recorded matches"
}

# objects_passes: a baseline and the passes 02-x and 04-connection-pools (each pass dir is the
# profile's name, as tuning 003 makes it), with TSVs but no record yet (with_record adds it) and no
# state (profile_state, profile_pass).
objects_passes() {
	local p
	rm -rf "$S"
	mkdir -p "$S"
	printf '# SUITE=controlplane\n# PASSES=baseline,02-x,04-connection-pools\n' > "${S}/sweep-metadata.txt"
	for p in baseline 02-x 04-connection-pools; do
		mkdir -p "${S}/${p}"
		printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10' > "${S}/${p}/controlplane-${p}.tsv"
	done
}

@test "tuning 004 (R6, I6-B1): a pass with every object of its own profile on every member reads own; the baseline none; no warning" {
	objects_passes
	with_record baseline
	# 02-x sets istiod's env (its digest is not the baseline's); 04 adds a DestinationRule.
	with_record 02-x "s/=0123456789ab/=fedcba987654/g"
	with_record 04-connection-pools
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	grep -qx "# TUNING_OBJECTS_BY_CONTEXT=ctx-a=04-connection-pools:ConfigMap/istio-system/tuning-profile-04-connection-pools+04-connection-pools:DestinationRule/istio-system/tuning-connection-pool,ctx-b=04-connection-pools:ConfigMap/istio-system/tuning-profile-04-connection-pools+04-connection-pools:DestinationRule/istio-system/tuning-connection-pool" "${S}/04-connection-pools/controlplane-04-connection-pools.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | same |"
	assert_output --partial "| istiod env | 0123456789ab | fedcba987654 | 0123456789ab |"
	assert_output --partial "| Tuning objects | none | own | own |"
	refute_output --partial "Warning"
	refute_output --partial "see notes"
	[ -z "$stderr" ] || { echo "$stderr"; false; }
}

@test "tuning 004 (R6, M5-B1): a baseline with a profile's objects, and a pass with another profile's, warn in both formats and on stderr" {
	local dr="04-connection-pools:DestinationRule/istio-system/tuning-connection-pool"
	objects_passes
	# A run stopped before its revert left profile 04's root DestinationRule on ctx-a; the sweep
	# ran --profiles without 04, so its own objects never replaced it.
	with_record baseline "s#ctx-a=none#ctx-a=${dr}#"
	with_record 02-x "s#ctx-a=none#ctx-a=02-x:ConfigMap/istio-system/tuning-profile-02-x+02-x:Sidecar/istio-system/tuning-02+${dr}#"
	with_record 04-connection-pools
	profile_pass 02-x "" Sidecar/istio-system/tuning-02
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Tuning objects | other (see notes) | other (see notes) | own |"
	assert_output --partial "- **Warning:** pass baseline ran with a tuning profile's objects in place on ctx-a (TUNING_OBJECTS_BY_CONTEXT: ${dr}), so its figures are not those of the charts' configuration and no profile's change against it is the profile's alone; tests/tuning/005-cleanup.sh undoes them"
	assert_output --partial "- **Warning:** pass 02-x ran with another tuning profile's objects in place on ctx-a (TUNING_OBJECTS_BY_CONTEXT: ${dr}), so it did not measure 02-x alone and its change against the baseline is not the profile's alone; tests/tuning/005-cleanup.sh undoes them"
	refute_output --partial "pass 04-connection-pools"
	# The notes after the table name them too.
	assert_output --partial "Pass baseline:"
	assert_output --partial "- TUNING_OBJECTS_BY_CONTEXT: a profile's objects on ctx-a: ${dr}"
	assert_output --partial "- TUNING_OBJECTS_BY_CONTEXT: another profile's objects on ctx-a: ${dr}"
	[[ "$stderr" == *"warning: pass baseline ran with a tuning profile's objects in place on ctx-a"* ]]
	[[ "$stderr" == *"warning: pass 02-x ran with another tuning profile's objects in place on ctx-a"* ]]
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp 'Tuning objects +other \(see notes\) +other \(see notes\) +own'
	assert_output --partial "WARNING: pass baseline ran with a tuning profile's objects in place on ctx-a"
	assert_output --regexp "  TUNING_OBJECTS_BY_CONTEXT +another profile's objects on ctx-a: ${dr}"
}

@test "tuning 004 (R6): objects not read on a member read unknown with a warning; a pass from before the record has its one note" {
	objects_passes
	with_record baseline "s#ctx-b=none#ctx-b=unknown#"
	with_record 02-x "s#ctx-b=none#ctx-b=unknown#"
	profile_pass 02-x
	profile_state 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Tuning objects | unknown (see notes) | unknown (see notes) | unknown (see notes) |"
	assert_output --partial "- **Warning:** pass baseline: its tuning profile objects (TUNING_OBJECTS_BY_CONTEXT) could not be read on ctx-b, so whether a profile's objects were in place is not known"
	assert_output --partial "- **Warning:** pass 02-x: its tuning profile objects (TUNING_OBJECTS_BY_CONTEXT) could not be read on ctx-b, so whether its profile's objects, and only those, were in place is not known"
	assert_output --partial "- TUNING_OBJECTS_BY_CONTEXT: could not be read on ctx-b"
	# 04-connection-pools has no record: its one note, no tuning objects warning of its own.
	assert_output --partial "Pass 04-connection-pools: every value of its platform record is unknown"
	refute_output --partial "pass 04-connection-pools: its"
	# A record from before the key: not recorded, so not known either.
	with_record 04-connection-pools '/^# TUNING_OBJECTS_BY_CONTEXT=/d'
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Tuning objects | unknown (see notes) | unknown (see notes) | unknown (see notes) |"
	assert_output --partial "- **Warning:** pass 04-connection-pools: its tuning profile objects (TUNING_OBJECTS_BY_CONTEXT) are not recorded (its TSVs predate the key), so whether it held only the objects its name says (none for the baseline) is not known"
	# In one of its two TSVs only (the other holds the profile's objects).
	{
		tsv_record "s#=none#=$(own_objects 04-connection-pools)#g"
		printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10'
	} > "${S}/04-connection-pools/controlplane-second.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "- **Warning:** pass 04-connection-pools: its tuning profile objects (TUNING_OBJECTS_BY_CONTEXT) are not recorded in every input (one predates the key), so whether its profile's objects, and only those, were in place is not known"
}

@test "tuning 004 (U6-S3): passes from before the tuning objects key share one warning that names them" {
	objects_passes
	with_record baseline '/^# TUNING_OBJECTS_BY_CONTEXT=/d'
	with_record 02-x '/^# TUNING_OBJECTS_BY_CONTEXT=/d'
	with_record 04-connection-pools '/^# TUNING_OBJECTS_BY_CONTEXT=/d'
	profile_state 02-x
	profile_state 04-connection-pools
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Tuning objects | unknown (see notes) | unknown (see notes) | unknown (see notes) |"
	assert_output --partial "- **Warning:** passes baseline, 02-x, 04-connection-pools: their tuning profile objects (TUNING_OBJECTS_BY_CONTEXT) are not recorded (their TSVs predate the key), so whether each held only the objects its name says (none for the baseline) is not known"
	[ "$(grep -c 'are not recorded' <<<"$stderr")" -eq 1 ]
}

@test "tuning 004 (I6-B1, U6-S1): a profile pass without one of its own objects on a member reads missing and warns, naming the members and objects" {
	local m02="02-x:ConfigMap/istio-system/tuning-profile-02-x" m04="04-connection-pools:ConfigMap/istio-system/tuning-profile-04-connection-pools"
	objects_passes
	with_record baseline
	# 02-x: its marker on ctx-a only (undone on ctx-b during the pass, or never applied there).
	with_record 02-x "s#ctx-a=none#ctx-a=${m02}#"
	# 04: its marker on both members, but its DestinationRule (state/objects lists it) on neither.
	with_record 04-connection-pools "s#=none#=${m04}#g"
	profile_state 02-x
	profile_state 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Tuning objects | none | missing (see notes) | missing (see notes) |"
	assert_output --partial "- **Warning:** pass 02-x: its profile's objects (${m02}) are not on ctx-b in its record (TUNING_OBJECTS_BY_CONTEXT), so the profile was not in place there all through the pass: undone during it (002-revert-profile.sh, 005-cleanup.sh or a hand delete), never applied there, or its TSVs predate the profile markers; its figures are not the profile's"
	assert_output --partial "- **Warning:** pass 04-connection-pools: its profile's objects (04-connection-pools:DestinationRule/istio-system/tuning-connection-pool) are not on ctx-a, ctx-b in its record"
	assert_output --partial "- TUNING_OBJECTS_BY_CONTEXT: its profile's ${m02} not on ctx-b"
	[[ "$stderr" == *"warning: pass 02-x: its profile's objects (${m02}) are not on ctx-b"* ]]
	# Without state/objects (a pass from before 001 wrote it), the marker alone is expected.
	mv "${S}/04-connection-pools/state/objects" "${S}/04-objects.old"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Tuning objects | none | missing (see notes) | own |"
	# On no member at all: a pass whose profile never reached the members, or TSVs from before the markers.
	with_record 02-x
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp 'Tuning objects +none +missing \(see notes\) +own'
	assert_output --partial "WARNING: pass 02-x: its profile's objects (${m02}) are not on ctx-a, ctx-b in its record"
	assert_output --regexp "  TUNING_OBJECTS_BY_CONTEXT +its profile's ${m02} not on ctx-a, ctx-b"
}

@test "tuning 004 (I6-B1, R6-S1): a profile undone during its pass (a TSV, or the read after its probe, without it) reads missing; settings that changed read mixed" {
	local m02="02-x:ConfigMap/istio-system/tuning-profile-02-x"
	objects_passes
	with_record baseline
	with_record 02-x "s/=0123456789ab/=fedcba987654/g"
	with_record 04-connection-pools
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	# The read after 02-x's probe found its marker gone and istiod back on the baseline's settings
	# on ctx-b (tuning 003's platform_drift_check writes this next to the pass's TSVs).
	printf '%s\n' '# Values that changed during this sweep' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' \
		'# ISTIOD_ENV_BY_CONTEXT=ctx-b=0123456789ab' '# TUNING_OBJECTS_BY_CONTEXT=ctx-b=none' > "${S}/02-x/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| istiod env | 0123456789ab | mixed (see notes) | 0123456789ab |"
	assert_output --partial "| Tuning objects | none | missing (see notes) | own |"
	assert_output --partial "- ISTIOD_ENV_BY_CONTEXT, by member: \`fedcba987654 on ctx-a; mixed: fedcba987654 and 0123456789ab on ctx-b\`"
	assert_output --partial "- **Warning:** pass 02-x: istiod's settings were not one value all through the pass (ISTIOD_ENV_BY_CONTEXT: fedcba987654 on ctx-a; mixed: fedcba987654 and 0123456789ab on ctx-b): its TSVs disagree or one could not read them, or the read at its end found them changed (an Argo CD sync, a hand edit, a profile applied or reverted during it), so part of it may have run other settings"
	# The baseline's digest in a pass whose profile sets istiod's env: also against the baseline.
	assert_output --partial "- ISTIOD_ENV_BY_CONTEXT: the baseline's (mixed: fedcba987654 and 0123456789ab on ctx-b), though the profile sets spec.values.pilot.env"
	assert_output --partial "- **Warning:** pass 02-x: its profile's objects (${m02}) are not on ctx-b in its record"
	refute_output --partial "pass 04-connection-pools"
	# On stderr, 004's own warnings only, not the library's for a sweep's report (U7-S4).
	[[ "$stderr" != *"during the sweep"* ]]
	! grep -v '^warning: pass' <<<"$stderr" || false
	# A pass's own two TSVs that disagree (churn-dataplane writes two): one without the marker.
	mv "${S}/02-x/platform-drift.txt" "${S}/02-x-drift.old"
	{
		tsv_record "s/=0123456789ab/=fedcba987654/g"
		printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10'
	} > "${S}/02-x/controlplane-second.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| istiod env | 0123456789ab | fedcba987654 | 0123456789ab |"
	assert_output --partial "| Tuning objects | none | missing (see notes) | own |"
	assert_output --partial "- **Warning:** pass 02-x: its profile's objects (${m02}) are not on ctx-a, ctx-b in its record"
}

@test "tuning 004 (I6-S1, M6-S1): istiod settings that contradict the profile against the baseline's warn; a missing state/patch.json warns" {
	objects_passes
	with_record baseline
	# 02-x sets istiod's env, yet ran with the baseline's settings on both members; 04 sets none,
	# yet ran with other settings on ctx-b.
	with_record 02-x
	with_record 04-connection-pools "s/ctx-b=0123456789ab/ctx-b=fedcba987654/"
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| istiod env | 0123456789ab | 0123456789ab (see notes) | by member (see notes) |"
	assert_output --partial "- ISTIOD_ENV_BY_CONTEXT: the baseline's (0123456789ab on ctx-a, ctx-b), though the profile sets spec.values.pilot.env"
	assert_output --partial "- **Warning:** pass 02-x: istiod's settings are the baseline's (ISTIOD_ENV_BY_CONTEXT: 0123456789ab on ctx-a, ctx-b), though its profile sets spec.values.pilot.env, so the profile's env was not in effect there all through the pass (an Argo CD sync or a hand edit put it back, or it never rolled out; or the profile sets the values istiod already had), and its change against the baseline is not the profile's"
	assert_output --partial "- ISTIOD_ENV_BY_CONTEXT: not the baseline's (fedcba987654 on ctx-b), though the profile does not patch the Istio CR"
	assert_output --partial "- **Warning:** pass 04-connection-pools: istiod's settings are not the baseline's (ISTIOD_ENV_BY_CONTEXT: fedcba987654 on ctx-b), though its profile does not patch the Istio CR, so something else changed them (an Argo CD sync, a hand edit, another profile), and its change against the baseline is not the profile's alone"
	[[ "$stderr" == *"warning: pass 02-x: istiod's settings are the baseline's"* ]]
	# A profile that patches other Istio CR values only (some reach istiod's env too) is not checked.
	echo '{"spec":{"values":{"pilot":{"traceSampling":1}}}}' > "${S}/04-connection-pools/state/patch.json"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| istiod env | 0123456789ab | 0123456789ab (see notes) | by member (see notes) |"
	refute_output --partial "though its profile does not patch the Istio CR"
	refute_output --partial "pass 04-connection-pools: its state/patch.json"
	# Without its state/patch.json, whether the profile sets istiod's env is not known: one warning.
	mv "${S}/02-x/state/patch.json" "${S}/02-x-patch.old"
	echo '{not json' > "${S}/04-connection-pools/state/patch.json"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| istiod env | 0123456789ab | 0123456789ab | by member (see notes) |"
	assert_output --partial "- **Warning:** pass 02-x: its state/patch.json (001-apply-profile.sh writes it in the pass's state dir) is not in the sweep directory or does not parse (jq reads it), so whether its profile's istiod settings were in effect is not checked against the baseline"
	assert_output --partial "- **Warning:** pass 04-connection-pools: its state/patch.json (001-apply-profile.sh writes it in the pass's state dir) is not in the sweep directory or does not parse"
	assert_output --partial "- ISTIOD_ENV_BY_CONTEXT: state/patch.json missing or unreadable: not checked against the baseline"
	# Nothing to compare (the baseline's settings were not read): no patch is needed, no warning.
	with_record baseline "s/=0123456789ab/=unknown/g"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	refute_output --partial "state/patch.json"
}

@test "tuning 004 (R6, U6-S2): a pass whose members ran different istiod settings shows them by member, five named, and warns" {
	objects_passes
	with_record baseline
	with_record 02-x "s/ctx-b=0123456789ab/ctx-b=fedcba987654/"
	with_record 04-connection-pools
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| istiod env | 0123456789ab | by member (see notes) | 0123456789ab |"
	assert_output --partial "- ISTIOD_ENV_BY_CONTEXT, by member: \`0123456789ab on ctx-a; fedcba987654 on ctx-b\`"
	assert_output --partial "- **Warning:** pass 02-x: istiod's settings differ between its members (ISTIOD_ENV_BY_CONTEXT: 0123456789ab on ctx-a; fedcba987654 on ctx-b), so they did not all run the same configuration; the profile may have reached some of them only"
	# ctx-a ran the baseline's settings though the profile sets istiod's env.
	assert_output --partial "- ISTIOD_ENV_BY_CONTEXT: the baseline's (0123456789ab on ctx-a), though the profile sets spec.values.pilot.env"
	[[ "$stderr" == *"warning: pass 02-x: istiod's settings differ between its members"* ]]
	# Seven members: five named per value, then how many more.
	local ctxs=ctx-a,ctx-b,ctx-c,ctx-d,ctx-e,ctx-f,ctx-g
	PLATFORM_FIXTURE_CTXS="$ctxs" objects_passes
	PLATFORM_FIXTURE_CTXS="$ctxs" with_record baseline
	PLATFORM_FIXTURE_CTXS="$ctxs" with_record 02-x "/^# ISTIOD_ENV_BY_CONTEXT=/s/=0123456789ab/=fedcba987654/g; /^# ISTIOD_ENV_BY_CONTEXT=/s/ctx-g=fedcba987654/ctx-g=0123456789ab/"
	PLATFORM_FIXTURE_CTXS="$ctxs" with_record 04-connection-pools
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "- ISTIOD_ENV_BY_CONTEXT, by member: \`fedcba987654 on ctx-a, ctx-b, ctx-c, ctx-d, ctx-e and 1 more; 0123456789ab on ctx-g\`"
}

# with_levers <pass>: the tuning levers, root Sidecar egress hosts and istiod limits a suite TSV
# records (tests/lib/preamble.sh; the controlplane's limits), at the top of that pass's TSV.
with_levers() {
	local f
	f="$(ls "${S}/$1"/controlplane-*.tsv)"
	{
		printf '%s\n' "# TUNING_BASELINE=${2:-${LEVERS_ON}}" "# SIDECAR_EGRESS_HOSTS=${3:-./* istio-system/*}" \
			"# ISTIOD_CPU_LIMIT_M=${4:-2000}" "# ISTIOD_MEM_LIMIT_MI=${5:-4096}"
		cat "$f"
	} > "${f}.new"
	mv "${f}.new" "$f"
}
LEVERS_ON=sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on
SIDECAR_OFF=sidecar=off,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on

@test "tuning 004 (M7-B1, R7-B1): what the read at a pass's end found changed warns for that pass in the body and on stderr: a Kubernetes version, a lever, the root Sidecar's hosts, an istiod limit" {
	local p w="- **Warning:** pass 02-x:"
	objects_passes
	with_record baseline
	with_record 02-x "s/=0123456789ab/=fedcba987654/g"
	with_record 04-connection-pools
	for p in baseline 02-x 04-connection-pools; do with_levers "$p"; done
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	# What tuning 003's platform_drift_check writes after 02-x's probes: a control-plane upgrade on
	# ctx-a, the root Sidecar gone, istiod's CPU limit raised; and a member whose limits differ from
	# the source member's, which every pass's read finds again (no change during the pass).
	printf '%s\n' '# The platform record read again at the end of this pass' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' \
		'# KUBE_VERSIONS=ctx-a=v1.33.2' \
		'# TUNING_BASELINE=sidecar=off,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on' \
		'# SIDECAR_EGRESS_HOSTS=none' '# ISTIOD_CPU_LIMIT_M=4000' '# ISTIOD_LIMITS_DIFFER_BY_CONTEXT=ctx-b=1000/2048' \
		> "${S}/02-x/platform-drift.txt"
	for p in baseline 04-connection-pools; do
		printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' '# ISTIOD_LIMITS_DIFFER_BY_CONTEXT=ctx-b=1000/2048' > "${S}/${p}/platform-drift.txt"
	done
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | changed (see notes) | same |"
	# The standing difference (S5): in the reference block, each member's limit, and no warning.
	assert_output --partial "- ISTIOD_CPU_LIMIT_M_BY_CONTEXT: \`2000 on ctx-a; 1000 on ctx-b\`"
	assert_output --partial "- ISTIOD_MEM_LIMIT_MI_BY_CONTEXT: \`4096 on ctx-a; 2048 on ctx-b\`"
	assert_output --partial "${w} KUBE_VERSIONS changed during the pass (its platform-drift.txt): v1.33.1 to v1.33.2 on ctx-a, so part of it ran with other Kubernetes versions, and its change against the baseline is not the profile's alone"
	assert_output --partial "${w} TUNING_BASELINE changed during the pass (its platform-drift.txt): sidecar from on to off, so part of it ran with other tuning levers, and its change against the baseline is not the profile's alone"
	assert_output --partial "${w} SIDECAR_EGRESS_HOSTS changed during the pass (its platform-drift.txt): ./* istio-system/* at its start, none at its end, so part of it ran with other root Sidecar egress hosts"
	assert_output --partial "${w} ISTIOD_CPU_LIMIT_M changed during the pass (its platform-drift.txt): 2000 at its start, 4000 at its end, so part of it ran with other istiod CPU limits, and its change against the baseline is not the profile's alone"
	# 004 shows istiod's CPU and memory, not a % of its limit; members whose limits differ are no change.
	refute_output --partial "window-peak"
	refute_output --partial ISTIOD_LIMITS_DIFFER_BY_CONTEXT
	refute_output --partial "pass 02-x differs"
	assert_output --partial "Pass 02-x, changed during the pass on KUBE_VERSIONS, TUNING_BASELINE, SIDECAR_EGRESS_HOSTS, ISTIOD_CPU_LIMIT_M:"
	assert_output --partial "- KUBE_VERSIONS, changed during the pass: \`v1.33.1 to v1.33.2 on ctx-a\`"
	assert_output --partial "- TUNING_BASELINE, changed during the pass: \`sidecar from on to off\`"
	# On stderr, 004's own lines only (U7-S4).
	[[ "$stderr" == *"warning: pass 02-x: KUBE_VERSIONS changed during the pass"* ]]
	[[ "$stderr" != *"during the sweep"* ]]
	! grep -v '^warning: pass' <<<"$stderr" || false
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp 'Platform record +baseline +changed \(see notes\) +same'
	assert_output --regexp '  KUBE_VERSIONS +changed during the pass: v1\.33\.1 to v1\.33\.2 on ctx-a'
	assert_output --partial "WARNING: pass 02-x: TUNING_BASELINE changed during the pass"
	# The baseline's own change: its cell and warning say so, and a pass that ran what it started
	# or ended with matches it, its notes saying which of those it ran (R9-B1).
	mv "${S}/02-x/platform-drift.txt" "${S}/baseline/platform-drift.txt"
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' '# ISTIOD_LIMITS_DIFFER_BY_CONTEXT=ctx-b=1000/2048' > "${S}/02-x/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | same (see notes) | same (see notes) |"
	assert_output --partial "- ISTIOD_CPU_LIMIT_M_BY_CONTEXT: \`mixed: 2000 and 4000 on ctx-a; 1000 on ctx-b\`"
	assert_output --partial "- KUBE_VERSIONS, where the baseline ran more than one value, one of those: \`v1.33.1 on ctx-a\`"
	assert_output --partial "- TUNING_BASELINE, where the baseline ran more than one value, one of those: \`sidecar=on\`"
	assert_output --partial "- SIDECAR_EGRESS_HOSTS, where the baseline ran more than one value, one of those: \`./* istio-system/*\`"
	assert_output --partial "- ISTIOD_CPU_LIMIT_M_BY_CONTEXT, where the baseline ran more than one value, one of those: \`2000 on ctx-a\`"
	# A member that never changed (ctx-b) is not one of those.
	refute_output --partial "one of those: \`1000 on ctx-b\`"
	assert_output --partial "- **Warning:** pass baseline: KUBE_VERSIONS changed during the pass (its platform-drift.txt): v1.33.1 to v1.33.2 on ctx-a, so part of it ran with other Kubernetes versions, and no profile's change against it is the profile's alone"
	assert_output --partial "Pass baseline, changed during the pass on KUBE_VERSIONS, TUNING_BASELINE, SIDECAR_EGRESS_HOSTS, ISTIOD_CPU_LIMIT_M:"
}

@test "tuning 004 (M7-S2, R7-B1): each member's Kubernetes version is compared with the reference pass's; unreachable is not read, never another version" {
	objects_passes
	with_record baseline
	with_record 02-x "s/=0123456789ab/=fedcba987654/g; /^# KUBE_VERSIONS=/s/ctx-b=v1.33.1/ctx-b=v1.34.0/"
	with_record 04-connection-pools "/^# KUBE_VERSIONS=/s/ctx-b=v1.33.1/ctx-b=unreachable/"
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | differs (see notes) | unknown (see notes) |"
	assert_output --partial "- KUBE_VERSIONS: \`v1.33.1\`"
	assert_output --partial "Pass 02-x, differs on KUBE_VERSIONS:"
	assert_output --partial "- KUBE_VERSIONS: \`ctx-b=v1.34.0 (1 of 2 members; the other 1 match)\`"
	assert_output --partial "- **Warning:** pass 02-x differs from the baseline on KUBE_VERSIONS (its values follow the table), so its change against the baseline is not the profile's alone"
	assert_output --partial "Pass 04-connection-pools, cannot be compared on KUBE_VERSIONS:"
	assert_output --partial "- KUBE_VERSIONS: \`ctx-b=unreachable (1 of 2 members; the other 1 match)\`"
	assert_output --partial "- **Warning:** pass 04-connection-pools: KUBE_VERSIONS could not be compared with the baseline (not read, or not recorded, in one of them), so whether it ran on the same platform, builds and Kubernetes versions is not known"
	refute_output --partial "04-connection-pools differs"
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp 'Platform record +baseline +differs \(see notes\) +unknown \(see notes\)'
	assert_output --regexp '  KUBE_VERSIONS +ctx-b=v1\.34\.0 \(1 of 2 members; the other 1 match\)'
}

@test "tuning 004 (U7-B1): istiod settings not read on a member are not other settings: their own warning, the read members' digest; none read reads unknown" {
	local c3=ctx-a,ctx-b,ctx-c
	objects_passes
	# The baseline's and 02-x's ctx-b not read (a PLATFORM_READ_TIMEOUT on its pod list), no member
	# of 04-connection-pools read.
	with_record baseline "s/ctx-b=0123456789ab/ctx-b=unknown/"
	with_record 02-x "s/ctx-a=0123456789ab/ctx-a=fedcba987654/; s/ctx-b=0123456789ab/ctx-b=unknown/"
	with_record 04-connection-pools "s/=0123456789ab/=unknown/g"
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| istiod env | 0123456789ab (see notes) | fedcba987654 (see notes) | unknown (see notes) |"
	assert_output --partial "- **Warning:** pass baseline: istiod's settings could not be read on ctx-b (ISTIOD_ENV_BY_CONTEXT: 0123456789ab on ctx-a; unknown on ctx-b), so whether that member ran the same settings as the others is not known"
	assert_output --partial "- **Warning:** pass 02-x: istiod's settings could not be read on ctx-b (ISTIOD_ENV_BY_CONTEXT: fedcba987654 on ctx-a; unknown on ctx-b), so whether its profile reached that member is not known"
	assert_output --partial "- **Warning:** pass 04-connection-pools: istiod's settings could not be read on ctx-a, ctx-b (ISTIOD_ENV_BY_CONTEXT: unknown on ctx-a, ctx-b), so whether its profile was in effect is not known"
	assert_output --partial "- ISTIOD_ENV_BY_CONTEXT, by member: \`fedcba987654 on ctx-a; unknown on ctx-b\`"
	# Not read is never "differ", and the read members are still checked against the baseline's.
	refute_output --partial "differ between its members"
	refute_output --partial "by member (see notes)"
	refute_output --partial "though its profile sets"
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp 'istiod env +0123456789ab \(see notes\) +fedcba987654 \(see notes\) +unknown \(see notes\)'
	# Two members read that differ and one not read: "differ" names the two read ones only.
	PLATFORM_FIXTURE_CTXS="$c3" objects_passes
	PLATFORM_FIXTURE_CTXS="$c3" with_record baseline
	PLATFORM_FIXTURE_CTXS="$c3" with_record 02-x "s/ctx-b=0123456789ab/ctx-b=fedcba987654/; s/ctx-c=0123456789ab/ctx-c=unknown/"
	PLATFORM_FIXTURE_CTXS="$c3" with_record 04-connection-pools
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| istiod env | 0123456789ab | by member (see notes) | 0123456789ab |"
	assert_output --partial "- **Warning:** pass 02-x: istiod's settings differ between its members (ISTIOD_ENV_BY_CONTEXT: 0123456789ab on ctx-a; fedcba987654 on ctx-b), so they did not all run the same configuration; the profile may have reached some of them only"
	assert_output --partial "- **Warning:** pass 02-x: istiod's settings could not be read on ctx-c (ISTIOD_ENV_BY_CONTEXT: 0123456789ab on ctx-a; fedcba987654 on ctx-b; unknown on ctx-c)"
}

@test "tuning 004 (M7-S1, I7-S1): istiod pods on different settings at once warn; each pod's digest is compared with the baseline's" {
	objects_passes
	with_record baseline
	# 02-x sets istiod's env, but one istiod pod per member still ran the baseline's settings (a
	# rollout caught midway, a pod stuck Terminating); 04 sets none, but a pod on ctx-b ran others.
	with_record 02-x "s/=0123456789ab/=fedcba987654+0123456789ab/g"
	with_record 04-connection-pools "s/ctx-b=0123456789ab/ctx-b=0123456789ab+fedcba987654/"
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| istiod env | 0123456789ab | fedcba987654+0123456789ab (see notes) | by member (see notes) |"
	assert_output --partial "- **Warning:** pass 02-x: istiod's pods ran different settings at once (ISTIOD_ENV_BY_CONTEXT: fedcba987654+0123456789ab on ctx-a, ctx-b, each pod's digest \"+\"-joined): a rollout caught midway (a short --settle), a pod stuck Terminating or a second istiod Deployment, so part of the pass may have run other settings"
	assert_output --partial "- **Warning:** pass 02-x: istiod's settings are the baseline's (ISTIOD_ENV_BY_CONTEXT: fedcba987654+0123456789ab on ctx-a, ctx-b), though its profile sets spec.values.pilot.env"
	assert_output --partial "- **Warning:** pass 04-connection-pools: istiod's pods ran different settings at once (ISTIOD_ENV_BY_CONTEXT: 0123456789ab+fedcba987654 on ctx-b,"
	assert_output --partial "- **Warning:** pass 04-connection-pools: istiod's settings are not the baseline's (ISTIOD_ENV_BY_CONTEXT: 0123456789ab+fedcba987654 on ctx-b), though its profile does not patch the Istio CR"
	[[ "$stderr" == *"warning: pass 02-x: istiod's pods ran different settings at once"* ]]
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp 'istiod env +0123456789ab +fedcba987654\+0123456789ab \(see notes\) +by member \(see notes\)'
}

# lever_passes [levers hosts cpu mem, for 02-x] [the same, for 04-connection-pools]: objects_passes
# with records and each pass's levers (the baseline's the charts': with_levers), 02-x setting
# istiod's env and 04-connection-pools adding a DestinationRule, as their profiles do.
lever_passes() {
	objects_passes
	with_record baseline
	with_record 02-x "s/=0123456789ab/=fedcba987654/g"
	with_record 04-connection-pools
	with_levers baseline
	with_levers 02-x "${1:-}" "${2:-}" "${3:-}" "${4:-}"
	with_levers 04-connection-pools "${5:-}" "${6:-}" "${7:-}" "${8:-}"
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
}

@test "tuning 004 (M8-B1, I8-B1): the levers, the root Sidecar's egress hosts and istiod's limits are compared between passes; one that no profile sets differs and warns" {
	# 02-x without the root Sidecar, 04-connection-pools with istiod's CPU limit doubled; neither
	# profile sets them, and neither changed during its pass (each pass's own read).
	lever_passes "$SIDECAR_OFF" none "" "" "" "" 4000
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | differs (see notes) | differs (see notes) |"
	assert_output --partial "- **Warning:** pass 02-x differs from the baseline on TUNING_BASELINE (sidecar), SIDECAR_EGRESS_HOSTS (its values follow the table), so its change against the baseline is not the profile's alone"
	assert_output --partial "- **Warning:** pass 04-connection-pools differs from the baseline on ISTIOD_CPU_LIMIT_M_BY_CONTEXT (its values follow the table), so its change against the baseline is not the profile's alone"
	# The baseline's values once, then each pass's that differ.
	assert_output --partial "- TUNING_BASELINE: \`${LEVERS_ON}\`"
	assert_output --partial "- SIDECAR_EGRESS_HOSTS: \`./* istio-system/*\`"
	assert_output --partial "- ISTIOD_CPU_LIMIT_M_BY_CONTEXT: \`2000\`"
	assert_output --partial "- ISTIOD_MEM_LIMIT_MI_BY_CONTEXT: \`4096\`"
	assert_output --partial "Pass 02-x, differs on TUNING_BASELINE (sidecar), SIDECAR_EGRESS_HOSTS:"
	assert_output --partial "- TUNING_BASELINE: \`${SIDECAR_OFF}\`"
	assert_output --partial "- SIDECAR_EGRESS_HOSTS: \`none\`"
	assert_output --partial "Pass 04-connection-pools, differs on ISTIOD_CPU_LIMIT_M_BY_CONTEXT:"
	assert_output --partial "- ISTIOD_CPU_LIMIT_M_BY_CONTEXT: \`4000\`"
	[[ "$stderr" == *"warning: pass 02-x differs from the baseline on TUNING_BASELINE (sidecar), SIDECAR_EGRESS_HOSTS"* ]]
	[[ "$stderr" == *"warning: pass 04-connection-pools differs from the baseline on ISTIOD_CPU_LIMIT_M_BY_CONTEXT"* ]]
	! grep -v '^warning: pass' <<<"$stderr" || false
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp 'Platform record +baseline +differs \(see notes\) +differs \(see notes\)'
	assert_output --regexp '  ISTIOD_CPU_LIMIT_M_BY_CONTEXT +4000'
	# The same levers and limits on every pass: same.
	lever_passes
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | same |"
	[ -z "$stderr" ]
}

@test "tuning 004 (M8-B1): a lever that changed during a pass and stayed changed: that pass reads changed, the next one differs" {
	# The root Sidecar went away during 02-x (its read at the end) and stayed gone through 04.
	lever_passes "" "" "" "" "$SIDECAR_OFF" none
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' "# TUNING_BASELINE=${SIDECAR_OFF}" '# SIDECAR_EGRESS_HOSTS=none' > "${S}/02-x/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | changed (see notes) | differs (see notes) |"
	assert_output --partial "- **Warning:** pass 02-x: TUNING_BASELINE changed during the pass (its platform-drift.txt): sidecar from on to off, so part of it ran with other tuning levers"
	assert_output --partial "- **Warning:** pass 04-connection-pools differs from the baseline on TUNING_BASELINE (sidecar), SIDECAR_EGRESS_HOSTS (its values follow the table), so its change against the baseline is not the profile's alone"
	refute_output --partial "pass 02-x differs"
}

@test "tuning 004 (M8-B1, I8-B1): what a pass's profile sets is shown, not warned: its own root Sidecar, discoverySelectors, istiod's limits" {
	objects_passes
	with_record baseline
	with_record 02-x "s/=0123456789ab/=fedcba987654/g"
	with_record 04-connection-pools
	# A lab without the charts' root Sidecar: 04's profile brings its own. 02-x's patch sets
	# discoverySelectors (to none: the lever reads off) and istiod's limits.
	with_levers baseline "$SIDECAR_OFF" none
	with_levers 02-x "sidecar=off,discoverySelectors=off,telemetryFiltering=on,accessLogFiltering=on" none 4000 8192
	with_levers 04-connection-pools
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	echo '{"spec":{"values":{"meshConfig":{"discoverySelectors":[]},"pilot":{"env":{"PILOT_DEBOUNCE_AFTER":"x"},"resources":{"limits":{"cpu":"4","memory":"8Gi"}}}}}}' > "${S}/02-x/state/patch.json"
	profile_pass 04-connection-pools "" Sidecar/istio-system/default
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same (see notes) | same (see notes) |"
	assert_output --partial "- TUNING_BASELINE, set by its profile (discoverySelectors: its state/patch.json sets spec.values.meshConfig.discoverySelectors): \`sidecar=off,discoverySelectors=off,telemetryFiltering=on,accessLogFiltering=on\`"
	assert_output --partial "- ISTIOD_CPU_LIMIT_M_BY_CONTEXT, set by its profile (its state/patch.json sets spec.values.pilot.resources.limits.cpu): \`4000\`"
	assert_output --partial "- ISTIOD_MEM_LIMIT_MI_BY_CONTEXT, set by its profile (its state/patch.json sets spec.values.pilot.resources.limits.memory): \`8192\`"
	assert_output --partial "- TUNING_BASELINE, set by its profile (sidecar: its state/objects lists Sidecar/istio-system/default): \`${LEVERS_ON}\`"
	assert_output --partial "- SIDECAR_EGRESS_HOSTS, set by its profile (its state/objects lists Sidecar/istio-system/default): \`./* istio-system/*\`"
	refute_output --partial "Warning"
	[ -z "$stderr" ]
	# A patch that removes istiod's resources (null: a value above the limits) sets them too.
	echo '{"spec":{"values":{"meshConfig":{"discoverySelectors":[]},"pilot":{"env":{"PILOT_DEBOUNCE_AFTER":"x"},"resources":null}}}}' > "${S}/02-x/state/patch.json"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same (see notes) | same (see notes) |"
	[ -z "$stderr" ]
	# A patch of istiod's env only sets none of them: the limits differ and warn.
	echo '{"spec":{"values":{"pilot":{"env":{"PILOT_DEBOUNCE_AFTER":"x"}}}}}' > "${S}/02-x/state/patch.json"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "- **Warning:** pass 02-x differs from the baseline on TUNING_BASELINE (discoverySelectors), ISTIOD_CPU_LIMIT_M_BY_CONTEXT, ISTIOD_MEM_LIMIT_MI_BY_CONTEXT (its values follow the table)"
	# Without a baseline, what the reference pass's profile sets counts too, and the note says whose.
	echo '{"spec":{"values":{"meshConfig":{"discoverySelectors":[]},"pilot":{"env":{"PILOT_DEBOUNCE_AFTER":"x"},"resources":{"limits":{"cpu":"4","memory":"8Gi"}}}}}}' > "${S}/02-x/state/patch.json"
	mkdir -p "${BATS_TEST_TMPDIR}/gone"
	mv "${S}/baseline" "${BATS_TEST_TMPDIR}/gone/"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | - | reference | same (see notes) |"
	assert_output --partial "- TUNING_BASELINE, set by its and the reference pass's profiles (sidecar: its state/objects lists Sidecar/istio-system/default; discoverySelectors: the reference pass's state/patch.json sets spec.values.meshConfig.discoverySelectors): \`${LEVERS_ON}\`"
	assert_output --partial "- ISTIOD_CPU_LIMIT_M_BY_CONTEXT, set by the reference pass's profile (the reference pass's state/patch.json sets spec.values.pilot.resources.limits.cpu): \`2000\`"
	refute_output --partial "differs"
}

@test "tuning 004 (M8-B1): a lever or limit not read on a side is not known: unknown (see notes) with its own warning, never differs" {
	objects_passes
	with_record baseline
	with_record 02-x "s/=0123456789ab/=fedcba987654/g"
	with_record 04-connection-pools
	with_levers baseline "sidecar=unknown,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on" unknown
	with_levers 02-x "$SIDECAR_OFF" none
	with_levers 04-connection-pools "" "" unknown
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | unknown (see notes) | unknown (see notes) |"
	assert_output --partial "- **Warning:** pass 02-x: TUNING_BASELINE (sidecar), SIDECAR_EGRESS_HOSTS could not be compared with the baseline (not read, or not recorded, in one of them), so whether it ran with the same tuning levers and root Sidecar egress hosts is not known"
	assert_output --partial "- **Warning:** pass 04-connection-pools: TUNING_BASELINE (sidecar), SIDECAR_EGRESS_HOSTS, ISTIOD_CPU_LIMIT_M_BY_CONTEXT could not be compared with the baseline (not read, or not recorded, in one of them), so whether it ran with the same tuning levers, root Sidecar egress hosts and istiod limits is not known"
	assert_output --partial "Pass 04-connection-pools, cannot be compared on TUNING_BASELINE (sidecar), SIDECAR_EGRESS_HOSTS, ISTIOD_CPU_LIMIT_M_BY_CONTEXT:"
	assert_output --partial "- ISTIOD_CPU_LIMIT_M_BY_CONTEXT: \`unknown\`"
	refute_output --partial "differs"
}

@test "tuning 004 (U8-B1): a key the baseline changed on during its pass is still compared member by member: one of the baseline's values is the same, another member's change or a third value differs" {
	objects_passes
	with_record baseline
	# 02-x on the value the baseline's ctx-a ended on; 04 also on another version on ctx-b, which
	# never changed during the baseline (an upgrade rolling through the members).
	with_record 02-x "s/=0123456789ab/=fedcba987654/g; /^# KUBE_VERSIONS=/s/ctx-a=v1.33.1/ctx-a=v1.33.2/"
	with_record 04-connection-pools "/^# KUBE_VERSIONS=/s/ctx-a=v1.33.1/ctx-a=v1.33.2/; /^# KUBE_VERSIONS=/s/ctx-b=v1.33.1/ctx-b=v1.33.2/"
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' '# KUBE_VERSIONS=ctx-a=v1.33.2' > "${S}/baseline/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | same (see notes) | differs (see notes) |"
	assert_output --partial "- KUBE_VERSIONS: \`mixed: v1.33.1 and v1.33.2 on ctx-a; v1.33.1 on ctx-b\`"
	assert_output --partial "- **Warning:** pass 04-connection-pools differs from the baseline on KUBE_VERSIONS (its values follow the table), so its change against the baseline is not the profile's alone"
	# Only the member that differs (U9-S3), and on ctx-a which of the baseline's values (R9-B1).
	assert_output --partial "- KUBE_VERSIONS: \`ctx-b=v1.33.2 (1 of 2 members; the other 1 match)\`"
	assert_output --partial "- KUBE_VERSIONS, where the baseline ran more than one value, one of those: \`v1.33.2 on ctx-a\`"
	refute_output --partial "pass 02-x differs"
	# A build the baseline ended with on every member, and a third one.
	objects_passes
	with_record baseline
	with_record 02-x "s/=0123456789ab/=fedcba987654/g; s/pilot:1.30.5/pilot:1.30.6/g"
	with_record 04-connection-pools "s/pilot:1.30.5/pilot:1.30.7/g"
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' '# ISTIOD_IMAGE_BY_CONTEXT=ctx-a=pilot:1.30.6,ctx-b=pilot:1.30.6' > "${S}/baseline/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | same (see notes) | differs (see notes) |"
	assert_output --partial "- **Warning:** pass 04-connection-pools differs from the baseline on ISTIOD_IMAGE_BY_CONTEXT"
	# Every member differs: the value once.
	assert_output --partial "- ISTIOD_IMAGE_BY_CONTEXT: \`pilot:1.30.7\`"
	assert_output --partial "- ISTIOD_IMAGE_BY_CONTEXT, where the baseline ran more than one value, one of those: \`pilot:1.30.6 on ctx-a, ctx-b\`"
}

@test "tuning 004 (M8-S1): a pass whose read at its end could not compare a value, or that was not read again at its end, reads unknown and warns" {
	objects_passes
	with_record baseline
	with_record 02-x "s/=0123456789ab/=fedcba987654/g"
	with_record 04-connection-pools
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	# 02-x's read at its end could not compare ctx-b's Kubernetes version and istiod build; 04 has
	# no drift file (the run stopped during it).
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' '# NOT_COMPARED_AT_END=ctx-b=KUBE_VERSIONS;ISTIOD_IMAGE_BY_CONTEXT' > "${S}/02-x/platform-drift.txt"
	mkdir -p "${BATS_TEST_TMPDIR}/gone"
	mv "${S}/04-connection-pools/platform-drift.txt" "${BATS_TEST_TMPDIR}/gone/"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | unknown (see notes) | unknown (see notes) |"
	assert_output --partial "- **Warning:** pass 02-x: the read again at its end (its platform-drift.txt) could not compare KUBE_VERSIONS on ctx-b; ISTIOD_IMAGE_BY_CONTEXT on ctx-b (not read at its start or end, or read with a digest @unknown: no pod had started), so whether those values changed during the pass is not known, nor whether its change against the baseline is the profile's alone"
	assert_output --partial "- **Warning:** pass 04-connection-pools: its record was not read again at its end (no platform-drift.txt in its directory: the run stopped during the pass, or it predates that read), so whether its builds, Kubernetes versions, tuning levers, istiod limits or replica counts changed during it is not known, nor whether its change against the baseline is the profile's alone"
	assert_output --partial "Pass 02-x, not compared at its end on KUBE_VERSIONS, ISTIOD_IMAGE_BY_CONTEXT:"
	assert_output --partial "- KUBE_VERSIONS, not compared at its end: ctx-b"
	assert_output --partial "Pass 04-connection-pools, not read again at its end:"
	assert_output --partial "- platform-drift.txt: none in its directory: its record was not read again at its end"
	[[ "$stderr" == *"warning: pass 04-connection-pools: its record was not read again at its end"* ]]
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp 'Platform record +baseline +unknown \(see notes\) +unknown \(see notes\)'
	assert_output --regexp '  KUBE_VERSIONS +not compared at its end: ctx-b'
	# The baseline's own: its cell says so, and one warning names both passes (U9-S2) and what
	# then is not known of every pass (M9-N2).
	mv "${S}/baseline/platform-drift.txt" "${BATS_TEST_TMPDIR}/gone/baseline-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | unknown (see notes) | unknown (see notes) |"
	assert_output --partial "- **Warning:** passes baseline, 04-connection-pools: their records were not read again at their end (no platform-drift.txt in their directories: the runs stopped during them, or they predate that read), so whether their builds, Kubernetes versions, tuning levers, istiod limits or replica counts changed during them is not known, nor whether any profile's change against the baseline is the profile's alone"
	[[ "$(grep -c 'not read again at' <<<"$stderr")" == 1 ]]
	refute_output --partial "pass baseline: its record was not read again"
}

@test "tuning 004 (SC8-S3): the reference pass's record names the members of a value they do not all share, five at most" {
	local odd=scale-campaign-region-a-member-007.example.invalid
	PLATFORM_FIXTURE_CTXS="$(wide_ctxs 500)" with_record baseline "/^# KUBE_VERSIONS=/s/${odd}=v1.33.1/${odd}=v1.34.0/"
	PLATFORM_FIXTURE_CTXS="$(wide_ctxs 500)" with_record 01-x "/^# KUBE_VERSIONS=/s/${odd}=v1.33.1/${odd}=v1.34.0/"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same |"
	assert_output --partial "- KUBE_VERSIONS: \`v1.33.1 on scale-campaign-region-a-member-001.example.invalid, scale-campaign-region-a-member-002.example.invalid, scale-campaign-region-a-member-003.example.invalid, scale-campaign-region-a-member-004.example.invalid, scale-campaign-region-a-member-005.example.invalid and 494 more; v1.34.0 on ${odd}\`"
	# No line names every member.
	awk 'length > 2000 { bad = 1 } END { exit bad }' <<<"$output"
}

# with_replicas <pass> <value> [key]: the istiod replica counts its TSV records, as the
# controlplane suite does (ISTIOD_REPLICAS_BY_CONTEXT: every member), or under ISTIOD_REPLICAS as
# propagation (<ctx>=<n>,...: every member) or churn and churn-dataplane (<n>: the source
# member's) do; replaces what it recorded.
with_replicas() {
	local f
	f="$(ls "${S}/$1"/controlplane-*.tsv)"
	{ printf '# %s=%s\n' "${3:-ISTIOD_REPLICAS_BY_CONTEXT}" "$2"; grep -v '^# ISTIOD_REPLICAS' "$f"; } > "${f}.new"
	mv "${f}.new" "$f"
}

@test "tuning 004 (I9-B1): istiod's replica counts are compared member by member: one no profile sets differs and warns; one its profile sets is shown, or not in effect on a member that did not run it" {
	lever_passes
	with_replicas baseline ctx-a=1,ctx-b=1
	with_replicas 02-x ctx-a=1,ctx-b=1
	with_replicas 04-connection-pools ctx-a=2,ctx-b=1
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | differs (see notes) |"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`1\`"
	assert_output --partial "- **Warning:** pass 04-connection-pools differs from the baseline on ISTIOD_REPLICAS_BY_CONTEXT (its values follow the table), so its change against the baseline is not the profile's alone"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`ctx-a=2 (1 of 2 members; the other 1 match)\`"
	refute_output --partial "pass 02-x differs"
	# Its profile sets the count and every member ran it: shown, not warned.
	echo '{"spec":{"values":{"pilot":{"replicaCount":2}}}}' > "${S}/04-connection-pools/state/patch.json"
	with_replicas 04-connection-pools ctx-a=2,ctx-b=2
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | same (see notes) |"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT, set by its profile (its state/patch.json sets spec.values.pilot.replicaCount): \`2\`"
	[ -z "$stderr" ]
	# A member that did not run it: not in effect there (M9-B1), even where it matches the baseline.
	with_replicas 04-connection-pools ctx-a=2,ctx-b=1
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | not in effect (see notes) |"
	assert_output --partial "- **Warning:** pass 04-connection-pools: its profile sets istiod's replica count to 2 (spec.values.pilot.replicaCount in its state/patch.json), yet ISTIOD_REPLICAS_BY_CONTEXT reads 1 on ctx-b, so the profile's value was not in effect there all through the pass (not rolled out there, changed during it, or set by an HPA), and its change against the baseline is not the profile's alone"
	assert_output --partial "Pass 04-connection-pools, its profile's value not in effect on ISTIOD_REPLICAS_BY_CONTEXT:"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT, the profile's 2 not in effect: \`1 on ctx-b\`"
	[[ "$stderr" == *"warning: pass 04-connection-pools: its profile sets istiod's replica count to 2"* ]]
	# Autoscaling turned on: its HPA sets the count, so replicaCount is not checked.
	echo '{"spec":{"values":{"pilot":{"autoscaleEnabled":true,"replicaCount":2}}}}' > "${S}/04-connection-pools/state/patch.json"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | same (see notes) |"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT, set by its profile (its state/patch.json sets spec.values.pilot.replicaCount, spec.values.pilot.autoscaleEnabled): \`ctx-a=2 (1 of 2 members; the other 1 match)\`"
	refute_output --partial "not in effect"
	# The text format: the key column as wide as the longest key (U9-N1).
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp 'Platform record +baseline +same +same \(see notes\)'
	assert_output --partial "  ISTIOD_MEM_LIMIT_MI_BY_CONTEXT 4096"
	assert_output --partial "  PLATFORM                       kubernetes"
}

@test "tuning 004 (I9-B1): the replica counts as propagation and the churn suites record them, each member by its name in the record" {
	local p
	lever_passes
	# propagation: every member's Running istiod pods.
	for p in baseline 04-connection-pools; do with_replicas "$p" ctx-a=1,ctx-b=1 ISTIOD_REPLICAS; done
	with_replicas 02-x ctx-a=1,ctx-b=2 ISTIOD_REPLICAS
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | differs (see notes) | same |"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`1\`"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`ctx-b=2 (1 of 2 members; the other 1 match)\`"
	# churn and churn-dataplane: the source member's (the first of the record), named as such.
	for p in baseline 04-connection-pools; do with_replicas "$p" 1 ISTIOD_REPLICAS; done
	with_replicas 02-x 3 ISTIOD_REPLICAS
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | differs (see notes) | same |"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`1 on ctx-a\`"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`3 on ctx-a\`"
	# A pass of another suite's form (the source member's only) against a record of every member's:
	# the member it does not record is named, never behind the value it shows.
	with_replicas baseline ctx-a=1,ctx-b=1 ISTIOD_REPLICAS
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`ctx-a=3, ctx-b not recorded (all 2 members)\`"
	# Equal counts on every pass: nothing to say.
	for p in baseline 02-x 04-connection-pools; do with_replicas "$p" 1 ISTIOD_REPLICAS; done
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | same |"
	[ -z "$stderr" ]
}

@test "tuning 004 (M9-B1): istiod's limits its profile sets that a member did not run are not in effect there: warned, whatever the baseline ran; one already in place says nothing; a suite that records none warns" {
	# 04's profile sets istiod's CPU limit to 4 (4000m); its read at the end found 2000m on ctx-b.
	lever_passes "" "" "" "" "" "" 4000
	echo '{"spec":{"values":{"pilot":{"resources":{"limits":{"cpu":"4"}}}}}}' > "${S}/04-connection-pools/state/patch.json"
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' '# ISTIOD_LIMITS_DIFFER_BY_CONTEXT=ctx-b=2000/4096' > "${S}/04-connection-pools/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | not in effect (see notes) |"
	assert_output --partial "- **Warning:** pass 04-connection-pools: its profile sets istiod's CPU limit to 4000m (spec.values.pilot.resources.limits.cpu in its state/patch.json), yet ISTIOD_CPU_LIMIT_M_BY_CONTEXT reads 2000m on ctx-b, so the profile's value was not in effect there all through the pass (not rolled out there, or changed during it), and its change against the baseline is not the profile's alone"
	assert_output --partial "- ISTIOD_CPU_LIMIT_M_BY_CONTEXT, the profile's 4000m not in effect: \`2000m on ctx-b\`"
	refute_output --partial "04-connection-pools differs"
	# On no member: the pass reads the baseline's limit, which the profile's value would change.
	lever_passes
	echo '{"spec":{"values":{"pilot":{"resources":{"limits":{"cpu":"4"}}}}}}' > "${S}/04-connection-pools/state/patch.json"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | not in effect (see notes) |"
	assert_output --partial "yet ISTIOD_CPU_LIMIT_M_BY_CONTEXT reads 2000m on ctx-a, ctx-b, so the profile's value was not in effect there all through the pass"
	# A third value: not in effect, not another difference from the baseline.
	lever_passes "" "" "" "" "" "" 3000
	echo '{"spec":{"values":{"pilot":{"resources":{"limits":{"cpu":"4000m"}}}}}}' > "${S}/04-connection-pools/state/patch.json"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | not in effect (see notes) |"
	assert_output --partial "yet ISTIOD_CPU_LIMIT_M_BY_CONTEXT reads 3000m on ctx-a, ctx-b"
	# What was already in place (2000m, the baseline's too): nothing to say.
	lever_passes
	echo '{"spec":{"values":{"pilot":{"resources":{"limits":{"cpu":"2","memory":"4Gi"}}}}}}' > "${S}/04-connection-pools/state/patch.json"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | same |"
	[ -z "$stderr" ]
	# TSVs that do not record istiod's limits (every suite but controlplane): not known, in its
	# cell and notes too (M10-B1).
	objects_passes
	sed -i 's/^# SUITE=controlplane$/# SUITE=propagation/' "${S}/sweep-metadata.txt"
	with_record baseline
	with_record 02-x "s/=0123456789ab/=fedcba987654/g"
	with_record 04-connection-pools
	profile_pass 02-x PILOT_DEBOUNCE_AFTER
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	echo '{"spec":{"values":{"pilot":{"resources":{"limits":{"memory":"8Gi"}}}}}}' > "${S}/04-connection-pools/state/patch.json"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | unknown (see notes) |"
	assert_output --partial "- **Warning:** pass 04-connection-pools: its profile sets istiod's memory limit to 8192Mi (spec.values.pilot.resources.limits.memory in its state/patch.json), which its TSVs do not record (only the controlplane suite's TSVs record istiod's limits), so whether it was in effect on any member is not known, nor whether its change against the baseline is the profile's alone"
	assert_output --partial "Pass 04-connection-pools, its profile's value not known to be in effect on ISTIOD_MEM_LIMIT_MI_BY_CONTEXT:"
	assert_output --partial "- ISTIOD_MEM_LIMIT_MI_BY_CONTEXT, the profile's 8192Mi not known to be in effect: not recorded (only the controlplane suite's TSVs record istiod's limits)"
	# A controlplane TSV without them: from before the key.
	sed -i 's/^# SUITE=propagation$/# SUITE=controlplane/' "${S}/sweep-metadata.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | unknown (see notes) |"
	assert_output --partial "which its TSVs do not record (its TSVs predate the key), so whether it was in effect on any member is not known"
}

@test "tuning 004 (M10-B1): a replica count its profile sets that its TSVs do not record on a member (the churn suites' source member only) is not known there, never in effect; with or without a baseline" {
	local p
	lever_passes
	sed -i 's/^# SUITE=controlplane$/# SUITE=churn/' "${S}/sweep-metadata.txt"
	for p in baseline 02-x; do with_replicas "$p" 1 ISTIOD_REPLICAS; done
	with_replicas 04-connection-pools 2 ISTIOD_REPLICAS
	echo '{"spec":{"values":{"pilot":{"replicaCount":2}}}}' > "${S}/04-connection-pools/state/patch.json"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | unknown (see notes) |"
	assert_output --partial "- **Warning:** pass 04-connection-pools: its profile sets istiod's replica count to 2 (spec.values.pilot.replicaCount in its state/patch.json), which its TSVs do not record on ctx-b (the churn suite's TSVs record the source member's only), so whether it was in effect there is not known, nor whether its change against the baseline is the profile's alone"
	assert_output --partial "Pass 04-connection-pools, its profile's value not known to be in effect on ISTIOD_REPLICAS_BY_CONTEXT:"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT, set by its profile (its state/patch.json sets spec.values.pilot.replicaCount): \`2 on ctx-a\`"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT, the profile's 2 not known to be in effect: not recorded on ctx-b (the churn suite's TSVs record the source member's only)"
	[[ "$(grep -c '^warning: ' <<<"$stderr")" == 1 ]]
	# The source member did not run it either: not in effect there, and still not known on ctx-b.
	with_replicas 04-connection-pools 1 ISTIOD_REPLICAS
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | not in effect (see notes) |"
	assert_output --partial "yet ISTIOD_REPLICAS_BY_CONTEXT reads 1 on ctx-a, so the profile's value was not in effect there all through the pass (not rolled out there, changed between its TSVs, set by an HPA, or a Terminating pod still counted as Running after a short --settle)"
	assert_output --partial "which its TSVs do not record on ctx-b (the churn suite's TSVs record the source member's only)"
	assert_output --partial "Pass 04-connection-pools, its profile's value not in effect on ISTIOD_REPLICAS_BY_CONTEXT, its profile's value not known to be in effect on ISTIOD_REPLICAS_BY_CONTEXT:"
	# Without a baseline, the reference pass is a profile pass: its own cell says so.
	mkdir -p "${BATS_TEST_TMPDIR}/gone"
	mv "${S}/baseline" "${BATS_TEST_TMPDIR}/gone/"
	printf '# SUITE=churn\n# PASSES=04-connection-pools,02-x\n' > "${S}/sweep-metadata.txt"
	with_replicas 04-connection-pools 2 ISTIOD_REPLICAS
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | reference (see notes) |"
	assert_output --partial "- **Warning:** pass 04-connection-pools: its profile sets istiod's replica count to 2 (spec.values.pilot.replicaCount in its state/patch.json), which its TSVs do not record on ctx-b (the churn suite's TSVs record the source member's only), so whether it was in effect there is not known, nor whether any pass's difference from it is the profiles' alone"
	# Every member recorded (propagation's form) and running it: nothing to say.
	printf '# SUITE=propagation\n# PASSES=04-connection-pools,02-x\n' > "${S}/sweep-metadata.txt"
	with_replicas 04-connection-pools ctx-a=2,ctx-b=2 ISTIOD_REPLICAS
	with_replicas 02-x ctx-a=2,ctx-b=2 ISTIOD_REPLICAS
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | reference | same |"
	refute_output --partial "not known to be in effect"
}

@test "tuning 004 (C10-S2): at 500 members, what a profile's value was not in effect on, not recorded on, and which of the baseline's values a pass ran each name five members, then how many more" {
	local ctxs base="" pass="" diff="" kv="" kv2="" i m
	local -a arr=()
	ctxs="$(wide_ctxs 500)"
	PLATFORM_FIXTURE_CTXS="$ctxs" lever_passes "" "" "" "" "" "" 4000
	IFS=',' read -r -a arr <<<"$ctxs"
	for i in "${!arr[@]}"; do
		m="${arr[i]}"
		base+="${base:+,}${m}=1"
		# 497 members on the baseline's count, three on the profile's.
		if ((i < 497)); then pass+="${pass:+,}${m}=1"; else pass+="${pass:+,}${m}=2"; fi
		((i == 0)) || diff+="${diff:+,}${m}=2000/4096"
		kv+="${kv:+,}${m}=v1.33.2"
	done
	with_replicas baseline "$base"
	with_replicas 02-x "$base"
	with_replicas 04-connection-pools "$pass"
	# 04's profile sets the count to 2 and the CPU limit to 4000m: ran on three members and on one.
	echo '{"spec":{"values":{"pilot":{"replicaCount":2,"resources":{"limits":{"cpu":"4"}}}}}}' > "${S}/04-connection-pools/state/patch.json"
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' "# ISTIOD_LIMITS_DIFFER_BY_CONTEXT=${diff}" > "${S}/04-connection-pools/platform-drift.txt"
	# Every member's Kubernetes version changed during the baseline; 02-x ran the new one.
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' "# KUBE_VERSIONS=${kv}" > "${S}/baseline/platform-drift.txt"
	sed -i "/^# KUBE_VERSIONS=/s/v1\.33\.1/v1.33.2/g" "${S}/02-x/controlplane-02-x.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | same (see notes) | not in effect (see notes) |"
	assert_output --partial "yet ISTIOD_CPU_LIMIT_M_BY_CONTEXT reads 2000m on ${arr[1]}, ${arr[2]}, ${arr[3]}, ${arr[4]}, ${arr[5]} and 494 more, so the profile's value was not in effect there"
	assert_output --partial "yet ISTIOD_REPLICAS_BY_CONTEXT reads 1 on ${arr[0]}, ${arr[1]}, ${arr[2]}, ${arr[3]}, ${arr[4]} and 492 more, so the profile's value was not in effect there"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT, the profile's 2 not in effect: \`1 on ${arr[0]}, ${arr[1]}, ${arr[2]}, ${arr[3]}, ${arr[4]} and 492 more\`"
	assert_output --partial "- KUBE_VERSIONS, where the baseline ran more than one value, one of those: \`v1.33.2 on ${arr[0]}, ${arr[1]}, ${arr[2]}, ${arr[3]}, ${arr[4]} and 495 more\`"
	awk 'length > 1000 { bad = 1 } END { exit bad }' <<<"$output"
	awk 'length > 1000 { bad = 1 } END { exit bad }' <<<"$stderr"
	# The churn suites' form: the 499 other members are not recorded.
	sed -i 's/^# SUITE=controlplane$/# SUITE=churn/' "${S}/sweep-metadata.txt"
	for m in baseline 02-x; do with_replicas "$m" 1 ISTIOD_REPLICAS; done
	with_replicas 04-connection-pools 2 ISTIOD_REPLICAS
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "which its TSVs do not record on ${arr[1]}, ${arr[2]}, ${arr[3]}, ${arr[4]}, ${arr[5]} and 494 more (the churn suite's TSVs record the source member's only)"
	awk 'length > 1000 { bad = 1 } END { exit bad }' <<<"$output"
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	awk 'length > 1000 { bad = 1 } END { exit bad }' <<<"$output"
}

@test "tuning 004 (R9-B1): where the baseline ran two values (a lever that changed during it), each pass's notes say which of them it ran" {
	lever_passes "" "" "" "" "$SIDECAR_OFF" none
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' "# TUNING_BASELINE=${SIDECAR_OFF}" '# SIDECAR_EGRESS_HOSTS=none' > "${S}/baseline/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | same (see notes) | same (see notes) |"
	assert_output --partial "- TUNING_BASELINE: \`sidecar=mixed: on and off,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on\`"
	assert_output --partial "Pass 02-x:"
	assert_output --partial "- TUNING_BASELINE, where the baseline ran more than one value, one of those: \`sidecar=on\`"
	assert_output --partial "- SIDECAR_EGRESS_HOSTS, where the baseline ran more than one value, one of those: \`./* istio-system/*\`"
	assert_output --partial "Pass 04-connection-pools:"
	assert_output --partial "- TUNING_BASELINE, where the baseline ran more than one value, one of those: \`sidecar=off\`"
	assert_output --partial "- SIDECAR_EGRESS_HOSTS, where the baseline ran more than one value, one of those: \`none\`"
	refute_output --partial "differs"
	# Only the baseline warns, on stderr too.
	[[ "$(grep -c '^warning: ' <<<"$stderr")" == 2 ]]
	! grep -v '^warning: pass baseline:' <<<"$stderr" || false
}

@test "tuning 004 (R9-S1, U9-S1): a value its profile sets that was not read on a side is not known, never set; another member's istiod limits not read at its end warn once, in that read's warning" {
	# 02-x's profile brings its own root Sidecar and sets istiod's CPU limit; its sidecar lever was
	# not read, nor ctx-b's limits at its end.
	objects_passes
	with_record baseline
	with_record 02-x "s/=0123456789ab/=fedcba987654/g"
	with_record 04-connection-pools
	with_levers baseline
	with_levers 02-x "sidecar=unknown,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on" "" 4000
	with_levers 04-connection-pools
	profile_pass 02-x PILOT_DEBOUNCE_AFTER Sidecar/istio-system/default
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	echo '{"spec":{"values":{"pilot":{"env":{"PILOT_DEBOUNCE_AFTER":"x"},"resources":{"limits":{"cpu":"4"}}}}}}' > "${S}/02-x/state/patch.json"
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' '# NOT_COMPARED_AT_END=ctx-b=ISTIOD_LIMITS_DIFFER_BY_CONTEXT' > "${S}/02-x/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | unknown (see notes) | same |"
	assert_output --partial "- **Warning:** pass 02-x: TUNING_BASELINE (sidecar) could not be compared with the baseline (not read, or not recorded, in one of them), so whether it ran with the same tuning levers is not known"
	assert_output --partial "- **Warning:** pass 02-x: the read again at its end (its platform-drift.txt) could not compare istiod's limits on ctx-b (not read at its end, the only read of them), so whether those values changed during the pass is not known, nor whether its change against the baseline is the profile's alone"
	refute_output --partial "ISTIOD_CPU_LIMIT_M_BY_CONTEXT could not be compared"
	refute_output --partial "set by its profile (sidecar"
	assert_output --partial "Pass 02-x, cannot be compared on TUNING_BASELINE (sidecar), ISTIOD_CPU_LIMIT_M_BY_CONTEXT, ISTIOD_MEM_LIMIT_MI_BY_CONTEXT, not compared at its end on istiod's limits:"
	assert_output --partial "- istiod's limits, not read at its end: ctx-b"
	# Without its drift file: the one warning of that pass says it.
	mkdir -p "${BATS_TEST_TMPDIR}/gone"
	mv "${S}/02-x/platform-drift.txt" "${BATS_TEST_TMPDIR}/gone/"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "- **Warning:** pass 02-x: its record was not read again at its end (no platform-drift.txt in its directory: the run stopped during the pass, or it predates that read), so whether its builds, Kubernetes versions, tuning levers, istiod limits or replica counts changed during it is not known, nor its other members' istiod limits, which only that read gives, nor whether its change against the baseline is the profile's alone"
	refute_output --partial "ISTIOD_CPU_LIMIT_M_BY_CONTEXT could not be compared"
}

@test "tuning 004 (I10-S1): a controlplane pass whose istiod replica count changed during it reads changed and warns; a profile that turns autoscaling on has its HPA named" {
	lever_passes
	with_replicas baseline ctx-a=1,ctx-b=1
	with_replicas 02-x ctx-a=1,ctx-b=1
	with_replicas 04-connection-pools ctx-a=1,ctx-b=1
	# What tuning 003's read at 02-x's end found: ctx-b's istiod scaled to 2 during the pass.
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' '# ISTIOD_REPLICAS_BY_CONTEXT=ctx-b=2' > "${S}/02-x/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | changed (see notes) | same |"
	assert_output --partial "- **Warning:** pass 02-x: ISTIOD_REPLICAS_BY_CONTEXT changed during the pass (its platform-drift.txt): 1 to 2 on ctx-b, so part of it ran with other istiod replica counts, and its change against the baseline is not the profile's alone"
	assert_output --partial "Pass 02-x, changed during the pass on ISTIOD_REPLICAS_BY_CONTEXT:"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT, changed during the pass: \`1 to 2 on ctx-b\`"
	refute_output --partial "pass 02-x differs"
	[[ "$stderr" == *"warning: pass 02-x: ISTIOD_REPLICAS_BY_CONTEXT changed during the pass"* ]]
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp 'Platform record +baseline +changed \(see notes\) +same'
	assert_output --regexp '  ISTIOD_REPLICAS_BY_CONTEXT +changed during the pass: 1 to 2 on ctx-b'
	# Its profile turns autoscaling on: its HPA moved the count, and the warning says so.
	echo '{"spec":{"values":{"pilot":{"autoscaleEnabled":true,"env":{"PILOT_DEBOUNCE_AFTER":"x"}}}}}' > "${S}/02-x/state/patch.json"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | changed (see notes) | same |"
	assert_output --partial "- **Warning:** pass 02-x: ISTIOD_REPLICAS_BY_CONTEXT changed during the pass (its platform-drift.txt): 1 to 2 on ctx-b; its profile turns autoscaling on (spec.values.pilot.autoscaleEnabled in its state/patch.json), so its HPA moved the count, and its figures may be over more than one istiod replica count"
	refute_output --partial "so part of it ran with other istiod replica counts"
	# A pass of another suite says its record was not read again for builds, versions, levers and limits only.
	mkdir -p "${BATS_TEST_TMPDIR}/gone"
	mv "${S}/02-x/platform-drift.txt" "${BATS_TEST_TMPDIR}/gone/"
	sed -i 's/^# SUITE=controlplane/# SUITE=propagation/' "${S}/sweep-metadata.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "so whether its builds, Kubernetes versions, tuning levers or istiod limits changed during it is not known"
}

@test "tuning 004 (I12-B1): a pass's note names the member that differs from the baseline ahead of those whose count only changed during the pass" {
	local ctxs=m1,m2,m3,m4,m5,m6,m7 six="" two="" i
	PLATFORM_FIXTURE_CTXS="$ctxs" lever_passes
	for i in 1 2 3 4 5 6; do six+="${six:+,}m${i}=1"; two+="${two:+,}m${i}=2"; done
	with_replicas baseline "${six},m7=1"
	with_replicas 04-connection-pools "${six},m7=1"
	# 02-x: m7 starts on 3 replicas, and m1 to m6 scale from 1 to 2 during the pass.
	with_replicas 02-x "${six},m7=3"
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' "# ISTIOD_REPLICAS_BY_CONTEXT=${two}" > "${S}/02-x/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | differs (see notes) | same |"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`m7=3, m1=mixed: 1 and 2, m2=mixed: 1 and 2, m3=mixed: 1 and 2, m4=mixed: 1 and 2, and 2 more members (all 7 members)\`"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT, changed during the pass: \`1 to 2 on m1, m2, m3, m4, m5 and 1 more\`"
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp '  ISTIOD_REPLICAS_BY_CONTEXT +m7=3, m1=mixed: 1 and 2, '
}

@test "tuning 004 (I13-B1): a pass's note names the member that differs from the baseline ahead of those not read at its probe" {
	local i im="" bi=""
	PLATFORM_FIXTURE_CTXS=m1,m2,m3,m4,m5,m6,m7 lever_passes
	# 02-x: m1 to m6 unreachable at its probe, m7 on another Kubernetes version.
	sed -i 's/^# KUBE_VERSIONS=.*/# KUBE_VERSIONS=m1=unreachable,m2=unreachable,m3=unreachable,m4=unreachable,m5=unreachable,m6=unreachable,m7=v1.33.2/' \
		"${S}/02-x"/controlplane-*.tsv
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | differs (see notes) | same |"
	assert_output --partial "- KUBE_VERSIONS: \`m7=v1.33.2, m1=unreachable, m2=unreachable, m3=unreachable, m4=unreachable, and 2 more members (all 7 members)\`"
	# Its istiod build instead: m1 to m6 with no pod started at its probe (a digest @unknown),
	# m7 on another build.
	sed -i 's/^# KUBE_VERSIONS=.*/# KUBE_VERSIONS=m1=v1.33.1,m2=v1.33.1,m3=v1.33.1,m4=v1.33.1,m5=v1.33.1,m6=v1.33.1,m7=v1.33.1/' \
		"${S}/02-x"/controlplane-*.tsv
	for i in 1 2 3 4 5 6 7; do
		bi+="${bi:+,}m${i}=pilot:1.30.5@$(digest aa)"
		if ((i < 7)); then im+="${im:+,}m${i}=pilot:1.30.5@unknown"; else im+=",m${i}=pilot:1.30.6@$(digest bb)"; fi
	done
	sed -i "s#^\# ISTIOD_IMAGE_BY_CONTEXT=.*#\# ISTIOD_IMAGE_BY_CONTEXT=${bi}#" "${S}/baseline"/controlplane-*.tsv "${S}/04-connection-pools"/controlplane-*.tsv
	sed -i "s#^\# ISTIOD_IMAGE_BY_CONTEXT=.*#\# ISTIOD_IMAGE_BY_CONTEXT=${im}#" "${S}/02-x"/controlplane-*.tsv
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | differs (see notes) | same |"
	assert_output --partial "- ISTIOD_IMAGE_BY_CONTEXT: \`m7=pilot:1.30.6@sha256:bbbbbbbbbbbb, m1=pilot:1.30.5@unknown, m2=pilot:1.30.5@unknown, m3=pilot:1.30.5@unknown, m4=pilot:1.30.5@unknown, and 2 more members (all 7 members)\`"
}

@test "tuning 004 (M11-S2): a pass of a suite that reads istiod's replica count at its start only, whose profile turns autoscaling on, is not known all through the pass: noted and warned" {
	local p
	lever_passes
	sed -i 's/^# SUITE=controlplane$/# SUITE=churn/' "${S}/sweep-metadata.txt"
	for p in baseline 02-x 04-connection-pools; do with_replicas "$p" 1 ISTIOD_REPLICAS; done
	echo '{"spec":{"values":{"pilot":{"autoscaleEnabled":true,"autoscaleMin":1,"autoscaleMax":3}}}}' > "${S}/04-connection-pools/state/patch.json"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | unknown (see notes) |"
	assert_output --partial "- **Warning:** pass 04-connection-pools: its profile turns istiod's autoscaling on (spec.values.pilot.autoscaleEnabled in its state/patch.json), so its HPA sets each member's istiod replica count, and the churn suite's TSVs record the source member's count at the probe's start only, so whether that count held all through the pass is not known, nor whether its change against the baseline is the profile's alone"
	assert_output --partial "Pass 04-connection-pools, not known all through the pass on ISTIOD_REPLICAS_BY_CONTEXT (set by its profile's HPA):"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT, set by its profile's HPA (spec.values.pilot.autoscaleEnabled in its state/patch.json): the churn suite's TSVs record the source member's count at the probe's start only, so whether that count held all through the pass is not known"
	[[ "$stderr" == *"warning: pass 04-connection-pools: its profile turns istiod's autoscaling on"* ]]
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp '  ISTIOD_REPLICAS_BY_CONTEXT +set by its profile.s HPA \(spec.values.pilot.autoscaleEnabled in its state/patch.json\): the churn suite'
	# propagation reads each member's count, at the probe's start only too.
	sed -i 's/^# SUITE=churn$/# SUITE=propagation/' "${S}/sweep-metadata.txt"
	for p in baseline 02-x 04-connection-pools; do with_replicas "$p" ctx-a=1,ctx-b=1 ISTIOD_REPLICAS; done
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | unknown (see notes) |"
	assert_output --partial "so its HPA sets each member's istiod replica count, and the propagation suite's TSVs record each member's count at the probe's start only, so"
	# Without a baseline, the reference pass is that profile pass: its own cell says so.
	mkdir -p "${BATS_TEST_TMPDIR}/gone"
	mv "${S}/baseline" "${BATS_TEST_TMPDIR}/gone/"
	printf '# SUITE=propagation\n# PASSES=04-connection-pools,02-x\n' > "${S}/sweep-metadata.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | reference (see notes) | same |"
	assert_output --partial "so whether that count held all through the pass is not known, nor whether any pass's difference from it is the profiles' alone"
	# The controlplane suite reads the count again at a pass's end: one that held is a note, not
	# a warning, since its HPA may have raised and lowered it in between (M12-S2).
	mv "${BATS_TEST_TMPDIR}/gone/baseline" "${S}/"
	printf '# SUITE=controlplane\n# PASSES=baseline,02-x,04-connection-pools\n' > "${S}/sweep-metadata.txt"
	for p in baseline 02-x 04-connection-pools; do with_replicas "$p" ctx-a=1,ctx-b=1; done
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | same (see notes) |"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT, set by its profile's HPA (spec.values.pilot.autoscaleEnabled in its state/patch.json): the read at the pass's end found each member's count it started with, but the HPA may have raised and lowered it in between; each cell's own count of istiod pods is in its istiod_pods_avg (tests/controlplane/004-report-results.sh --results-dir <the pass's directory> --format csv)"
	refute_output --partial "Warning:** pass 04-connection-pools"
	[[ "$stderr" != *"pass 04-connection-pools"* ]] || { echo "$stderr"; false; }
	# Without a baseline that pass is the reference: its cell points at the note, and it does
	# not warn either (C13-S1).
	mv "${S}/baseline" "${BATS_TEST_TMPDIR}/gone/"
	printf '# SUITE=controlplane\n# PASSES=04-connection-pools,02-x\n' > "${S}/sweep-metadata.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | reference (see notes) | same |"
	assert_output --partial "the read at the pass's end found each member's count it started with"
	refute_output --partial "Warning:**"
	[[ "$stderr" != *"warning: pass"* ]] || { echo "$stderr"; false; }
	mv "${BATS_TEST_TMPDIR}/gone/baseline" "${S}/"
	printf '# SUITE=controlplane\n# PASSES=baseline,02-x,04-connection-pools\n' > "${S}/sweep-metadata.txt"
	# A TSV that records the count without its members (ISTIOD_REPLICAS), which the read at its
	# end does not compare: no such note (R13-N1).
	with_replicas 04-connection-pools 1 ISTIOD_REPLICAS
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | unknown (see notes) |"
	refute_output --partial "found each member's count it started with"
	with_replicas 04-connection-pools ctx-a=1,ctx-b=1
	# Not read again at its end (no drift file), or not compared there: no such note.
	mv "${S}/04-connection-pools/platform-drift.txt" "${BATS_TEST_TMPDIR}/gone/"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | unknown (see notes) |"
	refute_output --partial "found each member's count it started with"
	mv "${BATS_TEST_TMPDIR}/gone/platform-drift.txt" "${S}/04-connection-pools/"
	printf '%s\n' '# NOT_COMPARED_AT_END=ctx-a=ISTIOD_REPLICAS_BY_CONTEXT' >> "${S}/04-connection-pools/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | unknown (see notes) |"
	refute_output --partial "found each member's count it started with"
}

@test "tuning 004 (R11-N1): bare replica counts from before the record that a pass's TSVs disagree on warn and show both; where the baseline's do, a pass that ran one of them says so" {
	local p
	rm -rf "$S"
	mkdir -p "$S"
	printf '# SUITE=churn\n# PASSES=baseline,02-x\n' > "${S}/sweep-metadata.txt"
	for p in baseline 02-x; do
		mkdir -p "${S}/${p}"
		printf '%s\n' '# ISTIOD_REPLICAS=1' "$CHURN_HDR" $'t\tOK\t100\t200\t300\t40\t50' > "${S}/${p}/churn-${p}.tsv"
	done
	profile_state 02-x
	# A second TSV in 02-x counted 2.
	printf '%s\n' '# ISTIOD_REPLICAS=2' "$CHURN_HDR" $'t\tOK\t100\t200\t300\t40\t50' > "${S}/02-x/churn-second.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | mixed (see notes) |"
	assert_output --partial "- **Warning:** pass 02-x: its TSVs disagree on ISTIOD_REPLICAS_BY_CONTEXT (or one of them did not read or record a value; the values follow the table)"
	assert_output --partial "Pass 02-x, every value of its platform record unknown (its TSVs predate the record, or nothing could be read), its TSVs disagree on ISTIOD_REPLICAS_BY_CONTEXT:"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`mixed: 1 and 2\`"
	# A third TSV from before the count: the two counts still disagree, mixed (SC12-S2).
	printf '%s\n' "$CHURN_HDR" $'t\tOK\t100\t200\t300\t40\t50' > "${S}/02-x/churn-third.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | mixed (see notes) |"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`mixed: 1 and 2 and unknown\`"
	mkdir -p "${BATS_TEST_TMPDIR}/gone"
	mv "${S}/02-x/churn-third.tsv" "${BATS_TEST_TMPDIR}/gone/"
	# In the baseline: its record shows both, and the pass that ran one of them says which.
	mv "${S}/02-x/churn-second.tsv" "${S}/baseline/churn-second.tsv"
	sed -i 's/^# ISTIOD_REPLICAS=1$/# ISTIOD_REPLICAS=2/' "${S}/02-x/churn-02-x.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "- **Warning:** pass baseline: its TSVs disagree on ISTIOD_REPLICAS_BY_CONTEXT"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`mixed: 1 and 2\`"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT, where the baseline ran more than one value, one of those: \`2\`"
	refute_output --partial "mixed:1;2"
	refute_output --partial "02-x differs"
	# A pass on a count the baseline never ran still differs.
	sed -i 's/^# ISTIOD_REPLICAS=2$/# ISTIOD_REPLICAS=3/' "${S}/02-x/churn-02-x.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | differs (see notes) |"
	refute_output --partial "one of those"
}

@test "tuning 004 (SC12-S2): a pass with a TSV from before a key reads unknown, not mixed; a baseline with one leaves every pass unknown" {
	five_passes
	grep -v '^# NODE_PROVIDER_BY_CONTEXT=' "${S}/01-same/controlplane-01-same.tsv" > "${S}/01-same/controlplane-old.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | unknown (see notes) | same | differs (see notes) | unknown (see notes) |"
	assert_output --partial "Pass 01-same, cannot be compared on NODE_PROVIDER_BY_CONTEXT:"
	assert_output --partial "- NODE_PROVIDER_BY_CONTEXT: \`not recorded in some of its TSVs, every member recorded matches\`"
	[[ "$stderr" == *"warning: pass 01-same: NODE_PROVIDER_BY_CONTEXT could not be compared with the baseline (not read, or not recorded, in one of them)"* ]] || { echo "$stderr"; false; }
	refute_output --partial "disagree"
	# In the baseline instead: the pass compared with, and every pass's NODE_PROVIDER_BY_CONTEXT
	# unknown.
	mkdir -p "${BATS_TEST_TMPDIR}/gone"
	mv "${S}/01-same/controlplane-old.tsv" "${BATS_TEST_TMPDIR}/gone/"
	grep -v '^# NODE_PROVIDER_BY_CONTEXT=' "${S}/baseline/controlplane-baseline.tsv" > "${S}/baseline/controlplane-old.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | unknown (see notes) | unknown (see notes) | differs (see notes) | unknown (see notes) |"
	assert_output --partial "- NODE_PROVIDER_BY_CONTEXT: \`not recorded in some of its TSVs; kind on ctx-a, ctx-b\`"
	refute_output --partial "disagree"
	refute_output --partial "no profile's change against it"
}

@test "tuning 004 (U9-N5): an unknown --format names the value it was given" {
	run --separate-stderr "$COMPARE" --results-dir "$S" --format html
	assert_failure
	[[ "$stderr" == *"--format must be text or md (or markdown), not html"* ]]
}

# The churn suite's columns that 004 reads (tests/churn/002-run-churn-probe.sh writes more).
CHURN_HDR=$'timestamp\tstatus\tconvergence_local_ms\tconvergence_remote_eds_ms\tremote_endpoint_reachable_ms\tsource_xds_pushes_delta\tsource_push_time_p99_ms'

@test "tuning 004 (R10-S2): passes from before the record compare the churn suite's bare replica count as it is: the same says nothing, another differs" {
	local p
	rm -rf "$S"
	mkdir -p "$S"
	printf '# SUITE=churn\n# PASSES=baseline,02-x\n' > "${S}/sweep-metadata.txt"
	for p in baseline 02-x; do
		mkdir -p "${S}/${p}"
		printf '%s\n' '# ISTIOD_REPLICAS=1' "$CHURN_HDR" $'t\tOK\t100\t200\t300\t40\t50' > "${S}/${p}/churn-${p}.tsv"
	done
	profile_state 02-x
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | unknown (see notes) |"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`1\`"
	assert_output --partial "- **Warning:** pass baseline: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read), and so are its Kubernetes versions, so whether the other passes ran on its platform and builds is not known, nor whether any profile's change against it is the profile's alone"
	assert_output --partial "- **Warning:** pass 02-x: no key of its platform record can be compared with the baseline (its TSVs predate the record, or nothing could be read), nor its Kubernetes versions"
	assert_output --partial "Pass 02-x: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read)."
	refute_output --partial "ISTIOD_REPLICAS_BY_CONTEXT could not be compared"
	refute_output --partial "differs"
	# Another count: it differs, with the cause a suite that counts Running pods adds.
	sed -i 's/^# ISTIOD_REPLICAS=1$/# ISTIOD_REPLICAS=2/' "${S}/02-x/churn-02-x.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | differs (see notes) |"
	assert_output --partial "- **Warning:** pass 02-x differs from the baseline on ISTIOD_REPLICAS_BY_CONTEXT (its values follow the table; the churn suite counts Running istiod pods, which include a Terminating pod after a short --settle), so its change against the baseline is not the profile's alone"
	assert_output --partial "Pass 02-x, every value of its platform record unknown (its TSVs predate the record, or nothing could be read), differs on ISTIOD_REPLICAS_BY_CONTEXT:"
	assert_output --partial "- ISTIOD_REPLICAS_BY_CONTEXT: \`2\`"
	[[ "$stderr" == *"warning: pass 02-x differs from the baseline on ISTIOD_REPLICAS_BY_CONTEXT"* ]]
}

@test "tuning 004 (R10-N1): a value of the baseline's not read on one of its inputs is not a second value it ran; a pass that ran two values itself is not said to run one of the baseline's" {
	lever_passes "" "" "" "" "$SIDECAR_OFF" none
	# The baseline's second TSV (churn-dataplane writes two) could not read ctx-b's Kubernetes version.
	sed 's/^# KUBE_VERSIONS=.*/# KUBE_VERSIONS=ctx-a=v1.33.1,ctx-b=unreachable/' "${S}/baseline/controlplane-baseline.tsv" > "${S}/baseline/controlplane-second.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "- KUBE_VERSIONS: \`v1.33.1 on ctx-a; mixed: v1.33.1 and unreachable on ctx-b\`"
	refute_output --partial "KUBE_VERSIONS, where the baseline ran more than one value"
	# The baseline's sidecar lever and egress hosts changed during it, and so did 02-x's: 04 ran
	# one of the baseline's values, 02-x both.
	rm "${S}/baseline/controlplane-second.tsv"
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' "# TUNING_BASELINE=${SIDECAR_OFF}" '# SIDECAR_EGRESS_HOSTS=none' > "${S}/baseline/platform-drift.txt"
	cp "${S}/baseline/platform-drift.txt" "${S}/02-x/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | changed (see notes) | same (see notes) |"
	assert_output --partial "Pass 02-x, changed during the pass on TUNING_BASELINE, SIDECAR_EGRESS_HOSTS:"
	assert_output --partial "- TUNING_BASELINE, where the baseline ran more than one value, one of those: \`sidecar=off\`"
	assert_output --partial "- SIDECAR_EGRESS_HOSTS, where the baseline ran more than one value, one of those: \`none\`"
	[[ "$(sed -n '/^Pass 02-x/,/^Pass 04/p' <<<"$output")" != *"one of those"* ]]
	[ "$(grep -c 'one of those' <<<"$output")" -eq 2 ]
}

@test "tuning 004 (R10-S1): a pass whose platform record is all unknown still shows what its profile sets, and which of the baseline's values it ran" {
	objects_passes
	with_record baseline
	# 02-x and 04: their records not read (their TSVs keep their Kubernetes versions).
	with_record 02-x '/^# KUBE_VERSIONS=/!d'
	with_record 04-connection-pools '/^# KUBE_VERSIONS=/!d'
	with_levers baseline
	# 02-x's profile brings its own root Sidecar.
	with_levers 02-x "$SIDECAR_OFF" none
	with_levers 04-connection-pools
	# Without a record a limit names no member: no pass records one here.
	sed -i '/^# ISTIOD_.*_LIMIT_/d' "${S}"/*/controlplane-*.tsv
	profile_state 02-x "" Sidecar/istio-system/default
	profile_state 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "Pass 02-x, every value of its platform record unknown (its TSVs predate the record, or nothing could be read):"
	assert_output --partial "- TUNING_BASELINE, set by its profile (sidecar: its state/objects lists Sidecar/istio-system/default): \`sidecar=off,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on\`"
	assert_output --partial "- SIDECAR_EGRESS_HOSTS, set by its profile (its state/objects lists Sidecar/istio-system/default): \`none\`"
	assert_output --partial "Pass 04-connection-pools: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read)."
	refute_output --partial "- PLATFORM: \`unknown\`"
	# 04 ran the second value of the baseline's sidecar lever and egress hosts (changed during it).
	sed -i "s/^# TUNING_BASELINE=.*/# TUNING_BASELINE=${SIDECAR_OFF}/; s|^# SIDECAR_EGRESS_HOSTS=.*|# SIDECAR_EGRESS_HOSTS=none|" "${S}/04-connection-pools/controlplane-04-connection-pools.tsv"
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' "# TUNING_BASELINE=${SIDECAR_OFF}" '# SIDECAR_EGRESS_HOSTS=none' > "${S}/baseline/platform-drift.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "Pass 04-connection-pools, every value of its platform record unknown (its TSVs predate the record, or nothing could be read):"
	[[ "$(sed -n '/^Pass 04-connection-pools/,$p' <<<"$output")" == *"- TUNING_BASELINE, where the baseline ran more than one value, one of those: \`sidecar=off\`"* ]]
	refute_output --partial "Pass 04-connection-pools: every value"
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --partial "Pass 04-connection-pools, every value of its platform record unknown (its TSVs predate the record, or nothing could be read):"
	assert_output --regexp "  TUNING_BASELINE +where the baseline ran more than one value, one of those: sidecar=off"
}

@test "tuning 004 (R10-N2): a baseline whose platform record is all unknown has the one note and one warning that say so; a pass compared with it warns for its own Kubernetes versions only" {
	objects_passes
	with_record baseline '/^# KUBE_VERSIONS=/!d'
	with_record 02-x
	with_record 04-connection-pools
	profile_pass 02-x
	profile_pass 04-connection-pools "" DestinationRule/istio-system/tuning-connection-pool
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline (see notes) | unknown (see notes) | unknown (see notes) |"
	assert_output --partial "Pass baseline: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read)."
	assert_output --partial "- **Warning:** pass baseline: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read), so whether the other passes ran on its platform and builds is not known, nor whether any profile's change against it is the profile's alone"
	# The passes compared with it have records: the baseline's warning covers them.
	refute_output --partial "no key of its platform record"
	[ "$(grep -c '^warning: ' <<<"$stderr")" -eq 1 ]
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --partial "Pass baseline: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read)."
	assert_output --partial "WARNING: pass baseline: every value of its platform record is unknown"
	# A pass whose own Kubernetes versions were not read on a member warns for those.
	sed -i 's/^# KUBE_VERSIONS=.*/# KUBE_VERSIONS=ctx-a=v1.33.1,ctx-b=unreachable/' "${S}/02-x/controlplane-02-x.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "- **Warning:** pass 02-x: KUBE_VERSIONS could not be compared with the baseline (not read, or not recorded, in one of them), so whether it ran on the same Kubernetes versions is not known"
	[ "$(grep -c '^warning: ' <<<"$stderr")" -eq 2 ]
	# The baseline's not read either: its warning says so, and none of the passes'.
	sed -i '/^# KUBE_VERSIONS=/d' "${S}/baseline/controlplane-baseline.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "- **Warning:** pass baseline: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read), and so are its Kubernetes versions, so whether the other passes ran on its platform and builds is not known"
	[ "$(grep -c '^warning: ' <<<"$stderr")" -eq 1 ]
}

@test "tuning 004 (U10-S1): a directory that is not a tuning sweep's says what to give instead; a pass the metadata lists without its directory has no data" {
	mkdir -p "${BATS_TEST_TMPDIR}/empty"
	run --separate-stderr "$COMPARE" --results-dir "${BATS_TEST_TMPDIR}/empty"
	assert_failure
	[[ "$stderr" == *"no pass directories in ${BATS_TEST_TMPDIR}/empty: give a tuning sweep directory (tests/tuning/results/sweep-<RUN_ID>), which holds one directory per pass"* ]]
	# A pass directory (its state/ is no pass), or another suite's sweep: the TSVs are its own.
	profile_state 01-x
	run --separate-stderr "$COMPARE" --results-dir "${S}/01-x"
	assert_failure
	[[ "$stderr" == *"${S}/01-x holds TSVs itself (a pass directory, or another suite's sweep): give a tuning sweep directory (tests/tuning/results/sweep-<RUN_ID>), which holds one directory per pass"* ]]
	mkdir -p "${BATS_TEST_TMPDIR}/sweep-prop/logs"
	printf '%s\n' $'p1_ms\tp2_ms\tp3_ms' $'1\t2\t3' > "${BATS_TEST_TMPDIR}/sweep-prop/propagation-r1.tsv"
	run --separate-stderr "$COMPARE" --results-dir "${BATS_TEST_TMPDIR}/sweep-prop"
	assert_failure
	[[ "$stderr" == *"${BATS_TEST_TMPDIR}/sweep-prop holds TSVs itself"* ]]
	# A pass the metadata lists without its directory, before any with data (no SUITE line: the
	# first pass with a TSV names it): no data.
	printf '# PASSES=03-gone,baseline,01-x\n' > "${S}/sweep-metadata.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "- Suite: controlplane"
	assert_output --partial "| Pass status | no data | ok | ok |"
	assert_output --partial "| Valid / total rows | 0/0 | 2/3 | 2/2 |"
	assert_output --partial "| Platform record | - | baseline (see notes) | unknown (see notes) |"
	assert_output --partial "| istiod memory peak (Mi) | - | 512 | 256 (-50.0%) |"
	# The directory that holds the sweeps (tests/tuning/results): it names the last of them (U11-S1).
	mkdir -p "${BATS_TEST_TMPDIR}/results"
	cp -r "$S" "${BATS_TEST_TMPDIR}/results/sweep-20260101T000000Z-1"
	cp -r "$S" "${BATS_TEST_TMPDIR}/results/sweep-20260102T000000Z-1"
	run --separate-stderr "$COMPARE" --results-dir "${BATS_TEST_TMPDIR}/results"
	assert_failure
	[[ "$stderr" == *"${BATS_TEST_TMPDIR}/results holds tuning sweeps, not passes: give one of them (the last by name: ${BATS_TEST_TMPDIR}/results/sweep-20260102T000000Z-1)"* ]] || { echo "$stderr"; false; }
}
