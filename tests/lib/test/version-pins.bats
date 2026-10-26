#!/usr/bin/env bats
# Keep-in-sync version pins (AGENTS.md "Version pins"): the defaults in config/versions.env and the
# chart values that repeat them. A bump in one place only fails here, instead of deploying one
# version while the results record another. Charts are found by their image repository, so a new
# chart that uses one of these images is checked too.

load test_helper

VALUES_FILES=("${ROOT}"/charts/*/values.yaml "${ROOT}"/tests/*/chart/values.yaml)

# pin_default <VAR>: VAR's default in config/versions.env (export VAR="${VAR:-<default>}").
pin_default() {
	awk -v v="$1" '
		index($0, "export " v "=\"${" v ":-") == 1 {
			s = substr($0, length("export " v "=\"${" v ":-") + 1)
			sub(/}"[[:space:]]*$/, "", s)
			print s
		}' "${ROOT}/config/versions.env"
}

# chart_tags <values.yaml> <repository>: the tag of every image whose `repository:` is
# <repository>, one per line, unquoted. The tag must follow within three lines (comments may sit
# between); "<no tag>" when it does not.
chart_tags() {
	awk -v repo="$2" '
		want > 0 && $1 == "tag:" { t = $2; gsub(/["\047]/, "", t); print t; want = 0; next }
		want > 0 && --want == 0 { print "<no tag>" }
		$1 == "repository:" { r = $2; gsub(/["\047]/, "", r); if (r == repo) want = 3 }
		END { if (want > 0) print "<no tag>" }
	' "$1"
}

# assert_image_pin <VAR> <repository> <min files>: every values file with that image uses VAR's
# default as its tag, and at least <min files> files have it (so a moved image is not skipped).
assert_image_pin() {
	local var="$1" repo="$2" min="$3" want f t tags n=0
	want="$(pin_default "$var")"
	[[ -n "$want" ]] || fail "no default for ${var} in config/versions.env"
	for f in "${VALUES_FILES[@]}"; do
		tags="$(chart_tags "$f" "$repo")"
		[[ -n "$tags" ]] || continue
		n=$((n + 1))
		while IFS= read -r t; do
			[[ "$t" == "$want" ]] \
				|| fail "${f#"${ROOT}"/}: ${repo} tag is '${t}', but ${var} in config/versions.env is '${want}'; keep them in sync"
		done <<<"$tags"
	done
	((n >= min)) || fail "found ${repo} in ${n} values files, expected at least ${min}; update this test if the image moved"
}

@test "version pins: charts/spoke-ossm istioVersion is ISTIO_VERSION, and every chart tag of the busybox, fortio and http-echo images is its versions.env default" {
	local want got
	want="$(pin_default ISTIO_VERSION)"
	got="$(awk '$1 == "istioVersion:" { v = $2; gsub(/["\047]/, "", v); print v }' "${ROOT}/charts/spoke-ossm/values.yaml")"
	[[ -n "$want" && "$got" == "$want" ]] \
		|| fail "charts/spoke-ossm/values.yaml istioVersion is '${got}', but ISTIO_VERSION in config/versions.env is '${want}'; keep them in sync"
	assert_image_pin BUSYBOX_VERSION busybox 4
	assert_image_pin FORTIO_VERSION fortio/fortio 2
	assert_image_pin HTTP_ECHO_VERSION hashicorp/http-echo 3
}
