#!/usr/bin/env bats
# propagation 004-collect-pilot-metrics through its real entrypoint (PL33), with a stub
# kubectl and curl, no cluster: each snapshot file is named by ctx_file_safe, the one
# file-name form of a context every other writer and redact-results.sh use (other bytes
# as _, in any locale), not a locale-dependent pattern of its own. Names are
# placeholders.

bats_require_minimum_version 1.5.0
load test_helper

FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"

setup() {
	OUT="${BATS_TEST_TMPDIR}/out"
	EK="${BATS_TEST_TMPDIR}/empty.kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export FX
	# kubectl: one Running istiod pod per context; a port-forward waits to be killed.
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
case " $* " in
*" get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-x1\n' ;;
*" port-forward "*) exec sleep 30 ;;
*) exit 1 ;;
esac
STUB
	# curl: every /metrics read serves the fixture (to -o FILE, or discarded).
	cat > "${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while (($#)); do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	*) shift ;;
	esac
done
if [[ -n "$out" && "$out" != /dev/null ]]; then cp "$FX/pre_metrics.txt" "$out"; fi
exit 0
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl"
}

@test "propagation 004: a snapshot file is named by ctx_file_safe, byte for byte in a UTF-8 locale" {
	local ctx=$'ci-\xc3\xa9' want
	want="$(ctx_file_safe "$ctx")"
	# Two bytes, two underscores: a character class in a UTF-8 locale would write one.
	[ "$want" = "ci-__" ]
	LC_ALL=C.UTF-8 PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr \
		"${ROOT}/tests/propagation/004-collect-pilot-metrics.sh" --contexts "$ctx" --output-dir "$OUT"
	assert_success
	run find "$OUT" -name '*.prom'
	assert_output --regexp "/ci-__-istiod-x1-[0-9]{8}T[0-9]{6}Z\.prom$"
	# Only pilot_* lines are kept.
	[ "$(grep -vc '^pilot_' "$OUT"/ci-__-istiod-x1-*.prom)" -eq 0 ]
}
