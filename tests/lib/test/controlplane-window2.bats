#!/usr/bin/env bats
# Controlplane 002 windows, part 2, through 002 (PL33; no cluster: kubectl and curl are
# stubs, as in controlplane-window.bats): a TSV whose last line lost its newline gets it
# before the window's lines; a Running istiod pod that is not Ready is named on the console;
# each member's istiod Deployment is read once a window (resolve_pods), and read again at
# the rows only when that read lacks a limit; a window into a TSV that exists reads nothing
# for its preamble.

bats_require_minimum_version 1.5.0
load test_helper

CP="${ROOT}/tests/controlplane"
FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export FX KLOG="${BATS_TEST_TMPDIR}/klog"
	# The Istio CR reads answer as fake-istio-cr.sh. Each member runs istiod-a and istiod-b,
	# Running, with the Ready conditions STUB_READY gives ("True True" unless set), of a
	# Deployment that wants three (one Pending) at a 2 CPU / 2Gi limit (a read of it fails
	# while STUB_DEPLOY_FAIL is set), each pod at 1500m and 1900Mi in `kubectl top`; other
	# lists are empty. Every call is logged to KLOG. Anything else fails, as against an
	# empty kubeconfig.
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KLOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*)
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*)
	read -r ra rb <<<"${STUB_READY:-True True}"
	printf 'istiod-a=%s istiod-b=%s ' "$ra" "$rb" ;;
*" -n istio-system get deploy istiod -o json "*)
	[[ -z "${STUB_DEPLOY_FAIL:-}" ]] || exit 1
	printf '%s\n' '{"spec":{"replicas":3,"template":{"spec":{"containers":[{"name":"discovery","resources":{"limits":{"cpu":"2","memory":"2Gi"}}}]}}},"status":{"replicas":3,"readyReplicas":2}}' ;;
*" -n istio-system top pod -l app=istiod --no-headers "*) printf 'istiod-a 1500m 1900Mi\nistiod-b 1500m 1900Mi\n' ;;
*" -o json "*) cat "$FX/empty_list.json" ;;
*) exit 1 ;;
esac
STUB
	cat > "${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while (($#)); do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	http://*) url="$1"; shift ;;
	*) shift ;;
	esac
done
case "$url" in
*/metrics) body="$FX/pre_metrics.txt" ;;
*/ready) echo LIVE; exit 0 ;;
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl"
	TSV="${RES}/controlplane-R1.tsv"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
}

# cp_window [args...]: one 002 window of ctx-a (and the --contexts given) into
# res/controlplane-R1.tsv.
cp_window() {
	PATH="${BIN}:${PATH}" run --separate-stderr "${CP}/002-collect-resource-metrics.sh" \
		--contexts ctx-a --config-dump-samples 0 --settle 0 --output-dir "$RES" --run-id R1 "$@"
}

# col <name>: the TSV column's values, one line, space-separated.
col() {
	awk -F'\t' -v c="$1" '$1 == "timestamp" { for (i = 1; i <= NF; i++) if ($i == c) k = i; next }
		/^#/ { next } k { printf "%s%s", (n++ ? " " : ""), $k } END { print "" }' "$TSV"
}

# deploy_reads <ctx>: the istiod Deployment reads KLOG holds for <ctx>.
deploy_reads() {
	grep -c -- "--context=$1 .*get deploy istiod -o json" "$KLOG" || true
}

@test "002 ends a TSV's last line that lost its newline (a write cut short) before the window's lines, so its rows do not merge onto it" {
	local cut
	cp_window
	assert_success
	# The last row loses its last column and newline.
	cut="$(<"$TSV")"
	cut="${cut%$'\t'*}"
	printf '%s' "$cut" > "$TSV"
	cp_window
	assert_success
	[ "$(grep -c '^# WINDOW_ROWS=' "$TSV")" -eq 2 ]
	grep -qxF -- "$(tail -n 1 <<<"$cut")" "$TSV"
	# Two whole windows of two rows each, and the cut row: no merged line.
	[ "$(awk -F'\t' '$2 == "ctx-a" && NF == 66' "$TSV" | wc -l | tr -d ' ')" -eq 3 ]
	[ "$(awk -F'\t' '$2 == "ctx-a" && NF != 66' "$TSV" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "002 names a Running istiod pod that is not Ready on the console; all Ready, it says nothing; the rows and pods.tsv keep the bare pod names" {
	local sd="${BATS_TEST_TMPDIR}/state"
	mkdir -p "$sd"
	STUB_READY="True False" cp_window --phase baseline --state-dir "$sd"
	assert_success
	[[ "$stderr" == *"warning: context ctx-a: istiod pod(s) Running but not Ready: istiod-b (a replacement still syncing its remote clusters, an old replica shutting down, or one failing its readiness probe under load?): such a pod takes no new proxy connections but keeps the ones it has (its connected_proxies column)"* ]]
	[ "$(cut -f 3 "${sd}/pods.tsv" | tr '\n' ' ')" = "istiod-a istiod-b " ]
	cp_window --phase final --state-dir "$sd"
	assert_success
	[ "$(col context)" = "ctx-a ctx-a" ]
	# No Ready condition read (a pod without conditions) is not Ready either.
	STUB_READY="True" cp_window
	assert_success
	[[ "$stderr" == *"istiod pod(s) Running but not Ready: istiod-b "* ]]
	cp_window
	assert_success
	[[ "$stderr" != *"not Ready"* ]]
}

@test "002 reads each member's istiod Deployment once a window, at its baseline, and its rows' %-of-limit use that read; read again at the rows only when it lacks a limit" {
	local sd="${BATS_TEST_TMPDIR}/state"
	mkdir -p "$sd"
	# The first window writes the TSV's preamble (which reads the Deployments for its own
	# keys); the windows after it find the TSV and read nothing for a preamble. In split
	# phases (as a sweep runs them) the final reads no Deployment: the baseline's read is in
	# the state dir.
	cp_window --contexts ctx-a,ctx-b
	assert_success
	rm -f "$KLOG"
	cp_window --contexts ctx-a,ctx-b --phase baseline --state-dir "$sd"
	assert_success
	[ "$(deploy_reads ctx-a)" -eq 1 ]
	[ "$(deploy_reads ctx-b)" -eq 1 ]
	cp_window --contexts ctx-a,ctx-b --phase final --state-dir "$sd"
	assert_success
	[ "$(deploy_reads ctx-a)" -eq 1 ]
	[ "$(deploy_reads ctx-b)" -eq 1 ]
	# The baseline could not read it: the final reads it at the rows.
	rm -rf "$KLOG" "$sd"
	mkdir -p "$sd"
	STUB_DEPLOY_FAIL=1 cp_window --contexts ctx-a,ctx-b --phase baseline --state-dir "$sd"
	assert_success
	cp_window --contexts ctx-a,ctx-b --phase final --state-dir "$sd"
	assert_success
	[ "$(deploy_reads ctx-a)" -eq 2 ]
	[ "$(deploy_reads ctx-b)" -eq 2 ]
	# Every row of the three windows: 3800Mi of 2 x 2048Mi and 3000m of 2 x 2000m (the pods
	# `kubectl top` summed).
	[ "$(col istiod_mem_pct_of_limit)" = "$(printf '93 %.0s' {1..11})93" ]
	[ "$(col istiod_cpu_pct_of_limit)" = "$(printf '75 %.0s' {1..11})75" ]
}
