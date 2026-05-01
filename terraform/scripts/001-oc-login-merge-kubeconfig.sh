#!/usr/bin/env bash
# Build a fresh kubeconfig by running oc login once per ROSA cluster from terraform/rosa-hcp outputs.
# Creates a new kubeconfig file, sets KUBECONFIG for all oc calls in this process, renames contexts to
# match terraform cluster_keys / cluster_name_format (e.g. rosa-001). Requires: terraform, jq, oc (run after terraform apply).
#
# Usage (repo root or any cwd):
#   ./terraform/scripts/001-oc-login-merge-kubeconfig.sh [--terraform-dir DIR] [--output FILE] [--insecure-skip-tls-verify] [--dry-run]
#
# After success, use the printed export line so your shell sees the same file:
#   export KUBECONFIG=/path/to/file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_DIR="${TF_DIR:-${REPO_ROOT}/terraform/rosa-hcp}"
OUT=""
INSECURE=0
DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  Reads terraform output from terraform/rosa-hcp (by_cluster, cluster_admin_login), creates a new
  kubeconfig file, and runs oc login --server / --username / --password per cluster.

Options:
  --terraform-dir DIR   Terraform root with state (default: ${REPO_ROOT}/terraform/rosa-hcp)
  --output FILE         Kubeconfig path (default: tempfile under \$TMPDIR)
  --insecure-skip-tls-verify   Pass through to oc login
  --dry-run             Print planned logins; do not write kubeconfig or call oc
  -h, --help            This help

Environment:
  TF_DIR                Same as --terraform-dir when set before invoking the script.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--terraform-dir)
		[[ -n "${2:-}" ]] || die "--terraform-dir requires a value"
		TF_DIR="$2"
		shift 2
		;;
	--output)
		[[ -n "${2:-}" ]] || die "--output requires a value"
		OUT="$2"
		shift 2
		;;
	--insecure-skip-tls-verify)
		INSECURE=1
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

command -v terraform >/dev/null 2>&1 || die "terraform not on PATH"
command -v jq >/dev/null 2>&1 || die "jq not on PATH"
command -v oc >/dev/null 2>&1 || die "oc not on PATH"
[[ -d "$TF_DIR" ]] || die "terraform dir not found: $TF_DIR"

raw="$(terraform -chdir="$TF_DIR" output -json)" || die "terraform output failed (init/apply this stack first?)"

by="$(echo "$raw" | jq -e '.by_cluster.value')" || die "missing by_cluster in terraform output"
login="$(echo "$raw" | jq -e '.cluster_admin_login.value')" || die "missing cluster_admin_login in terraform output"

user="$(echo "$login" | jq -r '.username // empty')"
pass="$(echo "$login" | jq -r '.password // empty')"
[[ -n "$user" && "$user" != "null" ]] || die "could not read cluster_admin username"
[[ -n "$pass" && "$pass" != "null" ]] || die "could not read cluster_admin password"

if [[ -z "$OUT" ]]; then
	if ((DRY_RUN)); then
		OUT="\${TMPDIR}/rosa-kubeconfig.XXXXXX (mktemp)"
	else
		OUT="$(mktemp "${TMPDIR:-/tmp}/rosa-kubeconfig.XXXXXX")"
	fi
else
	if ! ((DRY_RUN)); then
		: >"$OUT" || die "cannot write --output $OUT"
		chmod 600 "$OUT"
	fi
fi

if ((DRY_RUN)); then
	echo "dry-run: would write kubeconfig to: $OUT"
	echo "dry-run: would set KUBECONFIG to that path for oc login calls"
else
	export KUBECONFIG="$OUT"
fi

login_extra=()
((INSECURE)) && login_extra+=(--insecure-skip-tls-verify=true)

sorted_keys="$(echo "$by" | jq -r 'keys[]' | sort)"

while IFS= read -r key; do
	[[ -z "$key" ]] && continue
	server="$(echo "$by" | jq -r --arg k "$key" '.[$k].cluster_api_url // empty')"
	[[ -n "$server" && "$server" != "null" ]] || die "missing cluster_api_url for $key"

	if ((DRY_RUN)); then
		echo "dry-run: oc login --server=$server --username=$user --password='***' ${login_extra[*]:-}"
		continue
	fi

	if ! oc login --server="$server" -u "$user" -p "$pass" --kubeconfig="$KUBECONFIG" "${login_extra[@]}"; then
		die "oc login failed for context $key ($server)"
	fi

	new_ctx="$(oc config current-context --kubeconfig="$KUBECONFIG")"
	if [[ -n "$new_ctx" && "$new_ctx" != "$key" ]]; then
		if oc config get-contexts "$key" --kubeconfig="$KUBECONFIG" &>/dev/null; then
			oc config delete-context "$key" --kubeconfig="$KUBECONFIG" >/dev/null 2>&1 || true
		fi
		oc config rename-context "$new_ctx" "$key" --kubeconfig="$KUBECONFIG"
	fi
done <<<"$sorted_keys"

if ((DRY_RUN)); then
	exit 0
fi

first_ctx="$(echo "$sorted_keys" | head -1)"
[[ -n "$first_ctx" ]] || die "no clusters in by_cluster"
oc config use-context "$first_ctx" --kubeconfig="$KUBECONFIG"
chmod 600 "$KUBECONFIG"

echo >&2 ""
echo >&2 "Kubeconfig written to: $KUBECONFIG"
echo >&2 "Contexts:" >&2
oc config get-contexts --kubeconfig="$KUBECONFIG" >&2 || true
echo >&2 ""
echo >&2 "In this shell, run:"
echo >&2 "  export KUBECONFIG=$(printf '%q' "$KUBECONFIG")"
