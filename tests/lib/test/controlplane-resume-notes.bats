#!/usr/bin/env bats
# A controlplane --resume's outcome notes, through 003 (PL33; no cluster: kubectl is a stub,
# its cells fail as PROBE_FAILED, and where a cell must be interrupted, 001 and 002 are fakes
# in a symlinked copy of the tree): a carried harness PROBLEM that is kept says why, once,
# and the NOTE it becomes once its rows were all run again drops the advice to run the
# sweep again; a resume that stops before it adds a row keeps its own harness note out of
# its record, as a resume that ends does, and one interrupted inside a cell keeps it.

bats_require_minimum_version 1.5.0
load test_helper

CP="${ROOT}/tests/controlplane"

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	# The Istio CR reads answer as fake-istio-cr.sh; no controlplane-test namespace is left
	# on any member, and its delete succeeds. Anything else fails (002's first read too), as
	# against an empty kubeconfig.
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" get namespaces -l app.kubernetes.io/instance=controlplane-test -o json"*) echo '{"items":[]}' ;;
*" get namespace -l app.kubernetes.io/instance=controlplane-test -o name"*|*" get ns -l app.kubernetes.io/instance=controlplane-test -o name"*) : ;;
*" delete namespace "*) : ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
	export RN_DIR="$BATS_TEST_TMPDIR"
	SWEEP="${CP}/003-run-sweep.sh"
}

teardown() {
	local p
	[[ -s "${BATS_TEST_TMPDIR}/fake-pid" ]] || return 0
	p="$(<"${BATS_TEST_TMPDIR}/fake-pid")"
	if [[ "$p" =~ ^[0-9]+$ ]]; then kill -KILL "$p" 2>/dev/null || true; fi
}

# cp_sweep <args...>: $SWEEP with the stub kubectl, its results under res/; stdout in
# $output and stderr in $stderr. Sets D (the sweep dir) and TSV.
cp_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="${BATS_TEST_TMPDIR}/res" \
		run --separate-stderr bash "$SWEEP" "$@"
	D="$(find "${BATS_TEST_TMPDIR}/res" -mindepth 1 -maxdepth 1 -name 'sweep-*' -type d)"
	TSV="$(find "$D" -maxdepth 1 -name 'controlplane-*.tsv')"
}

# cp_row <ts> <ctx> <mesh> <svcs> <mem_mi>: a valid measurement row (66 columns, window
# kind deploy, 3 replicas, 1 namespace, scoping none, traffic none), as
# controlplane-window.bats writes it.
cp_row() {
	printf '%s\t%s\t%s\t%s\t3\t1\tnone\t%s\t50\t90\t5\t9\t100\t3.33\t10\t60\t10\t10\t10\t50\t1.67\t20\t2048\t1048576\t1048576\t1048576\t3/3\t30.0\t100\t30\t0\t100\t200\t250\t10\t15\t40\t50\t120\t250\t22\t22\tOK\tnone\t0\t0\t1.00\t0.50\t30\t51200\t20480\t0\tpods\t4\t0\tnone\tdeploy\t%s\t12.5\t45\t120\t200\t3\t210\t180\t0\n' \
		"$1" "$2" "$3" "$4" "$5" "$(($4 * 2))"
}

@test "a carried harness PROBLEM that is kept ends with why, once per outcome; the NOTE it becomes once its rows were all run again drops the advice to run the sweep again" {
	local date carried
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5,6
	[ "$status" -eq 4 ]
	# The first run measured the cell of 5 Services after all: its row stays in the figures.
	cp_row 2026-06-01T00:01:00+00:00 ci-a 1 5 1000 >> "$TSV"
	echo 'PROBLEM=the harness changed during the sweep: HARNESS_SHA=aaa1111 at its start (bats); run the sweep again if the change matters' >> "${D}/sweep-outcome.txt"
	date="$(sed -n 's/^# DATE=//p' "${D}/sweep-outcome.txt")"
	carried="an earlier run of this sweep (outcome of ${date}) recorded: the harness changed during the sweep: HARNESS_SHA=aaa1111 at its start (bats)"
	cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 4 ]
	grep -qxF "PROBLEM=${carried}; run the sweep again if the change matters (kept: 2 row(s) of that run are in the figures)" "${D}/sweep-outcome.txt"
	# That resume started in the second the outcome was written (run right after it): it is
	# not the run that wrote it. Resumed again: carried, and its reason given again, once.
	sed -i.bak "2s/^[^	]*/${date%Z}+00:00/" "${D}/resumes.txt" && rm -f "${D}/resumes.txt.bak"
	sed -i.bak "s/^# RESUMED_AT=[^ ]* /# RESUMED_AT=${date%Z}+00:00 /" "$TSV" && rm -f "${TSV}.bak"
	cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 4 ]
	grep -qxF "PROBLEM=${carried}; run the sweep again if the change matters (kept: 2 row(s) of that run are in the figures)" "${D}/sweep-outcome.txt"
	[ "$(grep -c '(kept: ' "${D}/sweep-outcome.txt")" = 1 ]
	# That row reads as failed now (a status row, the line count kept): the next resume runs
	# its cell again, and no row of the first run is left in the figures.
	awk -F'\t' -v OFS='\t' '$1 == "2026-06-01T00:01:00+00:00" { $2 = "PROBE_FAILED" } { print }' "$TSV" > "${TSV}.new"
	mv -f "${TSV}.new" "$TSV"
	cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 4 ]
	grep -qxF "NOTE=${carried} (its rows were all run again later)" "${D}/sweep-outcome.txt"
	[ "$(grep -c '^PROBLEM=\|(kept: \|run the sweep again if' "${D}/sweep-outcome.txt")" = 0 ]
}

