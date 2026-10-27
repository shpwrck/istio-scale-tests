#!/usr/bin/env bash
# Writes a redacted copy of a results dir, or of given result files, for pasting into
# docs/campaigns (AGENTS.md: no identifying data in public artifacts).
#
# Not numbered: AGENTS.md "Numbered scripts" orders a suite's steps (tests/<suite>/NNN-*.sh).
# tests/lib/ holds the shared libraries and standalone tools that no suite step runs in
# order (verify.sh, the lint-*.sh helpers, this file), so they keep plain names.
#
# What it replaces, in this order, on every line of a .tsv, .md, .txt, .csv or .json file
# (the scale envelope md and sweep-outcome.txt included):
#   1. kube context names -> <mesh-a-ctx>, <mesh-b-ctx>, ... (<hub-a-ctx> for the hub),
#      one mapping for the whole run, printed on stderr only, never into the copy.
#      Names come from the files' own metadata: the per-member keys
#      (ISTIO_VERSION_BY_CONTEXT and every *_BY_CONTEXT key, ISTIO_ACTIVE_REVISIONS,
#      ISTIO_GENERATIONS, older TSVs' ISTIO_PROXY_VERSIONS and ISTIO_NOTREADY_AT_*,
#      KUBE_VERSIONS, ISTIOD_REPLICAS and controlplane's WINDOW_ROWS lines (<ctx>=<rows>[/<replicas>],
#      the suffix kept) and ISTIOD_NOT_READY[_AT_END] lines (<ctx>=<pod>) as ctx=value
#      lists), the member lists (CONTEXTS, REMOTE_CONTEXTS,
#      REMOTES, any *_CONTEXTS key), SOURCE_CTX, WORKLOAD_CONTEXT and any other *_CTX /
#      *_CONTEXT key, HUB_CONTEXT (the hub), and the "# Contexts:" / "# Source: ...
#      Remotes:" lines, and the "by member <ctx>=<value>,..." lists of the scale envelope
#      and the tuning report; plus every --context / --hub-context the operator names. A
#      name matches only where no letter, digit or _ touches it on either side. The
#      file-name form of a name (ctx_file_safe in tests/lib/common.sh: other bytes as _,
#      as the tuning state files and tests/lib/istiod-diag.sh write it; istiod-diag
#      folders cut it to CTX_FILE_NAME_MAX chars) maps to the same placeholder.
#      When no member is learned and none is given, it refuses the whole run (exit 1,
#      nothing written): a lone report can name members in prose only. Metadata that
#      names members by placeholder only (<mesh-a-ctx>: a copy redacted already) passes;
#      --no-contexts runs anyway, for files that name no kube context (nothing checks
#      that: the mapping says so, and a human reads the copy for member names).
#   2. URLs -> <api-host> (in-cluster ones, *.svc[.cluster.local] and localhost, stay).
#   3. 12-digit AWS account ids in ARNs -> <account>; emails -> <email>.
#   4. API hosts (api.* / api-int.*) -> <api-host>; cluster host names (*.openshiftapps.com,
#      *.openshift.com, *.amazonaws.com, *.compute.internal, *.ec2.internal, *.azmk8s.io,
#      *.aroapp.io, *.appdomain.cloud, *.apps.<cluster>.<domain> routes, ip-a-b-c-d node
#      names) -> <host>.
#   5. AWS resource ids (vpc-, subnet-, sg-, i-, eni-, vol-, igw-, nat-, rtb- and 8 or 17
#      lowercase hex digits, no letter, digit, _ or - before it and no letter, digit or _
#      after it) -> <vpc-id>, <subnet-id>, <sg-id>, <instance-id>, <eni-id>, <volume-id>,
#      <igw-id>, <nat-id>, <rtb-id>.
#   6. IPv4 and IPv6 addresses -> <ip>; home dirs /home/<name> and /Users/<name> -> <home>.
# A TSV's header line is redacted like any other (its column names, read first, pick the
# context columns the final scan checks).
#
# File and dir names: a mapped name in a copied file's path (below the given dir; a given
# file's own name) is renamed the same way, without the angle brackets (mesh-a-ctx: no <
# or > in a file name), and each rename is listed on stderr only. --in-place renames the
# files and dirs below a given dir (an emptied old dir is removed) and a given file itself;
# it refuses a given dir whose own name holds a mapped name (rename it, or use --out).
#
# Final scan, per file, on the redacted text and the renamed path: no mapped name is left;
# every value of a TSV column named context, ctx, *_ctx or *_context (and of such a JSON
# string field) is a placeholder, none/N/A/unknown/- or an UPPER_SNAKE status a placeholder
# row writes there (PROBE_FAILED; controlplane's INTERRUPTED too); a .json file still
# parses (jq). A file that fails is never written (nor replaced or renamed with
# --in-place); the run names it and exits 1.
# Columns are checked, not learned from: a member the metadata never names is a context
# the script was not told about, so pass it with --context NAME.
#
# Files it skips (named on stderr, never copied): other file types, dot files (an older
# sweep's .sweep.lock among them: a PID), the raw istiod-diag evidence folders
# (istiod-diag-<RUN_ID>/NNN-*/), which keep host and node names on purpose and must never
# be pasted, and a tuning sweep's raw copies of the Istio CR (istio-spec/*.json,
# state/istio-before-*.json), which hold the cluster's own name. With --in-place they stay as they are,
# and a skipped path that still holds a mapped name is listed on stderr.
#
# What it does not catch (a human reads the copy, names included, before committing it):
# a context, cluster or node name that no metadata key names and no --context gives (in
# prose, a log line or a file name); host names and domains outside the suffixes above;
# AWS ids of other kinds or lengths (ami-, snap-, vpce-, ...), the resource part of an ARN
# (only its account id is masked), region and zone names; user names outside /home and
# /Users; tokens, passwords and other secrets an error message or log quotes; and the
# files it skips.
#
# Usage: tests/lib/redact-results.sh (--out DIR | --in-place | --dry-run) [options] PATH...
# Environment: TMPDIR (where its work dir goes; default /tmp).
# Needs bash 4.3+, awk, sed, find, sort, jq (for .json files). Never touches a cluster.
# ci-dry-run-skip: reads result files only, never a cluster; tests/lib/test/redact-results.bats runs it
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${ROOT}/tests/lib/common.sh"

