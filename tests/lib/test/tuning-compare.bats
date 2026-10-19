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

# with_record <pass> [sed program]: put the platform record a current writer adds (edited by
# the sed program) at the top of that pass's TSV.
with_record() {
	local f
	f="$(ls "${S}/$1"/controlplane-*.tsv)"
	{ platform_fixture_lines | sed "${2:-}"; cat "$f"; } > "${f}.new"
	mv "${f}.new" "$f"
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
	assert_output --partial "- **Warning:** pass 04-legacy: no key of its platform record can be compared with the baseline (its TSVs predate the record, or nothing could be read)"
	refute_output --partial "04-legacy differs"
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

@test "tuning 004: a pass whose TSVs disagree within it differs from the baseline" {
	five_passes
	# A second TSV in 01-same, on another istiod build: the pass's own record is mixed.
	{
		platform_fixture_lines | sed "${digests}; s/pilot:1.30.5@$(digest cd)/pilot:1.30.6@$(digest 23)/g; s#=none#=$(own_objects 01-same)#g"
		printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10'
	} > "${S}/01-same/controlplane-second.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | differs (see notes) | same | differs (see notes) | unknown (see notes) |"
	assert_output --partial "Pass 01-same, differs on ISTIOD_IMAGE_BY_CONTEXT:"
	# Both members hold both builds: the value they share, once.
	assert_output --partial "- ISTIOD_IMAGE_BY_CONTEXT: \`mixed:pilot:1.30.5@sha256:cdcdcdcdcdcd;pilot:1.30.6@sha256:232323232323\`"
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
		platform_fixture_lines | sed "s#=none#=$(own_objects 04-connection-pools)#g"
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
	# A pass's own two TSVs that disagree (churn-dataplane writes two): one without the marker.
	mv "${S}/02-x/platform-drift.txt" "${S}/02-x-drift.old"
	{
		platform_fixture_lines | sed "s/=0123456789ab/=fedcba987654/g"
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
