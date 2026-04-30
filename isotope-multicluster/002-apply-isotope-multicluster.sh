#!/usr/bin/env bash
# Render istio/tools isotope manifests per logical cluster and apply to kube contexts (multi-cluster mesh).
# Prerequisites: multi-primary mesh (istio-setup 004–008), multicluster DNS for *.global, clone of istio/tools, Go.
#
# Usage (repo root):
#   ./isotope-multicluster/002-apply-isotope-multicluster.sh [--tools-root DIR] [--topology FILE] \\
#     [--service-image REF] [--logical-clusters CSV] [--namespace-map k:v,...] [--uniform-namespace NS] [--contexts CSV] \\
#     [--render-only | --apply-only] [--gen-dir DIR] [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

SETUP_CONTEXTS="${SETUP_CONTEXTS:-rosa-001,rosa-002,rosa-003}"
TOOLS_ROOT="${ISOTOPE_TOOLS_ROOT:-}"
TOPOLOGY=""
SERVICE_IMAGE="${ISOTOPE_SERVICE_IMAGE:-}"
LOGICAL_CLUSTERS_CSV="${ISOTOPE_LOGICAL_CLUSTERS:-cluster1,cluster2}"
NAMESPACE_MAP_CSV="${ISOTOPE_NAMESPACE_MAP:-cluster1:demo1,cluster2:demo2}"
UNIFORM_NAMESPACE=""
CONTEXTS_CSV=""
GEN_DIR="${ROOT}/isotope-multicluster/gen"
RENDER_ONLY=0
APPLY_ONLY=0
DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --tools-root DIR     Path to a clone of https://github.com/istio/tools (or set ISOTOPE_TOOLS_ROOT).
  --topology FILE      service-graph YAML (default: ${ROOT}/isotope-multicluster/topology/service-graph-multicluster.yaml).
  --service-image REF  Container image for isotope mock services (or set ISOTOPE_SERVICE_IMAGE).
  --logical-clusters CSV   Logical cluster names in the topology, in order (default: cluster1,cluster2).
  --namespace-map CSV      cluster:namespace pairs for Namespace creation (default: cluster1:demo1,cluster2:demo2).
  --uniform-namespace NS   Build namespace map as <each-logical>:NS (overrides --namespace-map / ISOTOPE_NAMESPACE_MAP).
  --contexts CSV       Kube contexts to apply to, same length/order as logical clusters (default: first N of SETUP_CONTEXTS).
  --gen-dir DIR        Write rendered YAML here (default: isotope-multicluster/gen).
  --render-only        Only render manifests; do not apply.
  --apply-only         Only oc apply existing files in gen-dir (expects isotope-<logical>.yaml).
  --dry-run            oc apply --dry-run=client when applying.

Environment:
  ISOTOPE_TOOLS_ROOT, ISOTOPE_SERVICE_IMAGE, ISOTOPE_LOGICAL_CLUSTERS, ISOTOPE_NAMESPACE_MAP, SETUP_CONTEXTS.
  --uniform-namespace overrides ISOTOPE_NAMESPACE_MAP when that flag is set.

Requires: oc or kubectl, go (on PATH), git clone of istio/tools at tools-root.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--tools-root)
		[[ -n "${2:-}" ]] || die "--tools-root requires a value"
		TOOLS_ROOT="$2"
		shift 2
		;;
	--topology)
		[[ -n "${2:-}" ]] || die "--topology requires a value"
		TOPOLOGY="$2"
		shift 2
		;;
	--service-image)
		[[ -n "${2:-}" ]] || die "--service-image requires a value"
		SERVICE_IMAGE="$2"
		shift 2
		;;
	--logical-clusters)
		[[ -n "${2:-}" ]] || die "--logical-clusters requires a value"
		LOGICAL_CLUSTERS_CSV="$2"
		shift 2
		;;
	--namespace-map)
		[[ -n "${2:-}" ]] || die "--namespace-map requires a value"
		NAMESPACE_MAP_CSV="$2"
		shift 2
		;;
	--uniform-namespace)
		[[ -n "${2:-}" ]] || die "--uniform-namespace requires a value"
		UNIFORM_NAMESPACE="$2"
		shift 2
		;;
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--gen-dir)
		[[ -n "${2:-}" ]] || die "--gen-dir requires a value"
		GEN_DIR="$2"
		shift 2
		;;
	--render-only)
		RENDER_ONLY=1
		shift
		;;
	--apply-only)
		APPLY_ONLY=1
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1 (try --help)"
		;;
	esac
done

[[ -z "$TOPOLOGY" ]] && TOPOLOGY="${ROOT}/isotope-multicluster/topology/service-graph-multicluster.yaml"
if (( ! APPLY_ONLY )); then
	[[ -f "$TOPOLOGY" ]] || die "topology not found: $TOPOLOGY"
fi