usage() {
	cat <<'EOF'
Usage: tests/lib/redact-results.sh (--out DIR | --in-place | --dry-run) [options] PATH...

Writes a redacted copy of result files (a results dir, a sweep-<RUN_ID> dir, or single
files) for pasting into docs/campaigns. Kube contexts become <mesh-a-ctx>, <mesh-b-ctx>,
... (the hub <hub-a-ctx>); URLs and API hosts <api-host>; IPs <ip>; emails <email>; AWS
account ids in ARNs <account>; AWS resource ids (vpc-, subnet-, sg-, i-, eni-, vol-,
igw-, nat-, rtb- with 8 or 17 hex digits) <vpc-id>, <subnet-id>, ...; cluster host names
<host>; home dirs (/home/<name> and /Users/<name>) <home>. A file or dir name that
holds a context is renamed the same way, without the angle brackets (mesh-a-ctx). The
context mapping and the renames go to stderr only. Handles .tsv .md .txt .csv .json;
skips other files, dot files (an older sweep's .sweep.lock), the raw istiod-diag
evidence folders and a tuning sweep's raw copies of the Istio CR (istio-spec/,
state/istio-before-*.json), each named on stderr, never copied.

Modes (--out or --in-place; --dry-run alone or with either):
  --out DIR         write the copy under DIR (new or empty, outside every PATH): a dir
                    PATH lands at DIR/<its name>/..., a file PATH at DIR/<its name>,
                    renamed where a name holds a context
  --in-place        rewrite the files where they are (only a file that passes the scan),
                    and rename the files and dirs below a dir PATH, and a file PATH, whose
                    names hold a context (a dir PATH whose own name holds one is refused)
  --dry-run         write nothing; list per file what would change, then run the scan.
                    With --out or --in-place it checks that mode's preconditions (an
                    empty --out DIR, --in-place renames) and still writes nothing.

Options:
  --context NAME    a kube context to map, besides the ones the files' metadata names
                    (repeatable; NAME may be a comma list, no spaces). Named ones take the
                    first letters, in the order given; the rest follow in sorted order.
  --hub-context NAME
                    the ACM hub's context (repeatable, comma list): maps to <hub-a-ctx>, ...
  --no-contexts     run even though no member was learned from the files' metadata or
                    given with --context, for files that name no kube context; nothing
                    checks that, so read the copy for member names
  -h, --help        this help

Environment:
  TMPDIR            where the work dir (removed at exit) goes; default /tmp

Exit 1, before anything is written, when no member context was learned from the files'
metadata and none was given (a lone report, such as the scale envelope or a summary, can
name members in prose only): pass --context NAME for each member, or --no-contexts when
the files name none. Metadata that names members by placeholder only (a copy redacted
already) passes. Exit 1 when a file fails the final scan (a mapped name left in its
text or path, a context column or field holding a name it was not told about, or a .json
file that no longer parses): that file is not written, and stderr names it. Also exit 1,
before anything is written, when two files would land at one path once renamed, or
(--in-place) a dir PATH's own name holds a context or a rename would meet a path that
exists. Redact a whole results dir rather than a lone report: the TSV preambles name every
member.

What it does not catch, so read the copy, file names included, before you commit it: a
context, cluster or node name that no metadata key names and no --context gives (in
prose, a log line or a file name); host names and domains outside the suffixes it knows
(api.*, *.apps.*, *.openshiftapps.com, *.amazonaws.com, ...); other AWS ids (ami-, snap-,
vpce-, other lengths), the resource part of an ARN, region and zone names; user names
outside /home and /Users; tokens, passwords or other secrets a log or error quotes; and
the files it skips.

Examples:
  tests/lib/redact-results.sh --dry-run tests/controlplane/results/sweep-<RUN_ID>
  tests/lib/redact-results.sh --out /tmp/redacted tests/controlplane/results/sweep-<RUN_ID>
  tests/lib/redact-results.sh --out /tmp/redacted --context <mesh-a-ctx>,<mesh-b-ctx> \
      --hub-context <hub-ctx> report.md
EOF
}

OUT_DIR=""
IN_PLACE=0
DRY_RUN=0
NO_CONTEXTS=0
declare -a NAMED_CTX=() HUB_CTX=() INPUTS=() _parts=()

