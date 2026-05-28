#!/usr/bin/env bash
# Apply a tuning profile to the live mesh.
#
# Patches the Istio CR (sailoperator.io/v1 Istio/default in istio-system) with
# the profile's istio_cr_patch and applies any additional resources defined in
# the profile's resources list.
#
# Before patching, the current Istio CR is saved to a state directory so
# 002-revert-profile.sh can restore it.
#
# Usage:
#   ./tests/tuning/001-apply-profile.sh --profile <path> [--contexts CSV] [options]
#
# Examples:
#   # Apply sidecar scoping on all clusters:
#   ./tests/tuning/001-apply-profile.sh --profile profiles/01-sidecar-scoping.yaml
#
#   # Dry-run to see what would change:
#   ./tests/tuning/001-apply-profile.sh --profile profiles/03-push-throttling.yaml --dry-run
#
#   # Apply with explicit state dir for later revert:
#   ./tests/tuning/001-apply-profile.sh --profile profiles/04-istiod-resources.yaml \
#     --state-dir results/my-run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

PROFILE=""
CONTEXTS_CSV=""
DRY_RUN=0
STATE_DIR=""
ISTIO_CR_NAME="default"
ISTIO_CR_NAMESPACE="istio-system"
ROLLOUT_TIMEOUT=300
SKIP_VERIFY=0
KUBECTL="kubectl"

die() { echo "error: $*" >&2; exit 1; }

VERIFY_PASS=0
VERIFY_FAIL=0
verify_ok()   { VERIFY_PASS=$((VERIFY_PASS + 1)); echo "  PASS  $*"; }
verify_fail() { VERIFY_FAIL=$((VERIFY_FAIL + 1)); echo "  FAIL  $*"; }

# Verify that a jsonpath query on the Istio CR returns a non-empty value.
verify_istio_cr_field() {
	local ctx="$1" jsonpath="$2" label="$3"
	local val
	val="$($KUBECTL --context="$ctx" get istio "$ISTIO_CR_NAME" \
		-n "$ISTIO_CR_NAMESPACE" -o jsonpath="{${jsonpath}}" 2>/dev/null)" || true
	if [[ -n "$val" ]]; then
		verify_ok "${ctx}: Istio CR ${label} = ${val}"
	else
		verify_fail "${ctx}: Istio CR ${label} — field empty or missing"
	fi
}

# Verify a pilot env var appears on the istiod Deployment's discovery container.
verify_pilot_env() {
	local ctx="$1" var_name="$2" expected="$3"
	local actual
	actual="$($KUBECTL --context="$ctx" get deployment istiod \
		-n "$ISTIO_CR_NAMESPACE" \
		-o jsonpath="{.spec.template.spec.containers[?(@.name=='discovery')].env[?(@.name=='${var_name}')].value}" \
		2>/dev/null)" || true
	if [[ -z "$actual" ]]; then
		actual="$($KUBECTL --context="$ctx" get deployment istiod \
			-n "$ISTIO_CR_NAMESPACE" \
			-o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='${var_name}')].value}" \
			2>/dev/null)" || true
	fi
	if [[ "$actual" == "$expected" ]]; then
		verify_ok "${ctx}: istiod env ${var_name}=${actual}"
	elif [[ -n "$actual" ]]; then
		verify_fail "${ctx}: istiod env ${var_name}=${actual} (expected ${expected})"
	else
		verify_fail "${ctx}: istiod env ${var_name} — not found on Deployment"
	fi
}

# Verify a Kubernetes resource exists.
verify_resource_exists() {
	local ctx="$1" kind="$2" name="$3" ns="$4"
	if $KUBECTL --context="$ctx" get "$kind" "$name" -n "$ns" \
		>/dev/null 2>&1; then
		verify_ok "${ctx}: ${kind}/${name} exists in ${ns}"
	else
		verify_fail "${ctx}: ${kind}/${name} not found in ${ns}"
	fi
}

