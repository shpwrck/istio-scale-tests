#!/usr/bin/env bash
# /openapi/v2 GO-gate preflight (BLOCKER #1). READ-ONLY.
#
# The hub's aggregated clusterview API (ocm-proxyserver, owned by the MCE
# `server-foundation` component) can ship a MALFORMED OpenAPI model
# (clusterview/v1alpha1.UserPermission with an unresolved `UserPermissionStatus`
# $ref). When that poison is present, ArgoCD's hub cluster-cache call to
# LoadOpenAPISchema fails fatally and the app-of-apps never reconciles — so NO
# mesh ApplicationSets get created (STRESS_TEST_STATUS.md BLOCKER #1).
#
# This script asserts, BEFORE the app-of-apps runs, that each target context's
# /openapi/v2 (a) parses as JSON and (b) carries no clusterview definition with a
# dangling $ref (the SchemaError signature). It only READS `--raw /openapi/v2`;
# it never mutates a cluster. Run it as a GO gate; a non-zero exit means the hub
# would crash ArgoCD — fix the MCE version / disable server-foundation
# (charts/acm-multicluster-hub disabledComponents, var.acm_disabled_components)
# and re-run before proceeding.
#
# Usage:
#   ./terraform/platform/scripts/001-openapi-preflight.sh [--contexts CSV] [--dry-run]
#
# Examples:
#   # Check the hub (first SETUP_CONTEXTS entry by default):
#   ./terraform/platform/scripts/001-openapi-preflight.sh
#
#   # Check a specific hub context:
#   ./terraform/platform/scripts/001-openapi-preflight.sh --contexts cluster-001
# ci-dry-run: --contexts ci-dummy --dry-run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"

CONTEXTS_CSV="${SETUP_CONTEXTS:-}"
DRY_RUN=0
REQUEST_TIMEOUT="${OPENAPI_PREFLIGHT_TIMEOUT:-15}"

usage() {
	cat >&2 <<EOF
Usage: ${0##*/} [--contexts CSV] [--dry-run]

  --contexts CSV   Comma-separated kube contexts to check (default: SETUP_CONTEXTS,
                   or its first entry — the hub — if you only need the hub gate).
  --dry-run        Print what would be checked; do not contact any cluster.

Reads <ctx>/openapi/v2 (read-only) and fails if a clusterview definition carries a
dangling \$ref (the BLOCKER #1 SchemaError signature that crashes ArgoCD).
Internal DRY_RUN (0/1) pairs with --dry-run.
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

[[ -n "$CONTEXTS_CSV" ]] || die "no contexts: pass --contexts CSV or export SETUP_CONTEXTS"
split_csv "$CONTEXTS_CSV" CONTEXTS
((${#CONTEXTS[@]})) || die "no contexts resolved from: $CONTEXTS_CSV"

if command -v oc >/dev/null 2>&1; then KUBECTL=(oc); else KUBECTL=(kubectl); fi
command -v jq >/dev/null 2>&1 || die "jq is required"

echo "=== /openapi/v2 preflight (BLOCKER #1 GO gate) ==="
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
# clusterview definitions (the known BLOCKER #1 source) but report any dangling ref.
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
		echo "  WARN: $ctx: could not fetch /openapi/v2 (context unreachable?); cannot assert the gate — verify the hub manually before GO." >&2
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
		echo "  FAIL: $ctx: clusterview OpenAPI has dangling \$ref(s) — the BLOCKER #1 SchemaError that crashes ArgoCD's hub cluster-cache:" >&2
		printf '%s' "$cv_broken" | jq -r '.[] | "    \(.def): missing refs \(.dangling)"' >&2
		echo "    Fix: disable the MCE server-foundation component at install (charts/acm-multicluster-hub disabledComponents / terraform var.acm_disabled_components) or pin an ACM/MCE (config/versions.env ACM_MCE_VERSION) that serves valid clusterview OpenAPI; then re-run this gate." >&2
		rc=1
		continue
	fi
	# Surface any non-clusterview dangling refs as a soft warning (not the gate).
	other_broken="$(printf '%s' "$broken" | jq -c '[ .[] | select((.def | test("clusterview"; "i")) | not) ]' 2>/dev/null || echo '[]')"
	if [[ "$other_broken" != "[]" && -n "$other_broken" ]]; then
		echo "  WARN: $ctx: non-clusterview dangling \$ref(s) present (not the BLOCKER #1 gate, but ArgoCD may still struggle):" >&2
		printf '%s' "$other_broken" | jq -r '.[] | "    \(.def): missing refs \(.dangling)"' >&2
	fi
	echo "  OK: $ctx: /openapi/v2 parses; no clusterview SchemaError."
done

if ((rc != 0)); then
	die "/openapi/v2 preflight FAILED — NO-GO. See messages above."
fi
echo ""
echo "/openapi/v2 preflight passed on: ${CONTEXTS[*]}"