while (($#)); do
	case "$1" in
	--out)
		[[ $# -ge 2 && -n "$2" ]] || die "--out needs a directory"
		OUT_DIR="$2"; shift 2 ;;
	--in-place) IN_PLACE=1; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	--context|--hub-context)
		[[ $# -ge 2 && -n "$2" ]] || die "$1 needs a context name"
		split_csv "$2" _parts
		((${#_parts[@]} > 0)) || die "$1 needs a context name"
		for _p in "${_parts[@]}"; do
			[[ "$_p" != *[[:space:]]* ]] || die "$1 '${_p}': a context name has no spaces"
			if [[ "$1" == --context ]]; then NAMED_CTX+=("$_p"); else HUB_CTX+=("$_p"); fi
		done
		shift 2 ;;
	--no-contexts) NO_CONTEXTS=1; shift ;;
	-h|--help) usage; exit 0 ;;
	--) shift; INPUTS+=("$@"); break ;;
	-*) die "unknown option: $1 (see --help)" ;;
	*) INPUTS+=("$1"); shift ;;
	esac
done

((${#INPUTS[@]} > 0)) || die "name at least one results dir or file (see --help)"
if [[ -n "$OUT_DIR" && "$IN_PLACE" == 1 ]]; then die "--out and --in-place exclude each other"; fi
if [[ -z "$OUT_DIR" && "$IN_PLACE" == 0 && "$DRY_RUN" == 0 ]]; then
	die "say where the redacted files go: --out DIR, or --in-place; --dry-run only lists the changes"
fi

# abs_path <path>: absolute, from its nearest existing dir (symlinks resolved there); the
# path itself need not exist.
abs_path() {
	local p="$1" tail=""
	while [[ ! -d "$p" ]]; do
		tail="/$(basename "$p")${tail}"
		p="$(dirname "$p")"
	done
	printf '%s%s\n' "$(cd "$p" && pwd -P)" "$tail"
}

# within <child> <parent>: true when child is parent or below it.
within() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }

for _in in "${INPUTS[@]}"; do
	[[ -e "$_in" ]] || die "no such file or directory: ${_in}"
	[[ -f "$_in" || -d "$_in" ]] || die "not a regular file or directory: ${_in}"
done

OUT_ABS=""
if [[ -n "$OUT_DIR" ]]; then
	OUT_ABS="$(abs_path "$OUT_DIR")"
	[[ ! -e "$OUT_DIR" || -d "$OUT_DIR" ]] || die "--out ${OUT_DIR} exists and is not a directory"
	if [[ -d "$OUT_DIR" ]] && [[ -n "$(find "$OUT_DIR" -mindepth 1 -print 2>/dev/null | head -1)" ]]; then
		die "--out ${OUT_DIR} is not empty: use a new or empty dir, so no older unredacted file sits next to the copy"
	fi
	for _in in "${INPUTS[@]}"; do
		_ia="$(abs_path "$_in")"
		if within "$OUT_ABS" "$_ia" || within "$_ia" "$OUT_ABS"; then
			die "--out ${OUT_DIR} and ${_in} overlap: write the copy outside the results"
		fi
	done
fi

if ! WORK="$(mktemp -d "${TMPDIR:-/tmp}/redact-results.XXXXXX")"; then die "cannot create a temp dir"; fi
# shellcheck disable=SC2329
_rr_cleanup() { rm -rf "$WORK"; }
trap _rr_cleanup EXIT

# --- 1. The files: (source, copy-relative path) per handled file; the rest is skipped. ---
# src \t rel \t kind (tsv|json|text) \t anchor \t sub: rel is the path in the copy; with
# --in-place, the file is anchor/sub, and sub is the part of its path it may rename.
LIST="${WORK}/list.tsv"
: >"$LIST"
SKIPPED=()
declare -A REL_SEEN=()

# add_file <src> <rel> <anchor> <sub>
add_file() {
	local src="$1" rel="$2" anchor="$3" sub="$4" base kind
	base="${src##*/}"
	if [[ "$src" == *$'\t'* || "$src" == *$'\n'* ]]; then
		SKIPPED+=("${src} (a tab or newline in the name)"); return 0
	fi
	if [[ "$base" == .* ]]; then SKIPPED+=("${src} (dot file)"); return 0; fi
	if [[ "/${rel}" =~ /istiod-diag-[^/]+/[0-9][0-9][0-9]-[^/]+/ ]]; then
		SKIPPED+=("${src} (raw istiod-diag evidence: keeps host and node names, never paste it)"); return 0
	fi
	# A tuning sweep's copies of the Istio CR: its spec at the start and the end
	# (istio-spec/) and the whole CR a pass's apply saved (state/istio-before-<ctx>.json).
	# They hold the cluster's own name (multiCluster.clusterName, network), which no
	# metadata key names.
	if [[ "/${rel}" =~ /istio-spec/[^/]+$ || "$base" == istio-before-*.json ]]; then
		SKIPPED+=("${src} (a raw copy of an Istio CR: keeps the cluster and network names, never paste it)"); return 0
	fi
	case "$base" in
	*.tsv) kind=tsv ;;
	*.json) kind=json ;;
	*.md | *.txt | *.csv) kind=text ;;
	*) SKIPPED+=("${src} (not a .tsv/.md/.txt/.csv/.json file)"); return 0 ;;
	esac
	[[ -r "$src" ]] || die "cannot read ${src}"
	[[ -z "${REL_SEEN[$rel]+x}" ]] || die "two inputs land at the same place in the copy (${rel}): redact them in separate runs"
	REL_SEEN[$rel]=1
	printf '%s\t%s\t%s\t%s\t%s\n' "$src" "$rel" "$kind" "$anchor" "$sub" >>"$LIST"
}

for _in in "${INPUTS[@]}"; do
	if [[ -f "$_in" ]]; then
		add_file "$_in" "$(basename "$_in")" "$(dirname "$_in")" "$(basename "$_in")"
		continue
	fi
	_top="$(basename "$(abs_path "$_in")")"
	_in_trim="${_in%/}"
	[[ -n "$_in_trim" ]] || _in_trim="/"
	while IFS= read -r _f; do
		_rel="${_f#"$_in_trim"/}"
		add_file "$_f" "${_top}/${_rel}" "$_in_trim" "$_rel"
	done < <(find -H "$_in_trim" -type f -print 2>/dev/null | LC_ALL=C sort)
done