# Verify istiod container resource requests/limits.
verify_container_resources() {
	local ctx="$1" path="$2" expected="$3" label="$4"
	local actual
	actual="$($KUBECTL --context="$ctx" get deployment istiod \
		-n "$ISTIO_CR_NAMESPACE" \
		-o jsonpath="{.spec.template.spec.containers[?(@.name=='discovery')].resources.${path}}" \
		2>/dev/null)" || true
	if [[ -z "$actual" ]]; then
		actual="$($KUBECTL --context="$ctx" get deployment istiod \
			-n "$ISTIO_CR_NAMESPACE" \
			-o jsonpath="{.spec.template.spec.containers[0].resources.${path}}" \
			2>/dev/null)" || true
	fi
	if [[ -n "$actual" ]]; then
		verify_ok "${ctx}: istiod ${label} = ${actual}"
	else
		verify_fail "${ctx}: istiod ${label} — not set on Deployment"
	fi
}

# Run profile-specific verification checks on one context. Dispatches based
# on the profile YAML contents (patch paths and resource kinds).
verify_profile() {
	local ctx="$1" profile_file="$2"

	local patch_json resource_json
	patch_json="$(python3 -c "
import yaml, json, sys
with open('${profile_file}') as f:
    d = yaml.safe_load(f)
print(json.dumps(d.get('istio_cr_patch') or {}))
")"
	resource_json="$(python3 -c "
import yaml, json, sys
with open('${profile_file}') as f:
    d = yaml.safe_load(f)
print(json.dumps(d.get('resources') or []))
")"

	# --- Verify Istio CR patch fields ---
	# pilot.env
	local env_keys
	env_keys="$(echo "$patch_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
env = d.get('spec',{}).get('values',{}).get('pilot',{}).get('env',{})
for k,v in env.items():
    print(f'{k}={v}')
" 2>/dev/null)" || true

	local line var_name var_val
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		var_name="${line%%=*}"
		var_val="${line#*=}"
		verify_istio_cr_field "$ctx" \
			".spec.values.pilot.env.${var_name}" \
			"pilot.env.${var_name}"
		verify_pilot_env "$ctx" "$var_name" "$var_val"
	done <<<"$env_keys"

	# pilot.resources
	local has_pilot_resources
	has_pilot_resources="$(echo "$patch_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('spec',{}).get('values',{}).get('pilot',{}).get('resources')
print('yes' if r else 'no')
" 2>/dev/null)" || true

	if [[ "$has_pilot_resources" == "yes" ]]; then
		verify_container_resources "$ctx" "requests.cpu" "" "resources.requests.cpu"
		verify_container_resources "$ctx" "limits.memory" "" "resources.limits.memory"
	fi

	# meshConfig fields (non-env)
	local mc_fields
	mc_fields="$(echo "$patch_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
mc = d.get('spec',{}).get('values',{}).get('meshConfig',{})
def walk(obj, path):
    if isinstance(obj, dict):
        for k,v in obj.items():
            walk(v, f'{path}.{k}')
    elif isinstance(obj, list):
        print(f'{path}=LIST')
    else:
        print(f'{path}={obj}')
walk(mc, '.spec.values.meshConfig')
" 2>/dev/null)" || true

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local field_path="${line%%=*}"
		verify_istio_cr_field "$ctx" "$field_path" "${field_path#.spec.values.}"
	done <<<"$mc_fields"

	# global.proxy fields
	local proxy_fields
	proxy_fields="$(echo "$patch_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
gp = d.get('spec',{}).get('values',{}).get('global',{}).get('proxy',{})
def walk(obj, path):
    if isinstance(obj, dict):
        for k,v in obj.items():
            walk(v, f'{path}.{k}')
    else:
        print(f'{path}={obj}')
walk(gp, '.spec.values.global.proxy')
" 2>/dev/null)" || true

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local field_path="${line%%=*}"
		verify_istio_cr_field "$ctx" "$field_path" "${field_path#.spec.values.}"
	done <<<"$proxy_fields"

	# --- Verify additional resources exist ---
	local res_lines
	res_lines="$(echo "$resource_json" | python3 -c "
import json, sys
resources = json.load(sys.stdin)
for r in resources:
    kind = r.get('kind','')
    name = r.get('metadata',{}).get('name','')
    ns = r.get('metadata',{}).get('namespace','istio-system')
    if kind and name:
        print(f'{kind} {name} {ns}')
" 2>/dev/null)" || true

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local r_kind r_name r_ns
		read -r r_kind r_name r_ns <<<"$line"
		verify_resource_exists "$ctx" "$r_kind" "$r_name" "$r_ns"
	done <<<"$res_lines"
}

