#!/usr/bin/env bash
# The one definition of the propagation endpoint TSV schema and of which of its rows count.
# Sourced, never executed.
#
# Consumers: propagation (002 probe rows, summary and .md; 005 report; 006 placeholder
# rows), tuning (004 comparison)
#
# Exposes:
#   PROP_TSV_HEADER                  -> the header line every endpoint TSV writer emits (23
#                                       tab-separated columns, below), so 002 and 006's
#                                       placeholder write one schema (PL36)
#   prop_placeholder_row <run_id> <mesh_size> <source_ctx> <status>
#                                    -> one degraded row in that schema: the status in
#                                       status, p1_status and remote_status, restarted
#                                       unknown, every number N/A (in n_total, never n_valid)
#   PROP_ROW_AWK                     -> awk function library (prepend to an awk program run
#                                       with FS="\t" over endpoint TSV rows, $0 = one row):
#                                       prop_drop_reason(maxskew) -> "" when the row counts
#                                         for P2 and P3, else why it is dropped, from the
#                                         remote side only: remote_status (22) when not
#                                         OK or DRAIN_TIMEOUT (which counts), else
#                                         remote_scrape_skew>MAX (23). A row with no
#                                         remote (remote_status N/A) measures only P1, so
#                                         prop_p1_drop_reason decides it. A TSV from before
#                                         columns 22-23 has no remote-only verdict: its row
#                                         status when not OK or DRAIN_TIMEOUT, else
#                                         restarted=1|unknown, else scrape_skew>MAX (field
#                                         19); never p1_overflow, a source histogram (on a
#                                         row with no remote too)
#                                       prop_p1_drop_reason(maxskew) -> "" when the row's
#                                         iteration has a P1 sample, else why not, from the
#                                         source-side columns only: p1_status (20) when
#                                         not OK or DRAIN_TIMEOUT, else p1_overflow, else
#                                         p1_scrape_skew>MAX (21); a TSV from before them
#                                         (19 columns): the status (DRAIN_TIMEOUT counts),
#                                         restarted, p1_overflow and skew of the row
#                                       prop_p1_first(maxskew) -> 1 on the row that carries
#                                         its iteration's P1, 0 on the others: P1 (p1_ms and
#                                         the P1 convergence histogram) is measured once per
#                                         iteration on the source and copied onto every
#                                         remote's row, so it is one sample per (run_id,
#                                         iteration), never one per row. That row is
#                                         the iteration's first when prop_p1_drop_reason
#                                         keeps it, so a remote that timed out or restarted
#                                         never drops the source's P1; in a 19-column
#                                         TSV, the first row prop_p1_drop_reason keeps
#                                       prop_p1_sample(maxskew) -> 1 when prop_p1_first() and
#                                         p1_ms is a number; prop_p3_sample() -> 1 when p3_ms
#                                         is a number; prop_p2_sample() -> 1 when p2_ms is a
#                                         number and p2_dirty is not 1 (EDS bumped but the
#                                         canary never went healthy on that remote)
#                                       Call prop_p1_first/prop_p1_sample on every row, before
#                                       any row filter, in file order; call prop_p2_sample
#                                       and prop_p3_sample only on rows that prop_drop_reason
#                                       keeps.
#
# 002 summarizes its own rows with it and 005 (every format) and tuning 004 aggregate
# every TSV with it, so the probe's summary and the reports average the same rows.
# Columns: 1 run_id, 2 mesh_size, 3 iteration, 4 source_ctx, 5 remote_ctx (N/A: no remote),
# 6 t0_epoch_ns, 7 p1_ms, 8 p2_ms, 9 p3_ms, 10 status (the row's: either side), 11-12 the P1
# convergence p50/p99, 13 p1_sample_count, 14 p1_proxy_count, 15 p1_overflow, 16 restarted
# (the source's or this remote's istiod), 17 p2_dirty, 18 window_ms, 19 scrape_skew_ms (the
# widest of the source's and every remote's baseline), 20 p1_status and 21
# p1_scrape_skew_ms: the iteration's source-side verdict and source scrape skew, the
# same on every row of the iteration, 22 remote_status and 23 remote_scrape_skew_ms:
# this remote's own verdict for P2 and P3 (its istiod's restart, its P2 poll and baseline
# scrape, its sidecar's drain, P2/P3 timeouts) and its baseline scrape skew; N/A on a row
# with no remote. Older TSVs: 18 columns (no p2_dirty or skew: p2_dirty reads 0, no skew
# gate), 19 (no p1_status or p1_scrape_skew_ms), 21 (no remote_status or
# remote_scrape_skew_ms).
# A status is OK, DRAIN_TIMEOUT (the drain after the iteration timed out; the side was
# otherwise OK: 002 sets it only over OK) or the reason the side is left out:
# TIMEOUT_P1/P2/P3/ALL, RESTART, RESTART_UNKNOWN, NOT_DRAINED (a canary endpoint was
# already healthy on that side's watcher before t0), SCRAPE_INCOMPLETE, or a placeholder's
# SETUP_FAILED / PROBE_FAILED. A DRAIN_TIMEOUT side counts: its values were measured
# before that drain, and the next iteration settles before its baseline (and is
# NOT_DRAINED if the endpoint is still there), so dropping them would only cut the slow
# tail (a slow removal and a slow add share istiod's push path). Every rule below drops
# any status other than these two, so a new status needs no change here.
# shellcheck shell=bash

