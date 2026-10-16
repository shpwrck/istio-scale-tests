#!/usr/bin/env bash
# Prometheus metric extraction helpers. Sourced, never executed.
#
# Consumers: churn, churn-dataplane, controlplane
#
# Exposes:
#   extract_counter_sum <metrics_file> <counter_name>       -> sum, or unknown (see below)
#   extract_counter_by_label <metrics_file> <counter_name> <label> <value>
#                                                           -> sum, or unknown (see below)
#   counter_delta <before> <after> [<what>]                 -> after - before, or N/A
#   extract_gauge <metrics_file> <gauge_name>
#   extract_gauge_sum <metrics_file> <gauge_name>
#   delta_histogram_p99 <baseline_file> <final_file> <histogram_name>
#   config_dump_breakdown <dump_file>   (Envoy /config_dump JSON, not /metrics)
#
# All functions take file paths rather than string variables — istiod /metrics
# output is typically 10-50KB and piping through bash variables invites
# quoting problems at scale.
#
# Requires: awk (config_dump_breakdown: jq). Callers must have sourced
# tests/lib/common.sh (for die()).
# shellcheck shell=bash

# Counters (R10): a counter that is not in the scrape is `unknown`, never 0, so a metric
# renamed on another Istio version cannot read as zero pushes. The family counts as
# present when the scrape has a sample of it or its `# TYPE <name>` line; a present
# family with no sample for the label value asked for is a real 0 (istiod registers a
# label series at its first increment). An empty, missing or unreadable file is
# `unknown` too (PL29). Window deltas go through counter_delta, which also knows that
# a series absent at the baseline but present at the end started from 0.

# Sum all instances of a Prometheus counter, or unknown when the scrape has none.
# Usage: extract_counter_sum <metrics_file> <counter_name>
# shellcheck disable=SC2329
extract_counter_sum() {
	local file="$1" name="$2"
	[[ -s "$file" && -r "$file" ]] || { echo unknown; return 0; }
	awk -v name="$name" '
	BEGIN { pat = "^" name "(\\{| )"; tpat = "^# TYPE " name " " }
	$0 ~ tpat { found = 1; next }
	!/^#/ && $0 ~ pat { sum += $NF; found = 1 }
	END { if (found) printf "%.0f\n", sum+0; else print "unknown" }
	' "$file"
}