usage() {
	cat <<EOF
Usage: $(basename "$0") --profile <path> [options]

Apply a tuning profile to the live mesh by patching the Istio CR and deploying
any additional resources defined in the profile.

Options:
  --profile PATH         Path to the profile YAML file (required).
  --contexts CSV         Kube contexts to target (default: \$SETUP_CONTEXTS).
  --state-dir DIR        Directory to save baseline state for revert
                         (default: results/state-<profile-name>).
  --rollout-timeout N    Seconds to wait for istiod rollout (default: $ROLLOUT_TIMEOUT).
  --skip-verify          Skip post-apply verification checks.
  --dry-run              Show what would be applied without changing clusters.
  -h, --help             Show this help.

Environment:
  SETUP_CONTEXTS         Default cluster contexts (from config/versions.env).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--profile) PROFILE="$2"; shift 2 ;;
	--contexts) CONTEXTS_CSV="$2"; shift 2 ;;
	--state-dir) STATE_DIR="$2"; shift 2 ;;
	--rollout-timeout) ROLLOUT_TIMEOUT="$2"; shift 2 ;;
	--skip-verify) SKIP_VERIFY=1; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "Unknown option: $1" ;;
	esac
done

[[ -n "$PROFILE" ]] || die "--profile is required"
[[ -f "$PROFILE" ]] || die "Profile not found: $PROFILE"

command -v yq >/dev/null 2>&1 || die "yq (v4+) is required but not found in PATH"

CONTEXTS_CSV="${CONTEXTS_CSV:-$SETUP_CONTEXTS}"
[[ -n "$CONTEXTS_CSV" ]] || die "No contexts specified (set --contexts or SETUP_CONTEXTS)"

IFS=',' read -ra CONTEXTS <<<"$CONTEXTS_CSV"

PROFILE_NAME="$(basename "$PROFILE" .yaml)"

if [[ -z "$STATE_DIR" ]]; then
	STATE_DIR="${ROOT}/tests/tuning/results/state-${PROFILE_NAME}"
fi

OSSM_SUPPORT="$(yq -r '.ossm_support // "unknown"' "$PROFILE")"
case "$OSSM_SUPPORT" in
configurable)
	echo "NOTE: Profile '${PROFILE_NAME}' uses features not explicitly documented by Red Hat."
	detail="$(yq -r '.ossm_support_detail // ""' "$PROFILE")"
	[[ -n "$detail" ]] && echo "      ${detail}"
	echo ""
	;;
not-supported | not-supported-multicluster)
	echo "WARNING: Profile '${PROFILE_NAME}' is ${OSSM_SUPPORT}."
	detail="$(yq -r '.ossm_support_detail // ""' "$PROFILE")"
	[[ -n "$detail" ]] && echo "         ${detail}"
	echo ""
	if ((DRY_RUN)); then
		echo "(dry-run — continuing for inspection)"
	else
		echo "This profile cannot be applied automatically to an OSSM multicluster mesh."
		echo "See the profile YAML for manual steps."
		exit 1
	fi
	;;
esac

HAS_PATCH="$(yq -r '.istio_cr_patch | length' "$PROFILE")"
HAS_RESOURCES="$(yq -r '.resources | length' "$PROFILE")"

if [[ "$HAS_PATCH" == "0" ]] && [[ "$HAS_RESOURCES" == "0" ]]; then
	die "Profile has no istio_cr_patch and no resources — nothing to apply"
fi

echo "=== Applying profile: ${PROFILE_NAME} ==="
echo "    OSSM support: ${OSSM_SUPPORT}"
echo "    Contexts:     ${CONTEXTS_CSV}"
echo "    State dir:    ${STATE_DIR}"
echo ""

if ((DRY_RUN)); then
	echo "--- DRY RUN: Istio CR patch ---"
	if [[ "$HAS_PATCH" != "0" ]]; then
		yq -r '.istio_cr_patch' "$PROFILE"
	else
		echo "(no Istio CR patch)"
	fi
	echo ""
	echo "--- DRY RUN: Additional resources ---"
	if [[ "$HAS_RESOURCES" != "0" ]]; then
		yq -r '.resources[]' "$PROFILE"
	else
		echo "(no additional resources)"
	fi
	echo ""
	echo "--- DRY RUN: Would save baseline to ${STATE_DIR}/ ---"
	exit 0
fi

mkdir -p "$STATE_DIR"

