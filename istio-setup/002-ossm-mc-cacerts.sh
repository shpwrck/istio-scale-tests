#!/usr/bin/env bash
# Requires bash 4+ (associative arrays in apply).
#
# OpenShift Service Mesh 3.x — multi-cluster plug-in CA material and cacerts Secret
# -------------------------------------------------------------------------------
# Source of truth (plug-in CA, multi-cluster): Red Hat OSSM 3.3 — Multi-cluster topologies
#   https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies
# Also see repo config/versions.env and AGENTS.md for pinned platform / Istio versions.
#
# This script automates the *certificate* steps the documentation describes for
# multi-primary / shared-trust setups:
#   - One offline root CA (self-signed), shared conceptual trust anchor.
#   - One intermediate CA per cluster, signed by that root (pathlen:0), with SAN
#     including istiod.istio-system.svc (matches common RH/Istio examples).
#   - Per-cluster files: ca-cert.pem, ca-key.pem, root-cert.pem, cert-chain.pem
#     (intermediate + root), suitable for a Kubernetes Secret named "cacerts".
#   - Optional: create/update the cacerts Secret in each cluster (oc/kubectl) and
#     label the istio-system namespace with topology.istio.io/network=...
#
# Mesh control plane (Istio CR / plug-in CA) must reference ThirdParty (or
# equivalent) identity and the cacerts Secret before workload/intermediate
# issuance works — configure that in your Istio/ServiceMesh resources per the
# same guide; this script does not apply SMCP/Istio CRs.
#
# East-west gateways in the doc use Gateways with TLS mode AUTO_PASSTHROUGH so
# cross-mesh traffic uses normal mesh identities; you do *not* generate separate
# TLS keypairs for 15443 beyond what Istio issues. If your environment uses
# custom gateway certs instead, that is out of scope here.
#
# Assumptions / limits:
#   - openssl is on PATH. Root and intermediates are generated locally (not
#     openshift-install, not cert-manager) unless you only use verify/apply
#     with pre-existing PEMs.
#   - Secret keys must be named exactly: ca-cert.pem, ca-key.pem, root-cert.pem,
#     cert-chain.pem (Istio plug-in CA / cacerts contract).
#   - Idempotent: generate skips existing artifacts unless --force. apply uses
#     --dry-run, or creates secret, or with --replace deletes then recreates.

set -euo pipefail

PROG_NAME=$(basename "$0")
ROOT_DAYS=3650
INT_DAYS=3650
DEFAULT_BASE="$(pwd)/cacerts"
DEFAULT_NS=istio-system
MESH_NS=istio-system

dlog() { printf '%s\n' "[$PROG_NAME] $*"; }
die() { dlog "error: $*"; exit 1; }

usage() {
	cat <<EOF
Usage: $PROG_NAME <command> [options]

Commands:
  generate   Create root + per-cluster intermediate PEMs under <base>/cacerts/
  apply      Create cacerts Secret in each target cluster (requires cluster mapping)
  verify     openssl verify on each cert-chain
  help       This message

generate options:
  --base DIR         Working directory (default: $DEFAULT_BASE; PEMs: DIR/cacerts/...)
  --clusters CSV     Comma-separated cluster key names, e.g. rosa-001,rosa-002,west
  --force            Regenerate even if key material already exists
  --mesh-ns NAME     Namespace for istiod in intermediate SAN (default: $DEFAULT_NS)

apply options:
  --base DIR         Must match prior generate (default: $DEFAULT_BASE)
  --ns NAME          Namespace (default: $DEFAULT_NS)
  --replace          Delete existing cacerts Secret in NS before create
  --context-map K:V[,K:V...]   Map cluster key -> kube context (oc/kubectl)
  --network-suffix S Default network = "<clusterkey>-<S>" (default: network; so west -> west-network)
  --dry-run          Only print what would be run; do not call oc/kubectl
  (Requires oc or kubectl on PATH. Uses: oc --context=... when context-map set)

verify options:
  --base DIR         Same as generate (default: $DEFAULT_BASE)
  --clusters CSV     If omitted, deduce from subdirs of <base>/cacerts/ (excluding root)

Examples:
  $PROG_NAME generate --base /tmp/mesh --clusters west,east
  $PROG_NAME apply --base /tmp/mesh --context-map 'west:my-west-ctx,east:my-east-ctx' --replace
  $PROG_NAME verify --base /tmp/mesh

Doc: Red Hat OSSM 3.3 — Multi-cluster topologies (URL in AGENTS.md / config/versions.env)
EOF
}

# --- openssl helpers (aligned with https://access.redhat.com multi-primary examples) ---

write_root_conf() {
	local f=$1
	cat >"$f" <<'EOF'
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
[ req_dn ]
O = Istio
CN = Root CA
EOF
}