# shellcheck disable=SC2034  # read by the scripts that source this file
PROP_TSV_HEADER="run_id	mesh_size	iteration	source_ctx	remote_ctx	t0_epoch_ns	p1_ms	p2_ms	p3_ms	status	p1_conv_p50_ms	p1_conv_p99_ms	p1_sample_count	p1_proxy_count	p1_overflow	restarted	p2_dirty	window_ms	scrape_skew_ms	p1_status	p1_scrape_skew_ms	remote_status	remote_scrape_skew_ms"

# prop_placeholder_row <run_id> <mesh_size> <source_ctx> <status>: one row of a cell that
# failed before any measurement (006's SETUP_FAILED / PROBE_FAILED), in PROP_TSV_HEADER's
# schema: the status is the row's, P1's and the remote side's, so every phase counts it in
# n_total and none in n_valid.
# shellcheck disable=SC2329
prop_placeholder_row() {
	printf '%s\t%s\t0\t%s\tN/A\tN/A\tN/A\tN/A\tN/A\t%s\tN/A\tN/A\tN/A\tN/A\tN/A\tunknown\t0\tN/A\tN/A\t%s\tN/A\t%s\tN/A\n' \
		"$1" "$2" "$3" "$4" "$4" "$4"
}

# shellcheck disable=SC2016,SC2034  # awk source, read by the scripts that source this file
PROP_ROW_AWK='
# prop_legacy_reason_(maxskew, p1): the row rule of a TSV from before the remote-side
# verdict (columns 22-23): its status (DRAIN_TIMEOUT counts), restarted, then p1_overflow
# only when p1 is set (the P1 rule, or a row with no remote), then its scrape skew (field
# 19).
function prop_legacy_reason_(maxskew, p1,    st, ov, rs, sk) {
	st = $10
	ov = ($15 == "") ? "0" : $15
	rs = ($16 == "") ? "0" : $16
	sk = (NF >= 19 && $19 ~ /^[0-9]+$/) ? ($19 + 0) : -1
	if (maxskew == "") maxskew = 1000
	if (st != "" && st != "OK" && st != "DRAIN_TIMEOUT") return st
	if (rs == "1" || rs == "unknown") return "restarted=" rs
	if (p1 && ov == "1") return "p1_overflow"
	# A pre-gate TSV row (status OK) whose skew exceeds the current ceiling.
	if (sk >= 0 && sk > maxskew + 0) return "scrape_skew>" maxskew
	return ""
}
function prop_drop_reason(maxskew,    st, sk) {
	if (NF < 23) return prop_legacy_reason_(maxskew, $5 == "N/A")
	st = $22
	# No remote: the row measures P1 only.
	if (st == "N/A") return prop_p1_drop_reason(maxskew)
	if (maxskew == "") maxskew = 1000
	sk = ($23 ~ /^[0-9]+$/) ? ($23 + 0) : -1
	if (st != "OK" && st != "DRAIN_TIMEOUT") return (st == "" ? "remote_status=missing" : st)
	if (sk >= 0 && sk > maxskew + 0) return "remote_scrape_skew>" maxskew
	return ""
}
function prop_p1_drop_reason(maxskew,    st, ov, sk) {
	if (NF < 21) return prop_legacy_reason_(maxskew, 1)
	if (maxskew == "") maxskew = 1000
	st = $20
	ov = ($15 == "") ? "0" : $15
	sk = ($21 ~ /^[0-9]+$/) ? ($21 + 0) : -1
	if (st != "OK" && st != "DRAIN_TIMEOUT") return (st == "" ? "p1_status=missing" : st)
	if (ov == "1") return "p1_overflow"
	if (sk >= 0 && sk > maxskew + 0) return "p1_scrape_skew>" maxskew
	return ""
}
function prop_p1_first(maxskew,    k) {
	# Asking again about the same row gives the same answer.
	if (NR == prop_p1_nr_) return prop_p1_is_first_
	prop_p1_nr_ = NR
	prop_p1_is_first_ = 0
	k = $1 SUBSEP $3
	if (k in prop_p1_seen_) return 0
	if (NF >= 21) {
		# Every row of the iteration carries the same source-side verdict: decide on its first.
		prop_p1_seen_[k] = 1
		prop_p1_is_first_ = (prop_p1_drop_reason(maxskew) == "")
		return prop_p1_is_first_
	}
	if (prop_p1_drop_reason(maxskew) != "") return 0
	prop_p1_seen_[k] = 1
	prop_p1_is_first_ = 1
	return 1
}
function prop_p1_sample(maxskew) { return (prop_p1_first(maxskew) && $7 ~ /^[0-9]+$/) }
function prop_p2_sample(    dirty) {
	dirty = (NF >= 19 && $17 != "") ? $17 : "0"
	return (dirty != "1" && $8 ~ /^[0-9]+$/)
}
function prop_p3_sample() { return ($9 ~ /^[0-9]+$/) }
'