LOGICALS=()
split_csv "$LOGICAL_CLUSTERS_CSV" LOGICALS
((${#LOGICALS[@]})) || die "no logical clusters parsed from: ${LOGICAL_CLUSTERS_CSV}"

if [[ -n "$UNIFORM_NAMESPACE" ]]; then
	NAMESPACE_MAP_CSV=""
	for lc in "${LOGICALS[@]}"; do
		[[ -n "$NAMESPACE_MAP_CSV" ]] && NAMESPACE_MAP_CSV+=","
		NAMESPACE_MAP_CSV+="${lc}:${UNIFORM_NAMESPACE}"
	done
fi

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	die "neither oc nor kubectl found on PATH"
fi

apply=("${KUBECTL[@]}" apply)
((DRY_RUN)) && apply=("${KUBECTL[@]}" apply --dry-run=client)

namespace_for_logical_cluster() {
	local lc="$1"
	local pair p k v
	IFS=',' read -ra _pairs <<<"$NAMESPACE_MAP_CSV"
	for pair in "${_pairs[@]}"; do
		pair="${pair#"${pair%%[![:space:]]*}"}"
		pair="${pair%"${pair##*[![:space:]]}"}"
		[[ -z "$pair" ]] && continue
		k="${pair%%:*}"
		v="${pair#*:}"
		[[ "$k" == "$lc" ]] && echo "$v" && return 0
	done
	return 1
}

split_csv() {
	local csv="$1"
	local -n _out="$2"
	_out=()
	local x
	IFS=',' read -ra _raw <<<"$csv"
	for x in "${_raw[@]}"; do
		x="${x#"${x%%[![:space:]]*}"}"
		x="${x%"${x##*[![:space:]]}"}"
		[[ -n "$x" ]] && _out+=("$x")
	done
}

CONTEXTS=()
split_csv "$CONTEXTS_CSV" CONTEXTS

if [[ ${#CONTEXTS[@]} -eq 0 ]]; then
	split_csv "$SETUP_CONTEXTS" CONTEXTS
	first_n=()
	for ((i = 0; i < ${#LOGICALS[@]} && i < ${#CONTEXTS[@]}; i++)); do
		first_n+=("${CONTEXTS[i]}")
	done
	CONTEXTS=("${first_n[@]}")
fi

((${#CONTEXTS[@]} == ${#LOGICALS[@]})) || die "context count (${#CONTEXTS[@]}) must match logical cluster count (${#LOGICALS[@]}); pass --contexts with ${#LOGICALS[@]} names"

if ((APPLY_ONLY)); then
	mkdir -p "$GEN_DIR"
	for i in "${!LOGICALS[@]}"; do
		lc="${LOGICALS[i]}"
		ctx="${CONTEXTS[i]}"
		out="${GEN_DIR}/isotope-${lc}.yaml"
		[[ -f "$out" ]] || die "missing rendered file: $out (run without --apply-only first)"
		ns="$(namespace_for_logical_cluster "$lc")" || die "no namespace in map for logical cluster: $lc"
		echo "Applying $out to context $ctx (namespace $ns)"
		if ! "${KUBECTL[@]}" --context="$ctx" get namespace "$ns" >/dev/null 2>&1; then
			echo "Creating namespace $ns on $ctx"
			"${KUBECTL[@]}" --context="$ctx" create namespace "$ns"
		fi
		"${apply[@]}" --context="$ctx" -f "$out"
	done
	exit 0
fi

[[ -n "$TOOLS_ROOT" ]] || die "set --tools-root or ISOTOPE_TOOLS_ROOT to your istio/tools clone"
[[ -d "${TOOLS_ROOT}/isotope/convert" ]] || die "invalid tools root (expected isotope/convert): $TOOLS_ROOT"
command -v go >/dev/null 2>&1 || die "go not found on PATH (required to run the converter)"

[[ -n "$SERVICE_IMAGE" ]] || die "set --service-image or ISOTOPE_SERVICE_IMAGE (isotope mock-service image)"

mkdir -p "$GEN_DIR"

strip_converter_comments() {
	# Converter emits leading ## lines that are not valid Kubernetes YAML documents.
	grep -v '^## ' || true
}

for i in "${!LOGICALS[@]}"; do
	lc="${LOGICALS[i]}"
	out="${GEN_DIR}/isotope-${lc}.yaml"
	client_disabled=0
	((i > 0)) && client_disabled=1
	cmd=(
		go run ./isotope/convert kubernetes "$TOPOLOGY"
		--service-image "$SERVICE_IMAGE"
		--cluster "$lc"
	)
	((client_disabled)) && cmd+=(--client-disabled)

	echo "Rendering logical cluster '$lc' -> $out"
	(
		cd "$TOOLS_ROOT"
		"${cmd[@]}"
	) | strip_converter_comments >"$out"
done

((RENDER_ONLY)) && echo "Rendered under $GEN_DIR (render-only)." && exit 0

for i in "${!LOGICALS[@]}"; do
	lc="${LOGICALS[i]}"
	ctx="${CONTEXTS[i]}"
	out="${GEN_DIR}/isotope-${lc}.yaml"
	ns="$(namespace_for_logical_cluster "$lc")" || die "no namespace in map for logical cluster: $lc"
	echo "Applying $out to context $ctx (namespace $ns)"
	if ! "${KUBECTL[@]}" --context="$ctx" get namespace "$ns" >/dev/null 2>&1; then
		echo "Creating namespace $ns on $ctx"
		if ((DRY_RUN)); then
			"${KUBECTL[@]}" --context="$ctx" create namespace "$ns" --dry-run=client -o yaml | "${apply[@]}" --context="$ctx" -f -
		else
			"${KUBECTL[@]}" --context="$ctx" create namespace "$ns"
		fi
	fi
	"${apply[@]}" --context="$ctx" -f "$out"
done

echo "Done. Enable sidecar injection on your workload namespace(s) as required by your mesh (OSSM/Sail). Drive load from the Fortio client on the first cluster (see isotope-multicluster/README.md)."