@test "a --resume on another harness that stops before it adds a row keeps its harness note out of its record; one interrupted inside a cell (its INTERRUPTED row) keeps it" {
	local tree f at
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	sed -i.bak 's/^# HARNESS_SHA=.*/# HARNESS_SHA=old1234/; s/^# HARNESS_CONTENT_KEY=.*/# HARNESS_CONTENT_KEY=000000000000/' "$TSV" && rm -f "${TSV}.bak"
	# The resume stops before its first cell: it cannot write planned-cells.txt.
	rm -f "${D}/planned-cells.txt"
	mkdir "${D}/planned-cells.txt"
	cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"warning: --resume: this resume runs harness "*", and the run before it ran old1234"* ]]
	grep -qx 'STOPPED=1' "${D}/sweep-outcome.txt"
	at="$(sed -n 's/^RESUMED_AT=//p' "${D}/sweep-outcome.txt")"
	[[ "$at" =~ ^[0-9T:-]+Z$ ]]
	[ "$(grep -c "^NOTE=the --resume at ${at} ran HARNESS_SHA=" "${D}/sweep-outcome.txt")" = 0 ]
	# A resume in a copy of the tree (no git: HARNESS_SHA=unknown, another harness too) whose
	# 002 sends the sweep SIGTERM inside the cell: the cell gets its INTERRUPTED row, a row of
	# this resume, and its own note stays.
	rmdir "${D}/planned-cells.txt"
	tree="${BATS_TEST_TMPDIR}/tree"
	mkdir -p "${tree}/tests/controlplane"
	ln -s "${ROOT}/config" "${tree}/config"
	ln -s "${ROOT}/charts" "${tree}/charts"
	ln -s "${ROOT}/tests/lib" "${tree}/tests/lib"
	for f in "$CP"/*; do
		case "${f##*/}" in 001-* | 002-*) ;; *) ln -s "$f" "${tree}/tests/controlplane/${f##*/}" ;; esac
	done
	printf '#!/bin/sh\nexit 0\n' > "${tree}/tests/controlplane/001-setup-controlplane-test.sh"
	printf '#!/bin/sh\ncase " $* " in *" --phase final "*) echo $$ > "$RN_DIR/fake-pid"; kill -TERM "$PPID"; exec sleep 30 ;; esac\nexit 0\n' \
		> "${tree}/tests/controlplane/002-collect-resource-metrics.sh"
	chmod +x "${tree}/tests/controlplane/001-setup-controlplane-test.sh" "${tree}/tests/controlplane/002-collect-resource-metrics.sh"
	SWEEP="${tree}/tests/controlplane/003-run-sweep.sh" cp_sweep --resume "$D" --contexts ci-a
	[ "$status" -eq 143 ]
	[ "$(awk -F'\t' '$2 == "INTERRUPTED"' "$TSV" | wc -l | tr -d ' ')" -eq 1 ]
	grep -qx 'ENDED_SIGNAL=SIGTERM' "${D}/sweep-outcome.txt"
	at="$(sed -n 's/^RESUMED_AT=//p' "${D}/sweep-outcome.txt")"
	[[ "$at" =~ ^[0-9T:-]+Z$ ]]
	# Its own note, named by its harness (unknown): the resume before it may have started in
	# the same second, and that one's note, read again from resumes.txt, names the same time.
	[ "$(grep -c "^NOTE=the --resume at ${at} ran HARNESS_SHA=unknown (git describe failed there): rows from ${at} on " "${D}/sweep-outcome.txt")" = 1 ]
}