# Sum a Prometheus counter filtered by a specific label value: 0 when the counter is
# in the scrape but has no series with that value, unknown when it is not there at all.
# Usage: extract_counter_by_label <metrics_file> <counter_name> <label> <value>
# shellcheck disable=SC2329
extract_counter_by_label() {
	local file="$1" name="$2" label="$3" value="$4"
	[[ -s "$file" && -r "$file" ]] || { echo unknown; return 0; }
	awk -v name="$name" -v lbl="$label" -v val="$value" '
	BEGIN { pat = "^" name "\\{"; any = "^" name "(\\{| )"; tpat = "^# TYPE " name " " }
	$0 ~ tpat { found = 1; next }
	!/^#/ && $0 ~ any { found = 1 }
	!/^#/ && $0 ~ pat {
		labels = $0
		sub(/^[^{]*\{/, "", labels); sub(/\}.*$/, "", labels)
		nkv = split(labels, kvs, ",")
		hit = 0
		for (k = 1; k <= nkv; k++) {
			kv = kvs[k]
			gsub(/^[ \t]+|[ \t]+$/, "", kv)
			if (match(kv, "^" lbl "=\"") > 0) {
				v = kv
				sub("^" lbl "=\"", "", v)
				sub(/".*$/, "", v)
				if (v == val) { hit = 1; break }
			}
		}
		if (hit) sum += $NF
	}
	END { if (found) printf "%.0f\n", sum+0; else print "unknown" }
	' "$file"
}

# counter_delta <before> <after> [<what>]: the window delta of a cumulative counter read
# by the extractors above (or fanout_counter_sum): a number, or N/A when it is not a
# measurement. Before unknown with a number after is a 0 baseline (the series was
# registered in the window). N/A, with a warning on stderr naming <what>, when:
#   - both are unknown: the counter is in neither scrape (renamed, or not exported);
#   - after is unknown but before is not: the series vanished (an istiod restart);
#   - after < before: the counter went backwards (a restart the caller did not detect,
#     PL13/PL14).
# Always returns 0, so it is safe in $(...) under set -e.
# shellcheck disable=SC2329
counter_delta() {
	local b="$1" a="$2" what="${3:-counter}" num='^[0-9]+$'
	if [[ "$a" =~ $num && "$b" =~ $num ]]; then
		if (( a >= b )); then
			echo $(( a - b ))
		else
			echo "warning: ${what}: counter went from ${b} to ${a} in the window (a reset, usually an istiod restart); delta N/A" >&2
			echo "N/A"
		fi
	elif [[ "$a" =~ $num ]]; then
		echo "$a"
	elif [[ "$b" =~ $num ]]; then
		echo "warning: ${what}: counter was ${b} at the baseline and is missing from the final scrape (a reset?); delta N/A" >&2
		echo "N/A"
	else
		echo "warning: ${what}: counter is in neither scrape (renamed on this Istio version, or not exported); delta N/A, not 0" >&2
		echo "N/A"
	fi
	return 0
}

# Extract a single Prometheus gauge value (LAST matching line).
# Usage: extract_gauge <metrics_file> <gauge_name>
# Returns the gauge value, or "unknown" if not found.
# NOTE: this returns ONE permutation's value (the last line matched). For a gauge
# emitted with multiple label permutations whose TOTAL is meaningful (e.g.
# pilot_xds{type="ads"} + pilot_xds{type="grpc"}), use extract_gauge_sum instead.
# shellcheck disable=SC2329
extract_gauge() {
	local file="$1" name="$2"
	awk -v name="$name" '
	BEGIN { pat = "^" name "(\\{| )" }
	!/^#/ && $0 ~ pat { val = $NF+0; found = 1 }
	END {
		if (found) printf "%s\n", val
		else        printf "unknown\n"
	}
	' "$file"
}

# Sum a Prometheus gauge across ALL name-anchored label permutations (PL12).
# Usage: extract_gauge_sum <metrics_file> <gauge_name>
# Returns the summed value, or "unknown" if no permutation is present. The name
# is anchored with a following "{" or space so it does not prefix-collide with
# e.g. pilot_xds_pushes / pilot_xds_config_size_bytes.
# shellcheck disable=SC2329
extract_gauge_sum() {
	local file="$1" name="$2"
	awk -v name="$name" '
	BEGIN { pat = "^" name "(\\{| )" }
	!/^#/ && $0 ~ pat { sum += $NF+0; found = 1 }
	END {
		if (found) printf "%s\n", sum
		else        printf "unknown\n"
	}
	' "$file"
}

# Compute p99 from a delta-window histogram (baseline vs final scrape files).
# Outputs bucket upper bound in milliseconds, "N/A" if empty/corrupt, or
# "overflow" if p99 is in the +Inf bucket.
# PL14: negative per-bucket delta -> emit "N/A" (counter reset / undetected restart).
# Usage: delta_histogram_p99 <baseline_file> <final_file> <histogram_name>
# shellcheck disable=SC2329
delta_histogram_p99() {
	local baseline="$1" final="$2" name="$3"
	awk -v name="${name}_bucket" -v q="0.99" '
	function leval(line) {
		s = line; sub(/.*le="/, "", s); sub(/".*/, "", s); return s
	}
	function le_key(le) {
		if (le == "+Inf") return 1e308
		return le + 0
	}
	NR==FNR {
		if ($0 ~ name && /le="/) base[leval($0)] += $NF+0
		next
	}
	$0 ~ name && /le="/ {
		le = leval($0)
		final_v[le] += $NF+0
		if (!(le in seen)) { seen[le] = 1; les[++n] = le }
	}
	END {
		if (n == 0) { print "N/A"; exit }
		for (i = 1; i <= n; i++) sortable[i] = les[i]
		for (i = 2; i <= n; i++) {
			j = i
			while (j > 1 && le_key(sortable[j-1]) > le_key(sortable[j])) {
				t = sortable[j-1]; sortable[j-1] = sortable[j]; sortable[j] = t
				j--
			}
		}
		bad = 0
		for (i = 1; i <= n; i++) {
			le = sortable[i]
			delta = final_v[le] - (le in base ? base[le] : 0)
			if (delta < 0) { bad = 1; break }
			deltas[i] = delta
		}
		if (bad) { print "N/A"; exit }
		total = deltas[n]
		if (total <= 0) { print "N/A"; exit }
		target = total * q
		# Linear interpolation WITHIN the matched bucket (Prometheus
		# histogram_quantile semantics: uniform-within-bucket). deltas[] are
		# cumulative, sortable[] ascending by le; first bucket lower bound = 0.
		# Emitting the bucket upper bound (le) floors the quantile and understates
		# the tail (FINDING #5 — cross-suite convergence-histogram floor).
		prev_le = 0; prev_cum = 0
		for (i = 1; i <= n; i++) {
			if (deltas[i]+0 >= target) {
				if (sortable[i] == "+Inf") { print "overflow"; exit }
				le_val = sortable[i] + 0
				if (deltas[i] > prev_cum)
					val = prev_le + (le_val - prev_le) * (target - prev_cum) / (deltas[i] - prev_cum)
				else
					val = le_val
				printf "%.2f\n", val * 1000
				exit
			}
			prev_le = sortable[i] + 0
			prev_cum = deltas[i] + 0
		}
		print "N/A"
	}' "$baseline" "$final"
}

# --- VirtualService/DestinationRule load axis (controlplane) ---

# Per-proxy CDS/RDS breakdown of one Envoy config dump (pilot-agent request GET
# /config_dump), in one jq pass. Prints
#   clusters=<n> cds_bytes=<n> rds_bytes=<n>
# clusters = dynamic_active_clusters (istiod-pushed CDS clusters; one per DR subset
# per port on top of the plain service cluster); cds_bytes / rds_bytes = UTF-8 length
# of the compact JSON of the ClustersConfigDump / RoutesConfigDump section (a size
# proxy for that config, not the xDS wire size). rds_bytes is `unknown` when the dump
# has no RoutesConfigDump. Prints `unknown` for an empty or non-JSON file or one with
# no ClustersConfigDump, so a failed or truncated dump is never a zero.
# Usage: config_dump_breakdown <dump_file>
# shellcheck disable=SC2329
config_dump_breakdown() {
	local file="$1" out=""
	# jq prints nothing for empty input (no error), so guard it explicitly.
	[[ -s "$file" ]] || { echo "unknown"; return 0; }
	out="$(jq -r '
		[(.configs? // [])[]? | objects] as $c
		| ([$c[] | select((."@type" // "") | endswith(".ClustersConfigDump"))] | first) as $cl
		| ([$c[] | select((."@type" // "") | endswith(".RoutesConfigDump"))] | first) as $rt
		| if $cl == null then "unknown"
		  else "clusters=\(($cl.dynamic_active_clusters // []) | length) cds_bytes=\($cl | tojson | utf8bytelength) rds_bytes=\(if $rt == null then "unknown" else ($rt | tojson | utf8bytelength) end)"
		  end' "$file" 2>/dev/null)" || out=""
	[[ "$out" == clusters=* ]] || out="unknown"
	echo "$out"
}
