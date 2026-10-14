#!/usr/bin/env bash
# Least-squares fits and growth projections for the namespace-scaling report and the
# growth-mode memory guard. Sourced, never executed.
#
# Consumers: controlplane (004 namespace-scaling section, 003 memory stop guard)
#
# Exposes:
#   FIT_AWK                          -> awk function library (prepend to an awk program):
#                                       fit_isnum(s); fit_lin(xs, ys, n) and fit_exp(xs, ys, n)
#                                       set the globals FIT_SLOPE FIT_ICPT FIT_R2 FIT_N FIT_EXP
#                                       ("N/A" when there is nothing to fit)
#   fit_linear                       -> stdin "x y" lines; prints "slope intercept r2 n"
#                                       (N/A fields with fewer than 2 distinct x)
#   fit_loglog                       -> stdin "x y" lines; prints the log-log exponent
#                                       (slope of ln y on ln x; 1 = linear, 2 = quadratic),
#                                       N/A with fewer than 2 distinct positive points
#   mem_guard_project <cur> <base> <ratio> <power>
#                                    -> base + max(cur - base, 0) * ratio^power, never below
#                                       cur (a usage below the empty-mesh base projects as
#                                       the base, the conservative side); "unknown" on a
#                                       non-numeric input
#   mem_guard_verdict <value> <limit> <pct>
#                                    -> "stop" when value > limit * pct / 100, "ok" when not,
#                                       "unknown" when an input is missing or the limit <= 0
#
# Non-numeric points (N/A, overflow, unknown) are skipped, never read as 0.
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# shellcheck disable=SC2016
FIT_AWK='
function fit_isnum(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/ }
# fit_lin: ordinary least squares of y on x over xs[1..n]/ys[1..n] (numeric points only).
function fit_lin(xs, ys, n,    i, m, sx, sy, sxx, sxy, d, mx, my, ssr, sst, e, seen, nd) {
	FIT_SLOPE = "N/A"; FIT_ICPT = "N/A"; FIT_R2 = "N/A"; FIT_N = 0
	m = 0; sx = 0; sy = 0; sxx = 0; sxy = 0; nd = 0
	split("", seen)
	for (i = 1; i <= n; i++) {
		if (!fit_isnum(xs[i]) || !fit_isnum(ys[i])) continue
		m++; sx += xs[i]; sy += ys[i]; sxx += xs[i] * xs[i]; sxy += xs[i] * ys[i]
		if (!((xs[i] + 0) in seen)) { seen[xs[i] + 0] = 1; nd++ }
	}
	FIT_N = m
	if (nd < 2) return
	d = m * sxx - sx * sx
	if (d == 0) return
	FIT_SLOPE = (m * sxy - sx * sy) / d
	FIT_ICPT = (sy - FIT_SLOPE * sx) / m
	my = sy / m; ssr = 0; sst = 0
	for (i = 1; i <= n; i++) {
		if (!fit_isnum(xs[i]) || !fit_isnum(ys[i])) continue
		e = ys[i] - (FIT_ICPT + FIT_SLOPE * xs[i]); ssr += e * e
		sst += (ys[i] - my) * (ys[i] - my)
	}
	# A flat series fits exactly (ssr <= sst, so sst == 0 means ssr == 0).
	FIT_R2 = (sst > 0) ? 1 - ssr / sst : 1
}
# fit_exp: log-log exponent over the points with x > 0 and y > 0.
function fit_exp(xs, ys, n,    i, k, lx, ly) {
	FIT_EXP = "N/A"
	k = 0
	split("", lx); split("", ly)
	for (i = 1; i <= n; i++) {
		if (!fit_isnum(xs[i]) || !fit_isnum(ys[i]) || xs[i] + 0 <= 0 || ys[i] + 0 <= 0) continue
		k++; lx[k] = log(xs[i]); ly[k] = log(ys[i])
	}
	if (k < 2) return
	fit_lin(lx, ly, k)
	FIT_EXP = FIT_SLOPE
	# fit_lin above overwrote the linear-fit globals; callers run fit_exp first.
}
'

# fit_linear: stdin "x y" lines -> "slope intercept r2 n".
# shellcheck disable=SC2329
fit_linear() {
	awk "${FIT_AWK}"'
	NF >= 2 { n++; xs[n] = $1; ys[n] = $2 }
	END {
		fit_lin(xs, ys, n)
		printf "%s %s %s %d\n", \
			(FIT_SLOPE == "N/A" ? "N/A" : sprintf("%.6g", FIT_SLOPE)), \
			(FIT_ICPT == "N/A" ? "N/A" : sprintf("%.6g", FIT_ICPT)), \
			(FIT_R2 == "N/A" ? "N/A" : sprintf("%.4f", FIT_R2)), FIT_N
	}'
}

# fit_loglog: stdin "x y" lines -> exponent (two decimals) or N/A.
# shellcheck disable=SC2329
fit_loglog() {
	awk "${FIT_AWK}"'
	NF >= 2 { n++; xs[n] = $1; ys[n] = $2 }
	END {
		fit_exp(xs, ys, n)
		print (FIT_EXP == "N/A" ? "N/A" : sprintf("%.2f", FIT_EXP))
	}'
}

# mem_guard_project <cur> <base> <ratio> <power>: projected usage after a step that
# multiplies the cost above the empty-mesh base by ratio^power (power 1: linear in
# namespaces; 2: wide scoping, N scopes each holding N namespaces).
# shellcheck disable=SC2329
mem_guard_project() {
	awk -v c="${1:-}" -v b="${2:-}" -v r="${3:-}" -v p="${4:-}" '
	function isnum(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	BEGIN {
		if (!isnum(c) || !isnum(b) || !isnum(r) || !isnum(p)) { print "unknown"; exit }
		d = c - b; if (d < 0) d = 0
		v = b + d * (r ^ p)
		if (v < c) v = c
		printf "%.0f\n", v
	}'
}

# mem_guard_verdict <value> <limit> <pct>
# shellcheck disable=SC2329
mem_guard_verdict() {
	awk -v v="${1:-}" -v l="${2:-}" -v p="${3:-}" '
	function isnum(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	BEGIN {
		if (!isnum(v) || !isnum(l) || !isnum(p) || l + 0 <= 0) { print "unknown"; exit }
		print (v + 0 > l * p / 100) ? "stop" : "ok"
	}'
}
