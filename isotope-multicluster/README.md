# Multicluster isotope (istio/tools)

This directory wires **[istio/tools isotope](https://github.com/istio/tools/tree/master/isotope)** into the same **multi-primary, multi-network** clusters you bring up with `istio-setup/` (see repo root **README.md** and **[OSSM 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)**).

Upstream describes the pattern in `isotope/example-topologies/chain-2-services-different-cluster.yaml` and `isotope/convert/README.md`: each **logical** cluster name in the topology is rendered separately with `convert kubernetes ... --cluster <name>`, then applied to the matching kube context.

## Prerequisites

- Mesh installed through **`istio-setup/004`–`008`** (or equivalent): remote secrets and east–west gateways so services resolve across clusters.
- **Multicluster DNS** for the stub domain used in the graph (`b.global` in the sample). Without it, calls from `a` to `b` will not resolve. Align stub domains with your Istio/OSSM multicluster install (`.global` is the common Istio multicluster pattern).
- **Go** on `PATH` and a local clone of **[istio/tools](https://github.com/istio/tools)**.
- An **isotope service image** built from `istio/tools/isotope/service` (for example via `ko`) — there is no universal public pin in-tree; set `ISOTOPE_SERVICE_IMAGE` or `--service-image`.

## Topology

`topology/service-graph-multicluster.yaml` places:

- Service **`a`** (entrypoint) on logical **`cluster1`**, namespace **`demo1`**.
- Service **`b`** on logical **`cluster2`**, namespace **`demo2`**.
- **`a`** calls **`b`** using **`hostname: b.global:8080`** (cross-cluster).

Adjust namespaces, logical cluster names, or hostnames to match your mesh DNS and naming.

### Topology from Terraform (`cluster_keys`)

When clusters come from **`terraform/rosa-hcp`**, use the same names as Terraform **`cluster_keys`** (from **`cluster_name_format`**, e.g. **`rosa-001`**) for your kubectl/oc contexts. **`001-generate-topology-from-terraform.sh`** reads **`terraform output cluster_keys`** and writes a **chain** graph **`svc0 → svc1 → … → svc{N-1}`**, placing one hop on each cluster in that order (cross-cluster calls use **`svcK.global:8080`**). Single-cluster stacks get one entrypoint service only.

From the **repository root** (after **`terraform apply`** in the stack):

```bash
./isotope-multicluster/001-generate-topology-from-terraform.sh \
  -o isotope-multicluster/topology/generated-from-terraform.yaml --print-env

# --print-env writes ISOTOPE_* exports to stderr — capture if wanted:
# ./isotope-multicluster/001-generate-topology-from-terraform.sh --print-env 2> /tmp/isotope-env.sh
# source /tmp/isotope-env.sh

./isotope-multicluster/002-apply-isotope-multicluster.sh \
  --topology isotope-multicluster/topology/generated-from-terraform.yaml \
  --logical-clusters "$(terraform -chdir=terraform/rosa-hcp output -json cluster_keys | jq -r '(if type == "array" then . elif .value then .value else empty end) | join(",")')" \
  --uniform-namespace isotope \
  --service-image "$ISOTOPE_SERVICE_IMAGE" \
  --tools-root "$ISOTOPE_TOOLS_ROOT"
```

**`--uniform-namespace`** avoids hand-building **`ISOTOPE_NAMESPACE_MAP`** when every logical cluster uses the same namespace (the generator defaults to namespace **`isotope`**).

Requires **`terraform`** and **`jq`** on `PATH`. Override the stack with **`--terraform-dir`**. **`--stdout-only`** prints YAML to stdout instead of writing the default **`topology/generated-from-terraform.yaml`** (gitignored).

Keep **`SETUP_CONTEXTS`** in **`config/versions.env`** aligned with **`cluster_keys`** order when relying on default **`--contexts`** (first **N** contexts must match the **N** terraform keys).

## Render and apply

From the **repository root**, after choosing two contexts that correspond to `cluster1` and `cluster2` (defaults: first two entries in **`SETUP_CONTEXTS`** from `config/versions.env`):

```bash
export ISOTOPE_TOOLS_ROOT="$HOME/src/tools"   # your istio/tools clone
export ISOTOPE_SERVICE_IMAGE="your-registry/isotope-service:tag"

./isotope-multicluster/002-apply-isotope-multicluster.sh --dry-run
./isotope-multicluster/002-apply-isotope-multicluster.sh
```

Use **`--contexts`** when **`SETUP_CONTEXTS`** order or length does not match your topology (required when using the Terraform generator if **`SETUP_CONTEXTS`** lists more clusters than **`cluster_keys`**). **`--uniform-namespace`** builds **`cluster:namespace`** pairs from **`--logical-clusters`**. **`--render-only`** writes YAML under **`isotope-multicluster/gen/`** without applying; **`--apply-only`** reapplies existing files there.

Enable **sidecar injection** (or your revision label) on **`demo1`** / **`demo2`** per OSSM/Sail instructions.

The script renders **Fortio** only for the **first** logical cluster (`cluster1`); other clusters use **`--client-disabled`** so you do not duplicate the client.

## Generated files

Rendered manifests are written to **`isotope-multicluster/gen/`** (ignored by git). Do not commit kube secrets or environment-specific output.

## References

- [istio/tools — isotope README](https://github.com/istio/tools/blob/master/isotope/README.md)
- [istio/tools — convert README (multicluster example)](https://github.com/istio/tools/blob/master/isotope/convert/README.md)
