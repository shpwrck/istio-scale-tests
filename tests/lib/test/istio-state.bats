#!/usr/bin/env bats
# What a sweep reads of the members' Istio, and records: the Istio CR and IstioRevision
# generations (an edit at the same version is a problem; a rollout whose confirming read
# fails is not ready), the proxy versions connected to istiod, and kubectl errors with API
# hosts and addresses masked. Through the real scripts where a test can reach them (PL33);
# no cluster: kubectl is a stub.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/preamble.sh"
source "${ROOT}/tests/lib/capacity.sh"
source "${ROOT}/tests/lib/envelope.sh"

CP="${ROOT}/tests/controlplane"
REPORT="${CP}/004-report-results.sh"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
FAKE_CR="${ROOT}/tests/lib/test/fixtures/fake-istio-cr.sh"

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	# The kubectl stub: the Istio CR reads answer as fake-istio-cr.sh (the Istio CR's
	# generation from the file crgen, default 2); the istiod pod list (the proxy versions read, after the
	# start's version read) first copies bump-on-pods to crgen when that file exists;
	# `version` answers the file kver (unreachable, or no file: it fails); anything else
	# fails, as against an empty kubeconfig.
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$CA_DIR"
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	STUB_ISTIO_CR_GEN="$(cat "$d/crgen" 2>/dev/null || echo 2)"
	export STUB_ISTIO_CR_GEN
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" get pods -l app=istiod "*)
	[ ! -f "$d/bump-on-pods" ] || cp "$d/bump-on-pods" "$d/crgen"
	exit 1 ;;
*" version --output=json"*)
	k="$(cat "$d/kver" 2>/dev/null || echo unreachable)"
	[ "$k" != unreachable ] || exit 1
	printf '{"serverVersion":{"gitVersion":"%s"}}\n' "$k" ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
	export CA_DIR="$BATS_TEST_TMPDIR"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
}

# cp_sweep <args...>: controlplane 003 with the stub kubectl (PATH_PRE first on PATH, for a
# fake awk), its results under res/; output and stderr together.
cp_sweep() {
	PATH="${PATH_PRE:+${PATH_PRE}:}${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="${BATS_TEST_TMPDIR}/res" \
		run bash "$CP/003-run-sweep.sh" "$@"
}

# sweep_dir: the one sweep dir under res/.
sweep_dir() {
	find "${BATS_TEST_TMPDIR}/res" -maxdepth 1 -name 'sweep-*' -type d
}

# _rollout_kubectl: the Istio CR and IstioRevision as fake-istio-cr.sh; the istiod Deployment
# rolls out on its first read, is rolled out on its second, and every later read fails.
_rollout_kubectl() {
	local n
	case " $* " in
	*" get deployments.apps istiod -o json "*)
		n="$(cat "${BATS_TEST_TMPDIR}/deploy-reads" 2>/dev/null || echo 0)"
		echo $((n + 1)) > "${BATS_TEST_TMPDIR}/deploy-reads"
		case "$n" in
		0) echo '{"metadata":{"generation":5},"status":{"observedGeneration":5,"replicas":3,"updatedReplicas":2,"readyReplicas":3}}' ;;
		1) echo '{"metadata":{"generation":5},"status":{"observedGeneration":5,"replicas":2,"updatedReplicas":2,"readyReplicas":2}}' ;;
		*)
			echo "Unable to connect to the server: net/http: TLS handshake timeout" >&2
			return 1 ;;
		esac ;;
	*) "$FAKE_CR" "$@" ;;
	esac
}