PATCH_FILE=""
if [[ "$HAS_PATCH" != "0" ]]; then
	PATCH_FILE="$(mktemp)"
	yq -r -o json '.istio_cr_patch' "$PROFILE" > "$PATCH_FILE"
fi

RESOURCES_FILE=""
if [[ "$HAS_RESOURCES" != "0" ]]; then
	RESOURCES_FILE="$(mktemp)"
	yq -r '.resources[] | splitDoc' "$PROFILE" > "$RESOURCES_FILE"
fi

for ctx in "${CONTEXTS[@]}"; do
	ctx="${ctx#"${ctx%%[![:space:]]*}"}"
	ctx="${ctx%"${ctx##*[![:space:]]}"}"
	[[ -z "$ctx" ]] && continue

	echo "--- ${ctx}: saving baseline Istio CR ---"
	$KUBECTL --context="$ctx" get istio "$ISTIO_CR_NAME" \
		-n "$ISTIO_CR_NAMESPACE" -o yaml \
		> "${STATE_DIR}/istio-baseline-${ctx}.yaml" 2>/dev/null \
		|| die "Failed to get Istio CR on context ${ctx}"

	if [[ -n "$PATCH_FILE" ]]; then
		echo "--- ${ctx}: patching Istio CR ---"
		$KUBECTL --context="$ctx" patch istio "$ISTIO_CR_NAME" \
			-n "$ISTIO_CR_NAMESPACE" \
			--type=merge \
			-p "$(cat "$PATCH_FILE")"
	fi

	if [[ -n "$RESOURCES_FILE" ]]; then
		echo "--- ${ctx}: applying profile resources ---"
		$KUBECTL --context="$ctx" apply --server-side --force-conflicts \
			-f "$RESOURCES_FILE"
	fi
done

echo "$PROFILE_NAME" > "${STATE_DIR}/active-profile"
[[ -n "$RESOURCES_FILE" ]] && cp "$RESOURCES_FILE" "${STATE_DIR}/applied-resources.yaml"

echo ""
echo "=== Waiting for istiod rollout ==="
for ctx in "${CONTEXTS[@]}"; do
	ctx="${ctx#"${ctx%%[![:space:]]*}"}"
	ctx="${ctx%"${ctx##*[![:space:]]}"}"
	[[ -z "$ctx" ]] && continue

	echo "--- ${ctx}: waiting up to ${ROLLOUT_TIMEOUT}s ---"
	$KUBECTL --context="$ctx" rollout status deployment/istiod \
		-n "$ISTIO_CR_NAMESPACE" \
		--timeout="${ROLLOUT_TIMEOUT}s" 2>/dev/null || true
done

rm -f "$PATCH_FILE" "$RESOURCES_FILE"

if ((SKIP_VERIFY)); then
	echo ""
	echo "=== Profile '${PROFILE_NAME}' applied (verification skipped) ==="
	echo "    Revert with: ./tests/tuning/002-revert-profile.sh --state-dir ${STATE_DIR} --contexts ${CONTEXTS_CSV}"
	exit 0
fi

echo ""
echo "=== Verifying profile: ${PROFILE_NAME} ==="

for ctx in "${CONTEXTS[@]}"; do
	ctx="${ctx#"${ctx%%[![:space:]]*}"}"
	ctx="${ctx%"${ctx##*[![:space:]]}"}"
	[[ -z "$ctx" ]] && continue

	echo ""
	echo "--- ${ctx} ---"
	verify_profile "$ctx" "$PROFILE"
done

echo ""
if ((VERIFY_FAIL > 0)); then
	echo "=== Profile '${PROFILE_NAME}' applied with verification issues ==="
	echo "    ${VERIFY_PASS} passed, ${VERIFY_FAIL} failed"
	echo ""
	echo "    Some checks failed. Possible causes:"
	echo "      - The Sail operator has not yet reconciled the Istio CR"
	echo "      - istiod has not finished rolling out the new configuration"
	echo "      - The profile patch targets a field the operator does not propagate"
	echo "    Re-run with --skip-verify to bypass, or wait and retry."
else
	echo "=== Profile '${PROFILE_NAME}' applied and verified ==="
	echo "    ${VERIFY_PASS} checks passed"
fi
echo "    Revert with: ./tests/tuning/002-revert-profile.sh --state-dir ${STATE_DIR} --contexts ${CONTEXTS_CSV}"