N_FILES="$(awk 'END { print NR }' "$LIST")"
if ((${#SKIPPED[@]} > 0)); then
	echo "redact-results: skipped ${#SKIPPED[@]} file(s), not copied:" >&2
	printf '  %s\n' "${SKIPPED[@]}" >&2
fi
((N_FILES > 0)) || die "no .tsv/.md/.txt/.csv/.json file under the given paths"
if grep -q $'\tjson$' "$LIST" && ! command -v jq >/dev/null 2>&1; then
	die "jq is required to check that the redacted .json files still parse"
fi

# --- 2. The awk program: MODE=learn prints the names the metadata holds (M<TAB>name, ---
# H<TAB>name for the hub); MODE=redact writes each file's redacted copy and prints
# F<TAB>index<TAB>changed_lines<TAB>kinds and I<TAB>index<TAB>line<TAB>reason lines;
# MODE=paths prints each listed path renamed (P lines) and N lines for its final scan.
# shellcheck disable=SC2016
REDACT_AWK='
function lower(s) { return tolower(s) }
# keyclass <lowercased key> -> kv (ctx=value list), list (member list), single, hub or "".
function keyclass(k) {
	if (k ~ /_by_context$/) return "kv"
	if (k == "istio_active_revisions" || k == "istio_generations" || k == "kube_versions" \
		|| k == "istiod_replicas" || k == "window_rows" || k ~ /^istiod_not_ready(_at_end)?$/) return "kv"
	# Keys of older TSVs that no run writes now: recorded results still carry them.
	if (k == "istio_proxy_versions" || k ~ /^istio_notready_at_(start|end)$/) return "kv"
	if (k == "contexts" || k == "remotes" || k ~ /_contexts$/) return "list"
	if (k == "hub_context" || k == "hub_ctx") return "hub"
	if (k == "context" || k == "ctx" || k ~ /_ctx$/ || k ~ /_context$/) return "single"
	return ""
}
# neutral <token>: no context name: a word a metadata value or a context column holds in
# its place, a placeholder, or an UPPER_SNAKE status a placeholder row writes there
# (PROBE_FAILED), and INTERRUPTED, the one status of controlplane 003 (CELL_STATUS_RE)
# without an underscore (a cell a signal cut short).
function neutral(t,    l) {
	l = lower(t)
	return (t == "" || l == "none" || l == "unknown" || l == "unchecked" || l == "n/a" || l == "na" \
		|| l == "-" || l == "mixed" || l == "mixed:" || l == "all" || l == "null" || l == "true" || l == "false" \
		|| t ~ /^<[a-z][a-z0-9-]*>$/ || t ~ /^[A-Z][A-Z0-9]*_[A-Z0-9_]*$/ || t == "INTERRUPTED")
}
function isname(t) {
	if (neutral(t)) return 0
	if (t ~ /:$/ || t ~ /^[0-9.]+$/) return 0
	return (t ~ /^[A-Za-z0-9][A-Za-z0-9_.:\/@+-]*$/)
}
# emit_names <value> <class>: each name in a metadata value (a pooled value reads
# mixed:a,b or mixed:a | b). A member placeholder there (<mesh-a-ctx>) says the files
# name their members but are redacted already: recorded as P.
function emit_names(v, cls,    n, T, i, t, p) {
	gsub(/\\/, " ", v)
	n = split(v, T, /[ ,|]+/)
	for (i = 1; i <= n; i++) {
		t = T[i]; sub(/^mixed:/, "", t)
		if (cls == "kv") { p = index(t, "="); if (!p) continue; t = substr(t, 1, p - 1) }
		if (isname(t)) LEARN[(cls == "hub" ? "H" : "M") SUBSEP t] = 1
		else if (cls != "hub" && t ~ /^<mesh-[a-z]+-ctx>$/) REDACTED_SEEN = 1
	}
}
# cut_value <text after the separator> <mode>: the value, up to its end. A quoted value
# ends at its quote. Mode word (a CSV or ctx=value list, one context): the first word,
# " | " of a pooled value kept. Mode words (a space-separated member list): up to two
# spaces, " |", " (" or " #".
function cut_value(v, mode,    q, p) {
	sub(/^[ \t]+/, "", v)
	q = substr(v, 1, 1)
	if (q == "\"" || q == "`") {
		v = substr(v, 2); p = index(v, q); if (p) v = substr(v, 1, p - 1)
		return v
	}
	p = index(v, "\t"); if (p) v = substr(v, 1, p - 1)
	if (mode == "word") {
		gsub(/\\[|]/, "|", v); gsub(/ [|] /, "|", v)
		sub(/[ ].*$/, "", v)
		return v
	}
	p = index(v, "  "); if (p) v = substr(v, 1, p - 1)
	p = index(v, " |"); if (p) v = substr(v, 1, p - 1)
	p = index(v, " ("); if (p) v = substr(v, 1, p - 1)
	p = index(v, " #"); if (p) v = substr(v, 1, p - 1)
	return v
}
# learn <line>: record the context names this line names as metadata.
function learn(L,    s, k, lk, cls, pre, post, rest, sep, off, m, key, quoted, v, t) {
	# Free-form lines: "# Contexts: a b  Mesh size: 3", "- Contexts: a,b",
	# "# Source: a  Remotes: b c  Mesh size: 3", "Members: a b (workload: a)".
	if (match(L, /^[#>* \t-]*(\[[0-9]+\][ \t]*)?(Contexts|Members|Remotes):[ \t]+/)) {
		emit_names(cut_value(substr(L, RSTART + RLENGTH), "words"), "list")
	}
	if (L ~ /^[#>* \t-]*Source:[ \t]+[^ \t]/ && (L ~ /Remotes:/ || L ~ /\(pod:/)) {
		t = L; sub(/^[#>* \t-]*Source:[ \t]+/, "", t); sub(/[ \t|(].*$/, "", t)
		emit_names(t, "single")
		if (match(L, /[ \t|]Remotes:[ \t]+/)) emit_names(cut_value(substr(L, RSTART + RLENGTH), "words"), "list")
	}
	# "by member a=v1.30.5,b=v1.30.5" (ISTIO_VERSION_BY_CONTEXT on the Istio line of the
	# scale envelope and of the tuning report): a ctx=value list in prose.
	s = L
	while (match(s, /(^|[^A-Za-z0-9_])by member[ \t]+/)) {
		s = substr(s, RSTART + RLENGTH)
		emit_names(cut_value(s, "word"), "kv")
	}
	# KEY=value, KEY: value, "key": "value", | KEY | `value` |
	s = L; off = 0
	while (match(s, /[A-Za-z_][A-Za-z0-9_]*["`*]*[ \t]*[=:|]/)) {
		m = substr(s, RSTART, RLENGTH)
		key = m; sub(/["`* \t=:|]+$/, "", key)
		sep = substr(m, RLENGTH, 1)
		pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : (off > 0 ? substr(L, off, 1) : "")
		rest = substr(s, RSTART + RLENGTH)
		off += RSTART + RLENGTH - 1
		s = rest
		if (pre ~ /[A-Za-z0-9_.\/-]/) continue
		# A key in a code span followed by a colon is prose that names the key (a report
		# glossary: "`REMOTES`: iterations for the P1 phases"), not its value.
		if (pre == "`" && sep == ":") continue
		lk = lower(key)
		cls = keyclass(lk)
		if (cls == "") continue
		quoted = (pre == "\"" && substr(m, length(key) + 1, 1) == "\"")
		if (quoted) {
			# A JSON field: only metadata lists teach names; row fields are checked instead.
			if (sep != ":" || (cls != "kv" && cls != "list" && cls != "hub")) continue
		} else if (key == toupper(key)) {
			# KEY=, KEY:, | KEY | (any class)
		} else {
			# lower-case metadata (text and md formats): lists only, with = or :
			if (sep == "|" || index(lk, "_") == 0 || (cls != "kv" && cls != "list" && cls != "hub")) continue
		}
		v = cut_value(rest, (lk == "remotes") ? "words" : "word")
		emit_names(v, cls)
	}
}
# header <raw header line> <kind>: the first line of a file that is not a # comment, when
# it is a tab-separated header (always in a .tsv): its context columns (single or hub
# class, CCOL: checked by the final scan, never learned from).
function header(L, kind,    n, F, i, c, cls) {
	HSEEN = 1
	if (kind != "tsv" && !index(L, "\t")) return 0
	HDR = L
	n = split(L, F, "\t")
	for (i = 1; i <= n; i++) {
		c = lower(F[i]); cls = keyclass(c)
		if (kind == "tsv" && (cls == "single" || cls == "hub")) { CCOL[i] = F[i]; NC++ }
	}
	return 1
}
# findb <line> <name> <from>: first position >= from where name stands alone, else 0.
function findb(L, n, from,    t, p, a, b) {
	while (1) {
		t = substr(L, from); p = index(t, n); if (!p) return 0
		p = from + p - 1
		a = (p > 1) ? substr(L, p - 1, 1) : ""
		b = substr(L, p + length(n), 1)
		if (a !~ /[A-Za-z0-9_]/ && b !~ /[A-Za-z0-9_]/) return p
		from = p + 1
	}
}
# repctx <line>: every mapped name, leftmost first (longest at a tie); a placeholder is
# never scanned again.
function repctx(L,    c, out, best, bl, bi, i, p) {
	c = 1; out = ""
	while (1) {
		best = 0; bl = 0; bi = 0
		for (i = 1; i <= NN; i++) {
			p = findb(L, NAME[i], c)
			if (p > 0 && (best == 0 || p < best || (p == best && length(NAME[i]) > bl))) { best = p; bl = length(NAME[i]); bi = i }
		}
		if (!best) return out substr(L, c)
		out = out substr(L, c, best - c) PH[bi]; c = best + bl; K["context"]++
	}
}
function okb(chk, pre, post, post2) {
	if (chk == "alnum") return (pre !~ /[A-Za-z0-9_]/)
	if (chk == "ip4") return (pre !~ /[0-9.]/ && post !~ /[0-9]/ && !(post == "." && post2 ~ /[0-9]/))
	return 1
}
# rep <s> <regex> <placeholder> <kind> <check>: replace each match the check accepts.
function rep(s, re, ph, kind, chk,    out, pre, post, post2) {
	out = ""
	while (match(s, re)) {
		pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : substr(out, length(out), 1)
		post = substr(s, RSTART + RLENGTH, 1); post2 = substr(s, RSTART + RLENGTH + 1, 1)
		if (!okb(chk, pre, post, post2)) { out = out substr(s, 1, RSTART); s = substr(s, RSTART + 1); continue }
		out = out substr(s, 1, RSTART - 1) ph; s = substr(s, RSTART + RLENGTH); K[kind]++
	}
	return out s
}
# repurl <s>: a URL becomes <api-host> unless its host is in-cluster or local.
function repurl(s,    out, u, h, p) {
	out = ""
	while (match(s, RE_URL)) {
		u = substr(s, RSTART, RLENGTH)
		h = u; sub(/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, "", h); sub(/[\/?#].*$/, "", h); sub(/^.*@/, "", h)
		if (substr(h, 1, 1) == "[") { p = index(h, "]"); if (p) h = substr(h, 1, p) } else sub(/:.*$/, "", h)
		h = lower(h)
		if (h == "localhost" || h == "127.0.0.1" || h == "[::1]" || h ~ /\.svc$/ || h ~ /\.cluster\.local$/) {
			out = out substr(s, 1, RSTART + RLENGTH - 1)
		} else {
			out = out substr(s, 1, RSTART - 1) "<api-host>"; K["url"]++
		}
		s = substr(s, RSTART + RLENGTH)
	}
	return out s
}
# reparn <s>: the 12-digit account id of an ARN becomes <account>.
function reparn(s,    out) {
	out = ""
	while (match(s, RE_ARN)) {
		out = out substr(s, 1, RSTART + RLENGTH - 14) "<account>:"; s = substr(s, RSTART + RLENGTH); K["account"]++
	}
	return out s
}
# repaws <s>: an AWS resource id (vpc-, subnet-, sg-, i-, eni-, vol-, igw-, nat-, rtb- and
# 8 or 17 lowercase hex digits) becomes <vpc-id>, <instance-id>, ... where no letter,
# digit, _ or - comes before it and no letter, digit or _ after it (so a 12-digit suffix,
# my-sg-0123abcd or sg-0123abcdx stays). RE_AWS matches the 8 digits; 9 more extend it.
function repaws(s,    out, pre, post, n, p) {
	out = ""
	while (match(s, RE_AWS)) {
		n = RLENGTH
		if (substr(s, RSTART + n, 9) ~ RE_HEX9) n += 9
		pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : substr(out, length(out), 1)
		post = substr(s, RSTART + n, 1)
		if (pre ~ /[A-Za-z0-9_-]/ || post ~ /[A-Za-z0-9_]/) { out = out substr(s, 1, RSTART); s = substr(s, RSTART + 1); continue }
		p = index(substr(s, RSTART), "-")
		out = out substr(s, 1, RSTART - 1) "<" AWSPH[substr(s, RSTART, p - 1)] ">"; s = substr(s, RSTART + n); K["aws-id"]++
	}
	return out s
}
function redact(L,    s) {
	s = (NN > 0) ? repctx(L) : L
	if (index(s, "://")) s = repurl(s)
	if (index(s, "arn:aws")) s = reparn(s)
	if (index(s, "@")) s = rep(s, RE_EMAIL, "<email>", "email", "")
	if (index(s, ".")) {
		if (index(s, "api")) s = rep(s, RE_API, "<api-host>", "api-host", "")
		s = rep(s, RE_HOSTSFX, "<host>", "host", "")
		if (index(s, "apps.")) s = rep(s, RE_APPS, "<host>", "host", "")
	}
	if (index(s, "ip-")) s = rep(s, RE_NODE, "<host>", "host", "")
	if (index(s, "-")) s = repaws(s)
	if (index(s, ":")) {
		if (index(s, "[")) s = rep(s, RE_IP6B, "<ip>", "ip", "")
		if (index(s, "::")) s = rep(s, RE_IP6C, "<ip>", "ip", "alnum")
		s = rep(s, RE_IP6F, "<ip>", "ip", "alnum")
	}
	if (index(s, ".")) s = rep(s, RE_IP4, "<ip>", "ip", "ip4")
	if (index(s, "/home/") || index(s, "/Users/")) s = rep(s, RE_HOME, "<home>", "home", "")
	return s
}
# valok <value>: a context column or field value that names no unmapped context.
function valok(v,    n, T, i, t) {
	gsub(/\\/, " ", v)
	n = split(v, T, /[ ,|]+/)
	for (i = 1; i <= n; i++) { t = T[i]; sub(/^mixed:/, "", t); if (!neutral(t)) return 0 }
	return 1
}
function issue(line, why) { printf "I\t%d\t%d\t%s\n", FI, line, why }
# scan <redacted line> <line number> <kind>: the final checks on one line.
function scan(s, ln, kind, ishdr,    t, i, n, F, v, k, rest) {
	t = s; gsub(/<[a-z][a-z0-9-]*>/, " ", t)
	for (i = 1; i <= NN; i++) if (findb(t, NAME[i], 1)) { issue(ln, "the mapped name " NAME[i] " is still there"); break }
	delete LEARN
	learn(s)
	for (k in LEARN) { split(k, F, SUBSEP); issue(ln, "metadata names " F[2] ", a context it was not told about (pass --context " F[2] ")") }
	if (kind == "tsv" && NC > 0 && !ishdr && substr(s, 1, 1) != "#") {
		n = split(s, F, "\t")
		for (i = 1; i <= n; i++) if ((i in CCOL) && !valok(F[i])) issue(ln, "column " CCOL[i] " holds " F[i] ", a context it was not told about (pass --context " F[i] ")")
	}
	if (kind == "json") {
		rest = s
		while (match(rest, /"[A-Za-z_][A-Za-z0-9_]*"[ \t]*:[ \t]*"[^"]*"/)) {
			v = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
			k = v; sub(/^"/, "", k); sub(/".*$/, "", k)
			sub(/^"[^"]*"[ \t]*:[ \t]*"/, "", v); sub(/"$/, "", v)
			if (keyclass(lower(k)) == "single" && !valok(v)) issue(ln, "field " k " holds " v ", a context it was not told about (pass --context " v ")")
		}
	}
}
BEGIN {
	SQ = sprintf("%c", 39)
	o = "[0-9][0-9]?[0-9]?"
	RE_IP4 = o "\\." o "\\." o "\\." o
	d12 = ""; for (i = 0; i < 12; i++) d12 = d12 "[0-9]"
	RE_ARN = "arn:aws[A-Za-z-]*:[A-Za-z0-9-]*:[A-Za-z0-9-]*:" d12 ":"
	RE_URL = "[A-Za-z][A-Za-z0-9+.-]*://[^ \t\"" SQ "`|<>(),{}\\\\]+"
	RE_EMAIL = "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z][A-Za-z]+"
	RE_API = "api(-int)?\\.[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[a-z][a-z]+(:[0-9]+)?"
	RE_HOSTSFX = "([A-Za-z0-9-]+\\.)+(openshiftapps\\.com|openshift\\.com|amazonaws\\.com|compute\\.internal|ec2\\.internal|azmk8s\\.io|aroapp\\.io|appdomain\\.cloud)"
	RE_APPS = "([A-Za-z0-9-]+\\.)*apps(\\.[A-Za-z0-9-]+)+\\.[a-z][a-z]+"
	RE_NODE = "ip-" o "-" o "-" o "-" o "(\\.[A-Za-z0-9-]+)*"
	RE_IP6B = "\\[[0-9A-Fa-f.]*:[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*(%[0-9A-Za-z_.-]+)?\\]"
	RE_IP6C = "[0-9A-Fa-f:]*([0-9A-Fa-f]::|::[0-9A-Fa-f])([0-9A-Fa-f:]*[0-9A-Fa-f])?(%[0-9A-Za-z_.-]+)?"
	RE_IP6F = "[0-9A-Fa-f]+:[0-9A-Fa-f]+:[0-9A-Fa-f]+(:[0-9A-Fa-f]+)+"
	h8 = ""; for (i = 0; i < 8; i++) h8 = h8 "[0-9a-f]"
	RE_HEX9 = "^[0-9a-f]"; for (i = 0; i < 8; i++) RE_HEX9 = RE_HEX9 "[0-9a-f]"
	RE_HEX9 = RE_HEX9 "$"
	RE_AWS = "(vpc|subnet|sg|i|eni|vol|igw|nat|rtb)-" h8
	split("vpc vpc-id subnet subnet-id sg sg-id i instance-id eni eni-id vol volume-id igw igw-id nat nat-id rtb rtb-id", A, " ")
	for (i = 1; i < 18; i += 2) AWSPH[A[i]] = A[i + 1]
	RE_HOME = "/(home|Users)/[A-Za-z0-9._-]+"
	NN = 0
	if (MODE == "redact" || MODE == "paths") {
		while ((getline ln < MAPF) > 0) {
			split(ln, A, "\t"); NN++; NAME[NN] = A[1]; PH[NN] = A[2]
			# A file name takes the placeholder without its angle brackets (mesh-a-ctx).
			if (MODE == "paths") gsub(/[<>]/, "", PH[NN])
		}
		close(MAPF)
	}
	FI = 0
	while ((getline item < LISTF) > 0) {
		FI++
		split(item, A, "\t"); src = A[1]; kind = A[3]; dst = OUTD "/" FI
		if (MODE == "paths") {
			# P<TAB>index<TAB>renamed rel<TAB>renamed sub<TAB>sub, and N<TAB>index<TAB>reason
			# when the renamed path still holds a mapped name (the final scan of names).
			nr = (NN > 0) ? repctx(A[2]) : A[2]; ns = (NN > 0) ? repctx(A[5]) : A[5]
			printf "P\t%d\t%s\t%s\t%s\n", FI, nr, ns, A[5]
			t = nr; gsub(/(mesh|hub)-[a-z]+-ctx/, " ", t)
			for (i = 1; i <= NN; i++) if (findb(t, NAME[i], 1)) { printf "N\t%d\tits path still holds the mapped name %s\n", FI, NAME[i]; break }
			continue
		}
		HDR = ""; HSEEN = 0; NC = 0; delete CCOL; delete K; changed = 0; ln = 0
		while ((r = (getline L < src)) > 0) {
			ln++
			# The header (and a copy of it further down) is redacted like any line; its
			# column names, read before that, pick the columns.
			ishdr = 0
			if (!HSEEN && substr(L, 1, 1) != "#") ishdr = header(L, kind)
			else if (HDR != "" && L == HDR) ishdr = 1
			if (MODE == "learn") { learn(L); continue }
			s = redact(L)
			if (s != L) changed++
			print s > dst
			scan(s, ln, kind, ishdr)
		}
		if (r < 0 && MODE == "redact") printf "I\t%d\t0\tcannot read the file\n", FI
		close(src)
		if (MODE == "redact") {
			if (ln == 0) printf "" > dst
			close(dst)
			ks = ""
			nko = split("context url account email api-host host aws-id ip home", KO, " ")
			for (i = 1; i <= nko; i++) if (K[KO[i]] > 0) ks = ks (ks == "" ? "" : ", ") KO[i] " " K[KO[i]]
			printf "F\t%d\t%d\t%s\n", FI, changed, ks
		}
	}
	close(LISTF)
	if (MODE == "learn") for (k in LEARN) { split(k, F, SUBSEP); printf "%s\t%s\n", F[1], F[2] }
	if (MODE == "learn" && REDACTED_SEEN) printf "P\tredacted\n"
	exit 0
}'

# --- 3. Learn the names, build the mapping. ---
declare -A ROLE=()   # name -> M | H
declare -a MEMBERS=() HUBS=()
for _c in ${HUB_CTX[@]+"${HUB_CTX[@]}"}; do
	[[ -n "${ROLE[$_c]+x}" ]] && continue
	ROLE[$_c]=H; HUBS+=("$_c")
done
for _c in ${NAMED_CTX[@]+"${NAMED_CTX[@]}"}; do
	[[ -n "${ROLE[$_c]+x}" ]] && continue
	ROLE[$_c]=M; MEMBERS+=("$_c")
done
REDACTED_SEEN=0   # the metadata names members by placeholder only (an already redacted copy)
while IFS=$'\t' read -r _role _c; do
	if [[ "$_role" == P ]]; then REDACTED_SEEN=1; continue; fi
	[[ -n "$_c" && -z "${ROLE[$_c]+x}" ]] || continue
	ROLE[$_c]="$_role"
	if [[ "$_role" == H ]]; then HUBS+=("$_c"); else MEMBERS+=("$_c"); fi
done < <(awk -v MODE=learn -v LISTF="$LIST" "$REDACT_AWK" </dev/null | LC_ALL=C sort -t $'\t' -k1,1r -k2,2)
# No member to map: a lone report (the scale envelope, a summary) can name members in prose
# only, and the scan below finds no name it was not told about there. Refuse before
# anything is written, unless the metadata names members by placeholder only (a copy
# redacted already) or the operator says the files name none.
if ((${#MEMBERS[@]} == 0 && !REDACTED_SEEN && !NO_CONTEXTS)); then
	die "no member context found in the files' metadata and none given: pass --context NAME for each mesh member (a comma list works), or --no-contexts when the files name no kube context; nothing written"
fi

# letters <n>: a, b, ..., z, aa, ab, ...
letters() {
	local n="$1" s=""
	local -a a=({a..z})
	while :; do s="${a[n % 26]}${s}"; n=$((n / 26 - 1)); ((n >= 0)) || break; done
	printf '%s\n' "$s"
}

MAP="${WORK}/map.tsv"
: >"$MAP"
{
	echo "redact-results: context mapping for this run (stderr only; not written to any copy):"
	_i=0
	for _c in ${MEMBERS[@]+"${MEMBERS[@]}"}; do
		_ph="<mesh-$(letters "$_i")-ctx>"; _i=$((_i + 1))
		printf '%s\t%s\n' "$_c" "$_ph" >>"$MAP"
		printf '  %-16s %s\n' "$_ph" "$_c"
		((${#_c} >= 3)) || echo "  warning: ${_c} is short: any word equal to it is replaced too"
	done
	_i=0
	for _c in ${HUBS[@]+"${HUBS[@]}"}; do
		_ph="<hub-$(letters "$_i")-ctx>"; _i=$((_i + 1))
		printf '%s\t%s\n' "$_c" "$_ph" >>"$MAP"
		printf '  %-16s %s\n' "$_ph" "$_c"
	done
	if ((${#MEMBERS[@]} + ${#HUBS[@]} == 0)); then
		if ((REDACTED_SEEN)); then echo "  (none: the files' metadata names members by placeholder only, redacted already)"
		else echo "  none: not checked (--no-contexts): read the copy for member names"; fi
	fi
} >&2
# The file-name forms of each name (ctx_file_safe: whole, and cut to CTX_FILE_NAME_MAX
# chars for istiod-diag folders), when they differ, map to the same placeholder.
while IFS=$'\t' read -r _c _ph; do
	_s="$(ctx_file_safe "$_c")"
	_s40="$(ctx_file_safe "$_c" "$CTX_FILE_NAME_MAX")"
	[[ "$_s" == "$_c" || -n "${ROLE[$_s]+x}" ]] || printf '%s\t%s\n' "$_s" "$_ph"
	[[ "$_s40" == "$_s" || "$_s40" == "$_c" || -n "${ROLE[$_s40]+x}" ]] || printf '%s\t%s\n' "$_s40" "$_ph"
done <"$MAP" >"${WORK}/alias.tsv"
cat "${WORK}/alias.tsv" >>"$MAP"

# --- 4. Redact every file into the work dir, then check and place it. ---
mkdir -p "${WORK}/out"
RESULT="${WORK}/result.tsv"
awk -v MODE=redact -v LISTF="$LIST" -v MAPF="$MAP" -v OUTD="${WORK}/out" "$REDACT_AWK" </dev/null >"$RESULT"

declare -A CHANGED=() KINDS=() BAD=()
while IFS=$'\t' read -r _t _i _a _b; do
	case "$_t" in
	F) CHANGED[$_i]="$_a"; KINDS[$_i]="$_b" ;;
	I) BAD[$_i]+="    line ${_a}: ${_b}"$'\n' ;;
	esac
done <"$RESULT"

# --- 5. Names: a copied file's path that holds a mapped name (below a given dir, or a ---
# given file's own name) is renamed the same way, without the angle brackets.
declare -A NEWREL=() NEWSUB=()
awk -v MODE=paths -v LISTF="$LIST" -v MAPF="$MAP" "$REDACT_AWK" </dev/null >"${WORK}/paths.tsv"
while IFS=$'\t' read -r _t _i _a _b _; do
	case "$_t" in
	P) NEWREL[$_i]="$_a"; NEWSUB[$_i]="$_b" ;;
	N) BAD[$_i]+="    ${_a}"$'\n' ;;
	esac
done <"${WORK}/paths.tsv"
# Before anything is written: no two files may land at one path, nor a file where another
# needs a dir; --in-place neither renames a given dir nor moves a file onto a path that
# exists or below one that is not a dir.
declare -A NEW_SEEN=()
_i=0
while IFS=$'\t' read -r _src _rel _kind _anchor _sub; do
	_i=$((_i + 1))
	_nr="${NEWREL[$_i]:-$_rel}" _ns="${NEWSUB[$_i]:-$_sub}"
	[[ -z "${NEW_SEEN[$_nr]+x}" ]] || die "two files land at ${_nr} once their names are redacted: rename one of them (or redact them in separate runs) and run again"
	NEW_SEEN[$_nr]=1
done <"$LIST"
_i=0
while IFS=$'\t' read -r _src _rel _kind _anchor _sub; do
	_i=$((_i + 1))
	_nr="${NEWREL[$_i]:-$_rel}" _ns="${NEWSUB[$_i]:-$_sub}"
	_p="$_nr"
	while [[ "$_p" == */* ]]; do
		_p="${_p%/*}"
		[[ -z "${NEW_SEEN[$_p]+x}" ]] || die "${_p} would be both a file and a dir once names are redacted: rename one of them and run again"
	done
	if ! ((IN_PLACE)) || [[ "$_nr" == "$_rel" ]]; then continue; fi
	if [[ "$_sub" != "$_rel" && "${_nr%%/*}" != "${_rel%%/*}" ]]; then
		die "--in-place: the dir ${_anchor} holds a context name in its own name, and --in-place renames only what is below it: rename it, or use --out DIR (its copy is renamed), and run again"
	fi
	[[ "$_ns" == "$_sub" || ! -e "${_anchor}/${_ns}" ]] || die "--in-place: ${_src} would be renamed to ${_anchor}/${_ns}, which exists: move one of them and run again"
	_d="${_anchor}/${_ns}"
	_d="${_d%/*}"
	while [[ "$_d" == "$_anchor"/* ]]; do
		[[ ! -e "$_d" || -d "$_d" ]] || die "--in-place: ${_src} would move below ${_d}, which is not a dir: move it and run again"
		_d="${_d%/*}"
	done
done <"$LIST"

N_BAD=0
N_WRITTEN=0
N_CHANGED=0
RENAMED=()
_i=0
((DRY_RUN)) && echo "redact-results: dry run, nothing written"
while IFS=$'\t' read -r _src _rel _kind _anchor _sub; do
	_i=$((_i + 1))
	_tmp="${WORK}/out/${_i}"
	_nr="${NEWREL[$_i]:-$_rel}" _ns="${NEWSUB[$_i]:-$_sub}"
	if [[ "$_kind" == json && -z "${BAD[$_i]+x}" ]] && ! jq empty "$_tmp" >/dev/null 2>&1; then
		BAD[$_i]="    the redacted copy is no longer valid JSON"$'\n'
	fi
	_n="${CHANGED[$_i]:-0}"
	((_n == 0)) || N_CHANGED=$((N_CHANGED + 1))
	if [[ -n "${BAD[$_i]+x}" ]]; then
		N_BAD=$((N_BAD + 1))
		printf 'redact-results: %s: refused, not written:\n%s' "$_src" "${BAD[$_i]}" >&2
		((DRY_RUN)) && printf '  refused       %s (see stderr)\n' "$_src"
		continue
	fi
	[[ "$_nr" == "$_rel" ]] || RENAMED+=("${_rel} -> ${_nr}")
	if ((DRY_RUN)); then
		if ((_n > 0)); then printf '  would change  %s (%s line(s): %s)\n' "$_src" "$_n" "${KINDS[$_i]}"
		else printf '  unchanged     %s\n' "$_src"; fi
		continue
	fi
	if ((IN_PLACE)); then
		if ((_n > 0)); then cat "$_tmp" >"$_src"; N_WRITTEN=$((N_WRITTEN + 1)); fi
		if [[ "$_ns" != "$_sub" ]]; then
			mkdir -p "$(dirname "${_anchor}/${_ns}")"
			mv "$_src" "${_anchor}/${_ns}"
			# Remove the dirs the move emptied, up to (never) the given dir.
			_d="$(dirname "$_src")"
			while [[ "$_d" == "$_anchor"/* ]] && rmdir "$_d" 2>/dev/null; do _d="$(dirname "$_d")"; done
		fi
	else
		mkdir -p "$(dirname "${OUT_DIR}/${_nr}")"
		cp "$_tmp" "${OUT_DIR}/${_nr}"
		N_WRITTEN=$((N_WRITTEN + 1))
	fi
done <"$LIST"

if ((${#RENAMED[@]} > 0)); then
	{
		if ((DRY_RUN)); then
			echo "redact-results: file and dir names it would rename (stderr only):"
		elif ((IN_PLACE)); then
			echo "redact-results: renamed in place (stderr only):"
		else
			echo "redact-results: renamed in the copy (stderr only):"
		fi
		printf '  %s\n' "${RENAMED[@]}"
	} >&2
fi

# With --in-place, what it neither redacted nor renamed (skipped and refused files, and
# the dirs that hold them) may still name a context: list each topmost such path.
if ((IN_PLACE && !DRY_RUN)); then
	_left="${WORK}/left.tsv"
	: >"$_left"
	for _in in "${INPUTS[@]}"; do
		[[ -d "$_in" ]] || continue
		_in_trim="${_in%/}"
		[[ -n "$_in_trim" ]] || _in_trim="/"
		while IFS= read -r _f; do
			[[ "$_f" != *$'\t'* ]] || continue
			_r="${_f#"$_in_trim"/}"
			printf '%s\t%s\t-\t-\t%s\n' "$_f" "$_r" "$_r" >>"$_left"
		done < <(find -H "$_in_trim" -mindepth 1 -print 2>/dev/null | LC_ALL=C sort)
	done
	awk -v MODE=paths -v LISTF="$_left" -v MAPF="$MAP" "$REDACT_AWK" </dev/null | { grep '^P' || true; } >"${WORK}/left.out"
	_last="" _nleft=0
	while IFS=$'\t' read -r _src _rel _; do
		IFS=$'\t' read -r _t _i _a _b _c <&3 || break
		[[ "$_t" == P && "$_b" != "$_c" ]] || continue
		[[ -z "$_last" || "$_src" != "$_last"/* ]] || continue
		_last="$_src"
		((_nleft++ > 0)) || echo "redact-results: warning: still named after a context, neither redacted nor renamed (skipped or refused): never commit these:" >&2
		echo "  ${_src}" >&2
	done <"$_left" 3<"${WORK}/left.out"
fi

N_RENAMED=${#RENAMED[@]}
if ((DRY_RUN)); then
	echo "redact-results: ${N_FILES} file(s), ${N_CHANGED} would change, ${N_BAD} refused, ${N_RENAMED} would be renamed"
elif ((IN_PLACE)); then
	echo "redact-results: ${N_FILES} file(s), ${N_WRITTEN} rewritten in place, ${N_BAD} refused, ${N_RENAMED} renamed"
else
	echo "redact-results: ${N_WRITTEN} of ${N_FILES} file(s) written under ${OUT_DIR}, ${N_BAD} refused, ${N_RENAMED} renamed"
fi
if ((N_BAD > 0)); then
	echo "redact-results: ${N_BAD} file(s) refused (named above): do not paste them; pass --context NAME for a context the files' metadata does not name, then run again" >&2
	exit 1
fi
exit 0