# _pv_kubectl: istiod pods and their metrics for istio_proxy_versions, from files in pv/:
# <ctx>.pods (the Running istiod pods, one per line; no file: the list fails) and
# <pod>.metrics (its /metrics body; no file: the read fails); the Istio CR reads as
# fake-istio-cr.sh. Logs each call.
_pv_kubectl() {
	local ctx="" a d="${BATS_TEST_TMPDIR}/pv"
	for a in "$@"; do [[ "$a" == --context=* ]] && ctx="${a#--context=}"; done
	echo "$*" >> "${d}/log"
	case " $* " in
	*" get pods -l app=istiod "*)
		if [[ ! -f "${d}/${ctx}.pods" ]]; then
			echo "error: You must be logged in to the server (Unauthorized)" >&2
			return 1
		fi
		sed 's#^#pod/#' "${d}/${ctx}.pods" ;;
	*" get --raw /api/v1/namespaces/istio-system/pods/"*)
		a="$*"
		a="${a##*/pods/}"
		a="${a%%:15014/proxy/metrics*}"
		if [[ ! -f "${d}/${a}.metrics" ]]; then
			echo "Error from server (ServiceUnavailable): the server is currently unable to handle the request" >&2
			return 1
		fi
		cat "${d}/${a}.metrics" ;;
	*) "$FAKE_CR" "$@" ;;
	esac
}

# pv_pod <pod> <version=count>...: a pod's metrics with those pilot_xds series.
pv_pod() {
	local p="$1" kv
	shift
	{
		echo '# HELP pilot_xds Number of endpoints connected to this pilot using XDS.'
		echo '# TYPE pilot_xds gauge'
		for kv in "$@"; do printf 'pilot_xds{version="%s"} %s\n' "${kv%=*}" "${kv#*=}"; done
		echo '# TYPE pilot_xds_pushes counter'
		echo 'pilot_xds_pushes{type="cds"} 42'
	} > "${BATS_TEST_TMPDIR}/pv/${p}.metrics"
}