write_intermediate_conf() {
	local f=$1
	local key=$2
	cat >"$f" <<EOF
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
subjectAltName=@san
[ san ]
DNS.1 = istiod.${MESH_NS}.svc
[ req_dn ]
O = Istio
CN = Intermediate CA
L = $key
EOF
}

gen_root() {
	local base=$1
	local root_dir=${base}/cacerts/root
	mkdir -p "$root_dir"
	if [[ -f $root_dir/root-key.pem && $FORCE -eq 0 ]]; then
		dlog "root: exists, skipping (use --force to regenerate) -> $root_dir"
		return 0
	fi
	dlog "root: writing $root_dir"
	write_root_conf "${root_dir}/root-ca.conf"
	openssl genrsa -out "${root_dir}/root-key.pem" 4096
	openssl req -sha256 -new -key "${root_dir}/root-key.pem" \
		-config "${root_dir}/root-ca.conf" -out "${root_dir}/root-cert.csr"
	openssl x509 -req -sha256 -days "$ROOT_DAYS" \
		-signkey "${root_dir}/root-key.pem" -extensions req_ext -extfile "${root_dir}/root-ca.conf" \
		-in "${root_dir}/root-cert.csr" -out "${root_dir}/root-cert.pem"
}

gen_intermediate() {
	local base=$1
	local ckey=$2
	local root_dir=${base}/cacerts/root
	local int_dir=${base}/cacerts/${ckey}
	mkdir -p "$int_dir"
	if [[ -f $int_dir/ca-key.pem && -f $int_dir/ca-cert.pem && $FORCE -eq 0 ]]; then
		dlog "intermediate for '$ckey': exists, skipping -> $int_dir"
		# still ensure cert-chain and root copy
		if [[ -f $root_dir/root-cert.pem ]]; then
			cat "$int_dir/ca-cert.pem" "$root_dir/root-cert.pem" >"$int_dir/cert-chain.pem" || true
			cp -f "$root_dir/root-cert.pem" "$int_dir/" 2>/dev/null || true
		fi
		return 0
	fi
	[[ -f $root_dir/root-cert.pem && -f $root_dir/root-key.pem ]] || die "root not found under $root_dir; run generate or place root-*.pem"
	dlog "intermediate: cluster '$ckey' -> $int_dir"
	openssl genrsa -out "${int_dir}/ca-key.pem" 4096
	write_intermediate_conf "${int_dir}/intermediate.conf" "$ckey"
	openssl req -new -config "${int_dir}/intermediate.conf" \
		-key "${int_dir}/ca-key.pem" -out "${int_dir}/cluster-ca.csr"
	openssl x509 -req -sha256 -days "$INT_DAYS" \
		-CA "${root_dir}/root-cert.pem" -CAkey "${root_dir}/root-key.pem" -CAcreateserial \
		-extensions req_ext -extfile "${int_dir}/intermediate.conf" \
		-in "${int_dir}/cluster-ca.csr" -out "${int_dir}/ca-cert.pem"
	cat "${int_dir}/ca-cert.pem" "${root_dir}/root-cert.pem" >"${int_dir}/cert-chain.pem"
	cp -f "${root_dir}/root-cert.pem" "${int_dir}/"
}

