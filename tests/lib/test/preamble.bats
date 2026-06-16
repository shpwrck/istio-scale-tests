#!/usr/bin/env bats

load test_helper
source "${ROOT}/tests/lib/preamble.sh"

# ---------------------------------------------------------------------------
# infra_preamble_lines — the ONE shared cluster-infra emitter (PL36). Every
# expected key is ALWAYS emitted (defaulting to `unknown`), and caller-supplied
# values overlay. This is what guarantees the 003 pre-creator and the 002
# `! -f`-guarded collector write the identical infra key set.
# ---------------------------------------------------------------------------

@test "infra_preamble_lines: emits all keys, defaulting omitted ones to unknown" {
	run infra_preamble_lines NODE_ALLOC_CPU_M=16000 ISTIOD_LIM_MEM_MI=8192
	[ "$status" -eq 0 ]
	[[ "$output" == *"# NODE_ALLOC_CPU_M=16000"* ]]
	[[ "$output" == *"# ISTIOD_LIM_MEM_MI=8192"* ]]
	# Omitted keys still present as unknown (PL36: missing-but-expected, not absent).
	[[ "$output" == *"# NODE_ALLOC_MEM_MI=unknown"* ]]
	[[ "$output" == *"# ISTIOD_REQ_CPU_M=unknown"* ]]
	[[ "$output" == *"# ISTIOD_REPLICAS=unknown"* ]]
	[[ "$output" == *"# NETWORK_TOPOLOGY=unknown"* ]]
}

@test "infra_preamble_lines: no args -> all eight keys emitted as unknown" {
	run infra_preamble_lines
	[ "$status" -eq 0 ]
	# Exactly the canonical key set, all unknown.
	n=$(printf '%s\n' "$output" | grep -c '^# [A-Z_]*=unknown$')
	[ "$n" -eq 8 ]
}

@test "infra_preamble_lines: unrecognized key is ignored (not echoed verbatim)" {
	run infra_preamble_lines BOGUS_KEY=123 NETWORK_TOPOLOGY=multi-network:5
	[ "$status" -eq 0 ]
	[[ "$output" != *"BOGUS_KEY"* ]]
	[[ "$output" == *"# NETWORK_TOPOLOGY=multi-network:5"* ]]
}

# ---------------------------------------------------------------------------
# PL36 two-writer key-set symmetry. The 003 pre-creator and the 002 collector
# both build the controlplane TSV preamble; if one writes a `# KEY=` line the
# other omits, the `! -f` guard silently drops it downstream. Both now route the
# infra block through infra_preamble_lines, so the infra key set is identical by
# construction — but assert the FULL `# KEY=value` literal sets agree too, so a
# future hand-added line to one writer can't drift unnoticed.
# ---------------------------------------------------------------------------

@test "PL36: 002 and 003 emit the same controlplane preamble key set" {
	collector="${ROOT}/tests/controlplane/002-collect-resource-metrics.sh"
	precreate="${ROOT}/tests/controlplane/003-run-sweep.sh"
	# Pull the literal `echo "# KEY=..."` keys each writer emits inline.
	keys_002=$(grep -oE 'echo "# [A-Z_]+=' "$collector" | sed -E 's/echo "# ([A-Z_]+)=/\1/' | sort -u)
	keys_003=$(grep -oE 'echo "# [A-Z_]+=' "$precreate" | sed -E 's/echo "# ([A-Z_]+)=/\1/' | sort -u)
	# Both call infra_preamble_lines for the infra block, so the infra keys are not
	# inline echoes in either — symmetry there is guaranteed by the shared emitter.
	# Here we assert the INLINE-echoed key sets match modulo the known, intentional
	# 003-only provenance keys (METRICS_API, NOTE) and the shared-title comment.
	only_003=$(comm -13 <(printf '%s\n' "$keys_002") <(printf '%s\n' "$keys_003"))
	only_002=$(comm -23 <(printf '%s\n' "$keys_002") <(printf '%s\n' "$keys_003"))
	# 002 must not emit any key 003 lacks (that would vanish in an orchestrated run).
	[ -z "$only_002" ]
	# 003-only keys must be exactly the documented orchestrator-provenance extras.
	for k in $only_003; do
		case "$k" in
			METRICS_API|NOTE) : ;;
			*) echo "unexpected 003-only key: $k"; false ;;
		esac
	done
}

@test "PL36: both controlplane writers route the infra block through infra_preamble_lines" {
	grep -q 'infra_preamble_lines' "${ROOT}/tests/controlplane/002-collect-resource-metrics.sh"
	grep -q 'infra_preamble_lines' "${ROOT}/tests/controlplane/003-run-sweep.sh"
}