@test "the Istio CR or its IstioRevision edited during a sweep at the same version and revision is a problem naming what changed; an unread generation is not compared" {
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		export ISTIO_VERSION=v1.30.5 ISTIO_VERSION_READY_WAIT_SEC=0
		istio_version_resolve ci-a,ci-b 0 "$1" 2>/dev/null
		echo "GENS=${ISTIO_GENERATIONS}"
		out=(); istio_version_recheck out "$1"; echo "SAME=${#out[@]}"
		export STUB_ISTIO_CR_GEN=3
		out=(); istio_version_recheck out "$1"; printf "%s\n" "${out[@]}"
		export STUB_ISTIO_CR_GEN=2 STUB_ISTIO_REV_GEN=5
		out=(); istio_version_recheck out "$1"; printf "%s\n" "${out[@]}"
		export STUB_ISTIO_VERSION=fail
		out=(); istio_version_recheck out "$1"; printf "%s\n" "${out[@]}"' _ "$FAKE_CR"
	assert_success
	assert_line --index 0 "GENS=ci-a=2/2,ci-b=2/2"
	assert_line --index 1 "SAME=0"
	assert_line --index 2 "--problem"
	assert_line --index 3 "the Istio CR or its IstioRevision was edited during the sweep, though the version and active revision read the same at the end (ci-a: its Istio CR default (generation 2 at the start, 3 at the end); ci-b: its Istio CR default (generation 2 at the start, 3 at the end); ISTIO_GENERATIONS): a version changed and changed back, or a values change (an edit of the Istio CR), so its rows may not all come from one control-plane configuration"
	assert_line --index 4 "--problem"
	assert_line --index 5 --partial "(ci-a: its IstioRevision default (generation 2 at the start, 5 at the end); ci-b: its IstioRevision default (generation 2 at the start, 5 at the end); ISTIO_GENERATIONS)"
	# Unreadable at the end: unconfirmed (a note), never a generation problem.
	refute_output --partial "$(printf '%s\n' --problem "the Istio CR or its IstioRevision was edited during the sweep, though the version and active revision read the same at the end (ci-a: its Istio CR default (generation 2 at the start, 2")"
	assert_line --index 6 "--note"
	assert_line --index 7 --partial "the Istio version at the end of the sweep is unconfirmed"
	[ "${#lines[@]}" -eq 8 ]
}

@test "through 003, an Istio CR edited during the sweep is a problem in its outcome (exit 4); a --resume refuses a sweep whose Istio CR was edited since it started" {
	local d tsv
	# The generation goes from 2 to 3 right after the start's read.
	echo 3 > "${BATS_TEST_TMPDIR}/bump-on-pods"
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	d="$(sweep_dir)"
	tsv="$(find "$d" -maxdepth 1 -name 'controlplane-*.tsv')"
	grep -qx '# ISTIO_GENERATIONS=ci-a=2/2' "$tsv"
	assert_output --partial "error: the Istio CR or its IstioRevision was edited during the sweep, though the version and active revision read the same at the end (ci-a: its Istio CR default (generation 2 at the start, 3 at the end); ISTIO_GENERATIONS)"
	grep -q '^PROBLEM=the Istio CR or its IstioRevision was edited during the sweep' "$d/sweep-outcome.txt"
	# A --resume refuses a recorded problem anyway; without it, it refuses the edit itself,
	# before any change.
	rm -f "${BATS_TEST_TMPDIR}/bump-on-pods"
	sed -i.bak '/^PROBLEM=/d' "$d/sweep-outcome.txt" && rm -f "$d/sweep-outcome.txt.bak"
	local before
	before="$(cat "$tsv")"
	cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 1
	assert_output --partial "--resume: the Istio CR or its active IstioRevision was edited since this sweep started (ci-a: Istio CR generation 2 when the sweep started, 3 now; ISTIO_GENERATIONS), at the same version and active revision"
	[ "$(cat "$tsv")" = "$before" ]
	# Back at the generation it started on (nothing edited since): it resumes.
	echo 2 > "${BATS_TEST_TMPDIR}/crgen"
	cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	refute_output --partial "was edited since this sweep started"
}

@test "a rollout that ended, whose confirming read then fails, is not ready (rollout-unconfirmed), never the ok the read before it saw" {
	# POLL = WAIT: the first poll is at the deadline; the rollout ends there, so it gets its
	# extra read one poll later, which fails.
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		export ISTIO_VERSION=v1.30.5 ISTIO_VERSION_READY_WAIT_SEC=2 ISTIO_VERSION_READY_POLL_SEC=2
		eval "$2"; FAKE_CR="$1"
		istio_version_resolve ci-a 0 _rollout_kubectl
		echo "V=${ISTIO_VERSION} NR=${ISTIO_NOTREADY_AT_START}"' _ "$FAKE_CR" "$(declare -f _rollout_kubectl)" 2>/dev/null
	[ "$(cat "${BATS_TEST_TMPDIR}/deploy-reads")" -eq 3 ]
	assert_line "V=v1.30.5 NR=ci-a=rollout-unconfirmed"
	# The note names it.
	local -a o=()
	_istio_notready_notes o start "ci-a=rollout-unconfirmed" 2
	[[ "${o[*]}" == *"rollout-unconfirmed (an istiod rollout had just ended, and the read that confirms no old istiod pod still serves failed) on 1 member (ci-a)"* ]]
}

@test "istio_proxy_versions sums pilot_xds by version over a member's istiod pods, read through the API server's pod proxy; none, unknown per member" {
	mkdir -p "${BATS_TEST_TMPDIR}/pv"
	printf '%s\n' istiod-a1 istiod-a2 > "${BATS_TEST_TMPDIR}/pv/a.pods"
	pv_pod istiod-a1 1.30.5=100 1.30.4=3 1.29.9=0
	pv_pod istiod-a2 1.30.5=20
	echo istiod-b1 > "${BATS_TEST_TMPDIR}/pv/b.pods"
	pv_pod istiod-b1
	# c: the pod list fails; d: one pod of two cannot be read; e: no Running istiod pod;
	# f: an answer that is not Prometheus text.
	printf '%s\n' istiod-d1 istiod-d2 > "${BATS_TEST_TMPDIR}/pv/d.pods"
	pv_pod istiod-d1 1.30.5=7
	: > "${BATS_TEST_TMPDIR}/pv/e.pods"
	echo istiod-f1 > "${BATS_TEST_TMPDIR}/pv/f.pods"
	echo '<html>proxy error</html>' > "${BATS_TEST_TMPDIR}/pv/istiod-f1.metrics"
	METRICS_SCRAPE_TIMEOUT=7 run istio_proxy_versions a,b,c,d,e,f _pv_kubectl
	assert_success
	assert_output "a=1.30.5:120+1.30.4:3,b=none,c=unknown,d=unknown,e=unknown,f=unknown"
	run cat "${BATS_TEST_TMPDIR}/pv/log"
	assert_line "--context=a --request-timeout=5s -n istio-system get pods -l app=istiod --field-selector=status.phase=Running --no-headers -o custom-columns=NAME:.metadata.name,DELETING:.metadata.deletionTimestamp"
	assert_line "--context=a --request-timeout=7s get --raw /api/v1/namespaces/istio-system/pods/istiod-a1:15014/proxy/metrics"
	refute_output --partial "port-forward"
	# Off the istiod version: a warning at the start (never a stop), a note at the end.
	ISTIO_PROXY_VERSIONS="a=1.30.5:120+1.30.4:3,b=none,c=unknown" ISTIO_VERSION_BY_CONTEXT="a=v1.30.5,b=v1.30.5,c=v1.30.5" \
		run --separate-stderr _istio_proxy_versions_warn
	assert_success
	[[ "$stderr" == "warning: proxies on another Istio version than their istiod are connected (a (istiod 1.30.5): 3 on 1.30.4; ISTIO_PROXY_VERSIONS): a sidecar keeps the version it was injected with until its pod restarts. The run goes on;"* ]]
	ISTIO_PROXY_VERSIONS="a=1.30.5:120,b=none" ISTIO_VERSION_BY_CONTEXT="a=v1.30.5,b=v1.30.5" run --separate-stderr _istio_proxy_versions_warn
	[ -z "$stderr" ]
}

@test "istio_version_resolve records ISTIO_PROXY_VERSIONS (unchecked under --dry-run, without a read), istio_version_kv writes it, and the end of the sweep notes proxies off their istiod's version" {
	mkdir -p "${BATS_TEST_TMPDIR}/pv"
	echo istiod-a1 > "${BATS_TEST_TMPDIR}/pv/ci-a.pods"
	pv_pod istiod-a1 1.30.5=50 1.30.4=2
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		eval "$2"; FAKE_CR="$1"
		export ISTIO_VERSION=v1.30.5 ISTIO_VERSION_READY_WAIT_SEC=0
		istio_version_resolve ci-a 0 _pv_kubectl
		istio_version_kv | grep "^ISTIO_PROXY_VERSIONS="
		out=(); istio_version_recheck out _pv_kubectl; printf "%s\n" "${out[@]}"' _ "$FAKE_CR" "$(declare -f _pv_kubectl)"
	assert_success
	assert_line --index 0 "ISTIO_PROXY_VERSIONS=ci-a=1.30.5:50+1.30.4:2"
	assert_line --index 1 "--note"
	assert_line --index 2 "proxies on another Istio version than their istiod were connected at the start (ci-a (istiod 1.30.5): 2 on 1.30.4; ISTIO_PROXY_VERSIONS): a sidecar keeps the version it was injected with until its pod restarts, so part of the traffic and xDS load came from it"
	[[ "$stderr" == *"warning: proxies on another Istio version than their istiod are connected (ci-a (istiod 1.30.5): 2 on 1.30.4;"* ]]
	: > "${BATS_TEST_TMPDIR}/pv/log"
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		eval "$2"; FAKE_CR="$1"
		export ISTIO_VERSION=v1.30.5
		istio_version_resolve ci-a 1 _pv_kubectl
		istio_version_kv | grep "^ISTIO_PROXY_VERSIONS="' _ "$FAKE_CR" "$(declare -f _pv_kubectl)"
	assert_output "ISTIO_PROXY_VERSIONS=unchecked"
	[ ! -s "${BATS_TEST_TMPDIR}/pv/log" ]
}

@test "env_proxy_versions_summary sums over the members without naming them; controlplane 004 and the envelope print it" {
	run env_proxy_versions_summary "ci-a=1.30.5:120+1.30.4:3,ci-b=1.30.5:5,ci-c=none,ci-d=unknown"
	assert_output "1.30.5: 125, 1.30.4: 3 (4 members; 1 with none; 1 unknown)"
	run env_proxy_versions_summary "ci-a=none"
	assert_output "no proxy connected (1 member; 1 with none)"
	run env_proxy_versions_summary "ci-a=unknown"
	assert_output "unknown (1 member; 1 unknown)"
	run env_proxy_versions_summary unchecked
	assert_output unchecked
	run env_proxy_versions_summary ""
	assert_output unknown
	local r="${BATS_TEST_TMPDIR}/sweep-pv"
	mkdir -p "$r"
	awk '/^# HARNESS_SHA=/ { print "# ISTIO_GENERATIONS=mesh-a=2/2,mesh-b=3/2"; print "# ISTIO_PROXY_VERSIONS=mesh-a=1.30.5:30,mesh-b=1.30.5:34+1.30.4:2" } { print }' "$FIXTURE" > "${r}/controlplane-fixture-t2.tsv"
	run --separate-stderr "$REPORT" --results-dir "$r" --format text
	assert_output --partial "  proxy versions (at start):   1.30.5: 64, 1.30.4: 2 (2 members)  [proxies connected to istiod, by Istio version, summed over the members]"
	run --separate-stderr "$REPORT" --results-dir "$r" --format md
	assert_line 'istio_proxy_versions: "mesh-a=1.30.5:30,mesh-b=1.30.5:34+1.30.4:2"'
	assert_line 'istio_generations: "mesh-a=2/2,mesh-b=3/2"'
	assert_output --partial "| proxy versions at start (connected to istiod, summed over the members) | 1.30.5: 64, 1.30.4: 2 (2 members) |"
	run --separate-stderr "$REPORT" --results-dir "$r" --format csv
	assert_output --partial "ISTIO_PROXY_VERSIONS=mesh-a=1.30.5:30,mesh-b=1.30.5:34+1.30.4:2"
	run --separate-stderr "$REPORT" --results-dir "$r" --format json
	[ "$(jq -r '.metadata.istio_proxy_versions' <<<"$output")" = "mesh-a=1.30.5:30,mesh-b=1.30.5:34+1.30.4:2" ]
	[ "$(jq -r '.metadata.istio_generations' <<<"$output")" = "mesh-a=2/2,mesh-b=3/2" ]
	source "${ROOT}/tests/lib/platform.sh"
	run --separate-stderr render_scale_envelope "$r" "$REPORT" "mesh-a,mesh-b" false
	assert_output --partial "| Proxy (Envoy) versions at the start | 1.30.5: 64, 1.30.4: 2 (2 members) |"
	# A TSV from before ISTIO_PROXY_VERSIONS: unknown, never a guess.
	cp "$FIXTURE" "${r}/controlplane-fixture-t2.tsv"
	run --separate-stderr "$REPORT" --results-dir "$r" --format json
	[ "$(jq -r '.metadata.istio_proxy_versions' <<<"$output")" = "unknown" ]
}

@test "kubectl errors are recorded with API hosts and addresses masked; context names stay; localhost:8080 and a bracketed time are not masked" {
	run _istio_version_mask 'Get "https://api.ci-a.example:6443/apis/sailoperator.io/v1/istios/default?timeout=5s": dial tcp 192.0.2.10:6443: i/o timeout'
	assert_output 'Get "https://<api-host>:6443/apis/sailoperator.io/v1/istios/default?timeout=5s": dial tcp <ip>: i/o timeout'
	run _istio_version_mask 'Unable to connect to the server: dial tcp: lookup api.ci-a.example on 192.0.2.53:53: no such host'
	assert_output 'Unable to connect to the server: dial tcp: lookup <api-host> on <ip>: no such host'
	run _istio_version_mask 'Unable to connect to the server: dial tcp [2001:db8::1]:6443: connect: connection refused'
	assert_output 'Unable to connect to the server: dial tcp <ip>: connect: connection refused'
	run _istio_version_mask 'Get "https://[2001:db8:0:0:0:0:0:1]:6443/api": x'
	assert_output 'Get "https://<api-host>:6443/api": x'
	run _istio_version_mask 'The connection to the server api.ci-a.example:6443 was refused - did you specify the right host or port?'
	assert_output 'The connection to the server <api-host> was refused - did you specify the right host or port?'
	# kubectl without a kubeconfig context: not an API host refusing, so it stays apart.
	run _istio_version_mask 'The connection to the server localhost:8080 was refused - did you specify the right host or port?'
	assert_output 'The connection to the server localhost:8080 was refused - did you specify the right host or port?'
	run _istio_version_mask 'tls: failed to verify certificate: x509: certificate is valid for api.ci-b.example, *.apps.ci-b.example, not api.ci-a.example'
	assert_output 'tls: failed to verify certificate: x509: certificate is valid for <names>, not <api-host>'
	# Bracketed text that is no IPv6 address stays.
	run _istio_version_mask 'retrying [a:b] at [10:00:00.1]'
	assert_output 'retrying [a:b] at [10:00:00.1]'
	run _istio_version_mask 'error: context "ci-a" does not exist'
	assert_output 'error: context "ci-a" does not exist'
	# Grouping keys: members whose certificates differ group; localhost:8080 does not group
	# with a real API host refusing; a context kubectl does not find groups by message.
	[ "$(_istio_version_hostkey 'x509: certificate is valid for api.ci-a.example, not api.ci-x.example')" = \
		"$(_istio_version_hostkey 'x509: certificate is valid for api.ci-b.example, *.apps.ci-b.example, not api.ci-y.example')" ]
	[ "$(_istio_version_hostkey 'The connection to the server localhost:8080 was refused')" != \
		"$(_istio_version_hostkey 'The connection to the server api.ci-a.example:6443 was refused')" ]
	[ "$(_istio_version_hostkey 'error: context "ci-a" does not exist')" = "$(_istio_version_hostkey 'error: context "ci-b" does not exist')" ]
	# The why recorded from kubectl's stderr (_istio_version_errline): masked, klog prefix gone.
	printf 'E1017 10:00:00.000000   12345 memcache.go:265] couldn'"'"'t get current server API group list: Get "https://api.ci-a.example:6443/api?timeout=32s": dial tcp 198.51.100.7:6443: i/o timeout\n' > "${BATS_TEST_TMPDIR}/err"
	run _istio_version_errline "${BATS_TEST_TMPDIR}/err"
	assert_output 'couldn'"'"'t get current server API group list: Get "https://<api-host>:6443/api?timeout=32s": dial tcp <ip>: i/o timeout'
}

@test "through 003, the outcome and the console name no API host or address of an unreadable member" {
	local d
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
*"get istios.sailoperator.io default"*) echo 'Unable to connect to the server: dial tcp: lookup api.ci-a.example on 192.0.2.53:53: no such host' >&2; exit 1 ;;
*) exit 1 ;;
esac
STUB
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	assert_output --partial "lookup <api-host> on <ip>: no such host"
	refute_output --partial "api.ci-a.example"
	refute_output --partial "192.0.2.53"
	d="$(sweep_dir)"
	! grep -rqF -e "api.ci-a.example" -e "192.0.2.53" "$d"
}
