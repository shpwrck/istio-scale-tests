#!/usr/bin/env bash
# The one definition of which propagation endpoint rows count. Sourced, never executed.
#
# Consumers: propagation (002 probe summary and .md, 005 report)
#
# Exposes:
#   PROP_ROW_AWK                     -> awk function library (prepend to an awk program run
#                                       with FS="\t" over endpoint TSV rows, $0 = one row):
#                                       prop_drop_reason(maxskew) -> "" when the row counts,
#                                         else why it is dropped: its status when not OK,
#                                         else restarted=1|unknown, p1_overflow, or
#                                         scrape_skew>MAX (pre-gate TSVs, field 19);
#                                       prop_p1_sample(), prop_p3_sample() -> 1 when p1_ms /
#                                         p3_ms is a number; prop_p2_sample() -> 1 when p2_ms
#                                         is a number and p2_dirty is not 1 (EDS bumped but
#                                         the canary never went healthy on that remote)
#
# 002 summarizes its own rows with it and 005 aggregates every TSV with it, so the
# probe's summary and the report average the same rows (R6). Columns: 7 p1_ms, 8 p2_ms,
# 9 p3_ms, 10 status, 15 p1_overflow, 16 restarted, 17 p2_dirty and 19 scrape_skew_ms
# (both absent from pre-fanout TSVs with 18 columns: p2_dirty reads 0, no skew gate).
# shellcheck shell=bash

# shellcheck disable=SC2016,SC2034  # awk source, read by the scripts that source this file
PROP_ROW_AWK='
function prop_drop_reason(maxskew,    st, ov, rs, sk) {
	st = $10
	ov = ($15 == "") ? "0" : $15
	rs = ($16 == "") ? "0" : $16
	sk = (NF >= 19 && $19 ~ /^[0-9]+$/) ? ($19 + 0) : -1
	if (maxskew == "") maxskew = 1000
	if (st != "" && st != "OK") return st
	if (rs == "1" || rs == "unknown") return "restarted=" rs
	if (ov == "1") return "p1_overflow"
	# A pre-gate TSV row (status OK) whose skew exceeds the current ceiling.
	if (sk >= 0 && sk > maxskew + 0) return "scrape_skew>" maxskew
	return ""
}
function prop_p1_sample() { return ($7 ~ /^[0-9]+$/) }
function prop_p2_sample(    dirty) {
	dirty = (NF >= 19 && $17 != "") ? $17 : "0"
	return (dirty != "1" && $8 ~ /^[0-9]+$/)
}
function prop_p3_sample() { return ($9 ~ /^[0-9]+$/) }
'