do_verify() {
	local base=$1
	shift
	local -a keys=("$@")
	local root=${base}/cacerts/root/root-cert.pem
	[[ -f $root ]] || die "missing root: $root"
	if [[ ${#keys[@]} -eq 0 ]]; then
		if [[ ! -d ${base}/cacerts ]]; then
			die "no ${base}/cacerts/; run generate first or pass --clusters"
		fi
		for d in "${base}/cacerts"/*; do
			[[ -d $d ]] || continue
			k=$(basename "$d")
			[[ $k == root ]] && continue
			keys+=("$k")
		done
		((${#keys[@]})) || die "no cluster dirs under ${base}/cacerts/ (expected one dir per cluster key plus root/)"
	fi
	for k in "${keys[@]}"; do
		local d=${base}/cacerts/$k
		[[ -f $d/ca-cert.pem && -f $d/cert-chain.pem ]] || die "cluster '$k' missing ca-cert or cert-chain in $d"
		openssl verify -CAfile "$root" "$d/ca-cert.pem" || die "verify failed: intermediate for $k"
		dlog "ok: intermediate '$k' verifies against root"
	done
}

# --- k8s apply ---

apply_one() {
	local ckey=$1
	local ctx=$2
	local base=$3
	local ns=$4
	local rep=$5
	local net=$6
	local dry=$7
	local d=${base}/cacerts/${ckey}
	for f in ca-cert.pem ca-key.pem root-cert.pem cert-chain.pem; do
		[[ -f $d/$f ]] || die "missing $d/$f (run generate first)"
	done
	local bin
	if command -v oc &>/dev/null; then
		bin=oc
	elif command -v kubectl &>/dev/null; then
		bin=kubectl
	else
		die "oc/kubectl not found"
	fi
	local -a a=("$bin" --context="$ctx")
	if [[ $dry == 1 ]]; then
		dlog "dry-run: $bin --context=$ctx create namespace $ns (ignore if exists)"
		dlog "dry-run: $bin --context=$ctx label namespace $ns topology.istio.io/network=$net --overwrite"
		[[ $rep == 1 ]] && dlog "dry-run: $bin --context=$ctx -n $ns delete secret cacerts (if exists)"
		dlog "dry-run: $bin --context=$ctx -n $ns create secret generic cacerts --from-file=... (4 files from $d)"
		return 0
	fi
	# shellcheck disable=SC2016
	"${a[@]}" create namespace "$ns" 2>/dev/null || true
	"${a[@]}" label namespace "$ns" "topology.istio.io/network=$net" --overwrite
	if [[ $rep == 1 ]]; then
		"${a[@]}" -n "$ns" delete secret cacerts 2>/dev/null || true
	fi
	"${a[@]}" -n "$ns" create secret generic cacerts \
		--from-file=ca-cert.pem="${d}/ca-cert.pem" \
		--from-file=ca-key.pem="${d}/ca-key.pem" \
		--from-file=root-cert.pem="${d}/root-cert.pem" \
		--from-file=cert-chain.pem="${d}/cert-chain.pem"
	dlog "applied cacerts to context '$ctx' namespace '$ns' (cluster key '$ckey')"
}

parse_context_map() {
	# BASH 4+ associative array: clusterkey -> context
	local s=$1
	IFS=',' read -r -a parts <<<"$s"
	for p in "${parts[@]}"; do
		[[ $p == *:* ]] || die "invalid --context-map entry (want key:context): $p"
		CK=${p%%:*}
		CX=${p#*:}
		[[ -n $CK && -n $CX ]] || die "empty key or context in: $p"
		CONTEXT_MAP["$CK"]=$CX
	done
}

# --- main ---

COMMAND=${1:-}
[[ -n $COMMAND ]] && shift

FORCE=0
BASE=$DEFAULT_BASE
CLUSTERS_CSV=""
NS=$DEFAULT_NS
REPLACE=0
DRY=0
CONTEXT_MAP_STR=""
NET_SUFFIX=network
declare -A CONTEXT_MAP=()

while [[ $# -gt 0 ]]; do
	case $1 in
	--base)
		BASE=$2
		shift 2
		;;
	--clusters)
		CLUSTERS_CSV=$2
		shift 2
		;;
	--force)
		FORCE=1
		shift
		;;
	--ns)
		NS=$2
		shift 2
		;;
	--replace)
		REPLACE=1
		shift
		;;
	--dry-run)
		DRY=1
		shift
		;;
	--context-map)
		CONTEXT_MAP_STR=$2
		shift 2
		;;
	--network-suffix)
		NET_SUFFIX=$2
		shift 2
		;;
	--mesh-ns)
		MESH_NS=$2
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1 (try: $PROG_NAME help)"
		;;
	esac
done

case $COMMAND in
help | -h | --help | "")
	usage
	exit 0
	;;
generate)
	[[ -n $CLUSTERS_CSV ]] || die "--clusters is required for generate"
	gen_root "$BASE"
	IFS=',' read -r -a CLIST <<<"$CLUSTERS_CSV"
	for c in "${CLIST[@]}"; do
		[[ -n $c ]] || continue
		gen_intermediate "$BASE" "$c"
	done
	dlog "done. PEMs under: $BASE/cacerts/ — next: $PROG_NAME verify; then $PROG_NAME apply --context-map '...'"
	;;
verify)
	if [[ -z ${CLUSTERS_CSV} ]]; then
		do_verify "$BASE"
	else
		IFS=',' read -r -a CLIST <<<"$CLUSTERS_CSV"
		do_verify "$BASE" "${CLIST[@]}"
	fi
	;;
apply)
	[[ -n $CONTEXT_MAP_STR ]] || die "apply needs --context-map 'cluster:ctx,...' matching --clusters keys and PEM dirs"
	parse_context_map "$CONTEXT_MAP_STR"
	((${#CONTEXT_MAP[@]})) || die "empty --context-map"
	for ck in "${!CONTEXT_MAP[@]}"; do
		cx=${CONTEXT_MAP[$ck]}
		net_name="${ck}-${NET_SUFFIX}"
		apply_one "$ck" "$cx" "$BASE" "$NS" "$REPLACE" "$net_name" "$DRY"
	done
	;;
esac
