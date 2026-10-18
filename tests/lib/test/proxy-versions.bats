#!/usr/bin/env bats
# The proxy-version read (istio_proxy_versions, tests/lib/preamble.sh): an istiod pod being
# deleted (a deletionTimestamp: Terminating, its proxies moving to the other pods) is left
# out with a note; each pod's /metrics body is folded into the member's sums as it arrives
# and deleted before the next pod is read, so one member never keeps more than one body on
# disk. No cluster: kubectl is a stub.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/preamble.sh"

setup() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export PV_LOG="${BATS_TEST_TMPDIR}/pv.log" TMPDIR="${BATS_TEST_TMPDIR}/tmp"
	mkdir -p "$TMPDIR"
	: > "$PV_LOG"
	# kubectl: the istiod pods of PV_PODS ("name:deleting ..."; deleting is <none> or a
	# time), as custom-columns prints them; each /metrics read logs the pod and the files
	# under TMPDIR then (their names), and answers 3 proxies on 1.30.5.
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
*" get pods -l app=istiod "*)
	for p in $PV_PODS; do printf '%s   %s\n' "${p%%:*}" "${p#*:}"; done ;;
*"/proxy/metrics"*)
	p="${!#}"; p="${p##*/pods/}"; p="${p%%:*}"
	echo "read ${p}: $(find "$TMPDIR" -type f | sed 's|.*/||' | sort | tr '\n' ' ')" >> "$PV_LOG"
	printf '# TYPE pilot_xds gauge\npilot_xds{version="1.30.5"} 3\n' ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
}

@test "an istiod pod being deleted (Terminating) is left out of the proxy-version read, with a note naming the member and the count" {
	PV_PODS="istiod-a:<none> istiod-b:2026-10-18T00:00:00Z istiod-c:<none>" PATH="${BIN}:${PATH}" \
		run --separate-stderr istio_proxy_versions ci-a kubectl
	assert_success
	assert_output "ci-a=1.30.5:6"
	[ "$stderr" = "note: ci-a: 1 istiod pod(s) being deleted (Terminating) left out of its proxy-version read (ISTIO_PROXY_VERSIONS): their proxies are moving to the other pods" ]
	! grep -q "read istiod-b" "$PV_LOG"
	# Every pod being deleted: unknown, and the note.
	: > "$PV_LOG"
	PV_PODS="istiod-a:2026-10-18T00:00:00Z" PATH="${BIN}:${PATH}" run --separate-stderr istio_proxy_versions ci-a kubectl
	assert_output "ci-a=unknown"
	[[ "$stderr" == "note: ci-a: 1 istiod pod(s) being deleted"* ]]
	[ ! -s "$PV_LOG" ]
	# None being deleted: no note.
	PV_PODS="istiod-a:<none> istiod-c:<none>" PATH="${BIN}:${PATH}" run --separate-stderr istio_proxy_versions ci-a kubectl
	assert_output "ci-a=1.30.5:6"
	[ -z "$stderr" ]
}

@test "each pod's /metrics body is folded into the member's sums and deleted before the next pod is read; nothing is left in TMPDIR" {
	PV_PODS="istiod-a:<none> istiod-b:<none> istiod-c:<none>" PATH="${BIN}:${PATH}" run --separate-stderr istio_proxy_versions ci-a kubectl
	assert_success
	assert_output "ci-a=1.30.5:9"
	# The member's own output file, the body being read, and the sums of the pods before.
	[ "$(sed -n 1p "$PV_LOG")" = "read istiod-a: 0 body " ]
	[ "$(sed -n 2p "$PV_LOG")" = "read istiod-b: 0 body sums " ]
	[ "$(sed -n 3p "$PV_LOG")" = "read istiod-c: 0 body sums " ]
	run find "$TMPDIR" -mindepth 1
	assert_output ""
}
