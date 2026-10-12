#!/usr/bin/env bash
# Read-only /openapi/v2 check for the ACM hub (where Argo CD runs).
#
# Some MCE builds served a clusterview/v1alpha1 OpenAPI model with a dangling
# $ref; Argo CD then fails to load the hub's schema and the app-of-apps never
# syncs. MCE >= 2.11.3 (current ACM 2.16.z and 2.17) is fixed. Run this before
# the platform apply; a non-zero exit means: upgrade ACM/MCE first.
#
# Usage:
#   ./terraform/platform/scripts/001-openapi-preflight.sh --contexts <acm-hub-ctx> [--dry-run]
# ci-dry-run: --contexts ci-dummy --dry-run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"

CONTEXTS_CSV=""
DRY_RUN=0
REQUEST_TIMEOUT="${OPENAPI_PREFLIGHT_TIMEOUT:-15}"

usage() {
	cat >&2 <<EOF
Usage: ${0##*/} --contexts CSV [--dry-run]

  --contexts CSV   Kube context(s) of the ACM hub to check (required).
  --dry-run        Print what would be checked; do not contact any cluster.

Reads <ctx>/openapi/v2 (read-only) and fails if a clusterview definition carries a
dangling \$ref, which makes Argo CD fail to load the hub schema.
EOF
}

while (($#)); do
	case "$1" in
		--contexts)
			[[ -n "${2:-}" ]] || die "--contexts requires a value"
			CONTEXTS_CSV="$2"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage; die "unknown argument: $1" ;;
	esac
done

[[ -n "$CONTEXTS_CSV" ]] || { usage; die "--contexts is required"; }
split_csv "$CONTEXTS_CSV" CONTEXTS
((${#CONTEXTS[@]})) || die "no contexts resolved from: $CONTEXTS_CSV"

if command -v oc >/dev/null 2>&1; then KUBECTL=(oc); else KUBECTL=(kubectl); fi
command -v jq >/dev/null 2>&1 || die "jq is required"

echo "=== /openapi/v2 preflight ==="
echo "Contexts: ${CONTEXTS[*]}"
((DRY_RUN)) && echo "Mode:     dry-run"
echo ""

if ((DRY_RUN)); then
	for ctx in "${CONTEXTS[@]}"; do
		echo "[dry-run] would: ${KUBECTL[*]} --context=$ctx get --raw /openapi/v2 | jq (dangling-ref scan)"
	done
	echo "dry-run: no clusters contacted."
	exit 0
fi

# jq program: a "definition" is poison if it references (anywhere in its subtree) a
# $ref to a model not present in the top-level definitions map. We scope the scan to
# clusterview definitions (the known bad model) but report any dangling ref.
# shellcheck disable=SC2016  # $ref/$defs/$known are jq variables, not shell.
JQ_SCAN='
  (.definitions // {}) as $defs
  | ($defs | keys) as $known
  | [ $defs | to_entries[]
      | .key as $name
      | [ .value | .. | objects | select(has("$ref")) | .["$ref"]
          | sub("^#/definitions/"; "") ]
      | map(select((. as $r | $known | index($r)) | not))
      | select(length > 0)
      | {def: $name, dangling: .}
    ]
'

rc=0
for ctx in "${CONTEXTS[@]}"; do
	echo "Checking $ctx ..."
	body="$("${KUBECTL[@]}" --context="$ctx" --request-timeout="${REQUEST_TIMEOUT}s" \
		get --raw /openapi/v2 2>/dev/null)" || {
		echo "  WARN: $ctx: could not fetch /openapi/v2 (context unreachable?); check the hub manually." >&2
		rc=1
		continue
	}
	if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
		echo "  FAIL: $ctx: /openapi/v2 is not valid JSON (this is itself the failure mode ArgoCD hits)." >&2
		rc=1
		continue
	fi
	broken="$(printf '%s' "$body" | jq -c "$JQ_SCAN" 2>/dev/null || echo '[]')"
	cv_broken="$(printf '%s' "$broken" | jq -c '[ .[] | select(.def | test("clusterview"; "i")) ]' 2>/dev/null || echo '[]')"
	if [[ "$cv_broken" != "[]" && -n "$cv_broken" ]]; then
		echo "  FAIL: $ctx: clusterview OpenAPI has dangling \$ref(s); Argo CD cannot load this hub's schema:" >&2
		printf '%s' "$cv_broken" | jq -r '.[] | "    \(.def): missing refs \(.dangling)"' >&2
		echo "    Fix: upgrade ACM so MCE >= 2.11.3, then re-run. Do not disable server-foundation (it breaks spoke import)." >&2
		rc=1
		continue
	fi
	# Surface any non-clusterview dangling refs as a soft warning (not the gate).
	other_broken="$(printf '%s' "$broken" | jq -c '[ .[] | select((.def | test("clusterview"; "i")) | not) ]' 2>/dev/null || echo '[]')"
	if [[ "$other_broken" != "[]" && -n "$other_broken" ]]; then
		echo "  WARN: $ctx: non-clusterview dangling \$ref(s) present (Argo CD may still struggle):" >&2
		printf '%s' "$other_broken" | jq -r '.[] | "    \(.def): missing refs \(.dangling)"' >&2
	fi
	echo "  OK: $ctx: /openapi/v2 parses; no clusterview SchemaError."
done

if ((rc != 0)); then
	die "/openapi/v2 preflight FAILED. See messages above."
fi
echo ""
echo "/openapi/v2 preflight passed on: ${CONTEXTS[*]}"
