# kind lab: the mesh on one machine

A hub and two mesh members as three kind clusters on one Linux host, deployed by
`terraform/platform` the same way as on any other Kubernetes clusters. Use it to try the repo,
smoke-run the suites and develop the charts. Don't publish its numbers: the three clusters share
one host's CPUs and network, so latencies and convergence times describe the host more than Istio.
Capacity and headroom figures are void too (every node reports the whole host, which the three
clusters share), and so are remote-path latencies and the remote-minus-local delta: both gateways
sit behind cloud-provider-kind's load balancer (`ipMode: Proxy` on the Services), a userspace Envoy
on the same shared host, where a cloud load balancer is a hop on infrastructure of its own.

Last run end to end on 2026-10-18 with kind v0.33.0 (node image `kindest/node:v1.34.11`),
cloud-provider-kind v0.12.0, Argo CD v3.5.3 and Istio v1.30.5 through the Sail operator 1.31.1:
every Application Synced/Healthy, both wiring gates `Ready ... ca=shared`, mesh-verify answering
from both members, the propagation and dataplane suites' setup, probe, report and cleanup, and the
one-off Gateway API check (all 22 predictions matched).

## What you need

- A Linux host with Docker, at least 4 CPUs, about 12 GiB of free memory and 15 GB of free disk.
  At rest the hub uses about 2.8 GiB of memory and each member about 1.8 GiB; during suite runs
  the three nodes used about 7.3 GiB and their volumes 7.4 GB.
- `kind` v0.33.0, [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind)
  v0.12.0, and the tools in [What you need](../../../README.md#what-you-need). On linux/amd64:

  ```bash
  curl -fsSLo kind https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64
  echo "aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d  kind" | sha256sum -c
  curl -fsSLO https://github.com/kubernetes-sigs/cloud-provider-kind/releases/download/v0.12.0/cloud-provider-kind_0.12.0_linux_amd64.tar.gz
  echo "5716aca8f01a85172c12f3b6329c70f151bec02c91b6f600c9f230845ee138e6  cloud-provider-kind_0.12.0_linux_amd64.tar.gz" | sha256sum -c
  tar -xzf cloud-provider-kind_0.12.0_linux_amd64.tar.gz cloud-provider-kind
  chmod +x kind cloud-provider-kind && sudo mv kind cloud-provider-kind /usr/local/bin/
  ```
- Internet access from the host and from the kind nodes: GitHub, the chart repos (Argo CD,
  cert-manager, External Secrets, the Sail operator) and the image registries (Docker Hub,
  quay.io, ghcr.io, registry.k8s.io).
- A git repo the hub's Argo CD can pull: this repo or your fork, with the branch you deploy pushed.

macOS and Windows (Docker Desktop) are untested. The clusters reach each other on the Docker
network either way, but the host may not reach the LoadBalancer addresses there.

## 1. Host settings

Three clusters' kubelets and proxies exceed the default inotify limits, and pods then fail with
"too many open files":

```bash
sudo sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=1048576
```

Put the same two keys in a file under `/etc/sysctl.d/` to keep them across reboots.

## 2. Clusters

```bash
# kind v0.33.0's v1.34 node image, pinned by digest.
NODE_IMAGE=kindest/node:v1.34.11@sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d
for c in hub mesh-1 mesh-2; do
  kind create cluster --name "$c" --image "$NODE_IMAGE" --wait 180s
done
kubectl config get-contexts   # kind-hub, kind-mesh-1, kind-mesh-2
```

kind adds the contexts to `~/.kube/config` (or the file `$KUBECONFIG` names). Their names are DNS
labels, as `terraform/platform` requires.

## 3. LoadBalancers and the Gateway API CRDs

In a second terminal, start cloud-provider-kind and leave it running while you use the lab:

```bash
cloud-provider-kind
```

It gives every `type: LoadBalancer` Service (the ingress and east-west gateways) an address on the
kind Docker network, and installs the Gateway API CRDs (v1.6.1, standard channel) in every kind
cluster, which the gateway-api check needs.

On a host kernel without IPv6 (no `/proc/sys/net/ipv6`) its load balancers never become ready,
because their Envoy's admin port listens on `::`. Enable IPv6 on the host, or build
cloud-provider-kind with that listener on IPv4 (the lab's host had no IPv6 and ran this build):

```bash
git clone --depth 1 --branch v0.12.0 https://github.com/kubernetes-sigs/cloud-provider-kind
cd cloud-provider-kind
sed -i -e 's/address: "::"/address: "0.0.0.0"/' -e '/ipv4_compat: true/d' pkg/loadbalancer/proxy.go
make build   # bin/cloud-provider-kind
```

## 4. Deploy

In `terraform/platform`, write `terraform.tfvars`:

```hcl
platform         = "kubernetes"
cluster_provider = "kubeconfig"
kubeconfig_path  = "~/.kube/config"   # the file kind wrote the contexts to (step 2)

hub_cluster_context    = "kind-hub"
spoke_cluster_contexts = ["kind-mesh-1", "kind-mesh-2"]

# kind writes https://127.0.0.1:<port>, which works only from the host. The hub's pods and the
# other member's istiod reach a member by its node container name on the kind Docker network.
# The hub needs no entry: in kubeconfig mode nothing reads the hub's URL.
cluster_api_url_overrides = {
  "kind-mesh-1" = "https://mesh-1-control-plane:6443"
  "kind-mesh-2" = "https://mesh-2-control-plane:6443"
}

gitops_app_repo_url      = "https://github.com/<org>/istio-scale-tests.git"
gitops_app_repo_revision = "<commit>"   # the commit under test: a branch can move under the lab

# Small requests: one host runs all three clusters (the chart defaults are sized for 20).
argocd_helm_values = {
  controller     = { resources = { requests = { cpu = "200m", memory = "512Mi" }, limits = { cpu = "2", memory = "2Gi" } } }
  repoServer     = { replicas = 1, resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "1", memory = "1Gi" } } }
  server         = { resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { cpu = "1", memory = "512Mi" } } }
  applicationSet = { resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { cpu = "1", memory = "512Mi" } } }
}
gitops_app_overrides = {
  "spoke-ossm-appset" = {
    values = { template = { source = { helm = { valuesObject = {
      pilot = {
        replicaCount = 1
        resources    = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "2", memory = "1Gi" } }
      }
    } } } } }
  }
}
```

Then:

```bash
terraform init
terraform plan -out=platform.tfplan
terraform apply platform.tfplan
```

The apply installs Argo CD on the hub, registers both members and starts the app-of-apps, then
waits until each member has Applications. Argo CD rolls out the rest. In the lab every Application
was Synced/Healthy about 10 minutes after the apply:

```bash
kubectl --context kind-hub -n argocd get applications.argoproj.io
```

## 5. Verify

```bash
for m in kind-mesh-1 kind-mesh-2; do
  kubectl --context "$m" exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- sh /opt/check/readiness.sh
done
# Ready: secrets=2 istiod_managed=2 (local=1 remote=1) expected=2 members=kind-mesh-1,kind-mesh-2 ca=shared synced=1 replicas=1 root=<fingerprint> eastwest=<address>
```

`root=` must read the same on both members; `replicas=1` is the lab's one istiod replica; `members=`
lists both members, which each gate checks by name.

Then run the preflight ([Check the mesh](../../../README.md#2-check-the-mesh)) with the end to end
echo check; answers come from both members. The ingress address is on the kind Docker network,
which a Linux host reaches directly.

```bash
tests/preflight/001-check-mesh.sh --contexts kind-mesh-1,kind-mesh-2 --hub-context kind-hub --echo
```

## 6. Smoke-run a suite

From the repo root (`config/versions.env` defaults to other context names):

```bash
export SETUP_CONTEXTS=kind-mesh-1,kind-mesh-2
tests/propagation/001-setup-propagation-test.sh --contexts kind-mesh-1,kind-mesh-2 --watcher-replicas 2
tests/propagation/002-run-endpoint-probe.sh --source-context kind-mesh-1 --remote-contexts kind-mesh-2 --iterations 2 --tsv
tests/propagation/005-report-results.sh --format markdown
tests/propagation/007-cleanup.sh --contexts kind-mesh-1,kind-mesh-2
```

The other suites run the same way: the "Quick start" in each suite's README lists its steps
(tuning: "Run a sweep"; the one-off Gateway API check: "Deploy" and "Run"). Keep runs small: a sweep sized for the
20-cluster campaign does not fit on one host.

Expect kind warnings in the reports; they describe the lab, not a failed run. The controlplane
report flags its capacity figures (each kind node reports the whole host) and its SLA verdict
leaves the node figures out, so that verdict, in the report and in the scale envelope a
controlplane sweep writes, reads `CAUTION` at best, never `PASS`. The dataplane and
churn-dataplane reports flag their remote latency: the cross-cluster path runs through
cloud-provider-kind's userspace Envoy on the shared host.

kind has no metrics API, so the controlplane report's four utilization-% columns
(`istiod_*_pct_of_limit`, `node_*_pct`) read `N/A` and its memory guard reads the gateways' memory
from Envoy's own stats instead of `kubectl top`; the rest of the run is unaffected. To fill them,
install [metrics-server](https://github.com/kubernetes-sigs/metrics-server) on each member with
`--kubelet-insecure-tls`, because kind's kubelets serve self-signed certificates:

```bash
for m in kind-mesh-1 kind-mesh-2; do
  kubectl --context "$m" apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml
  kubectl --context "$m" -n kube-system patch deployment metrics-server --type=json \
    -p '[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
done
```

`node_*_pct` stays void on kind (each node reports the whole host). In the lab metrics-server
scraped the kubelets this way, but the metrics API stayed unavailable behind the lab host's HTTPS
proxy, so `kubectl top` on kind is untested.

## 7. Tear down

```bash
terraform destroy   # in terraform/platform
kind delete clusters hub mesh-1 mesh-2
```

Then stop cloud-provider-kind (Ctrl-C). `docker ps -a --filter name=kindccm` lists any load
balancer container it left behind; remove those with `docker rm -f`.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Pods crash with `too many open files` | The inotify limits are too low (step 1). |
| An operator Application (External Secrets, the Sail operator) stays `Progressing` after it synced | Argo CD's health of the operator's new CRDs is catching up. It cleared by itself within about 10 minutes in the lab. |
| Gateway Services stay `<pending>` | cloud-provider-kind is not running (step 3). If it runs and logs `SyncLoadBalancerFailed` with `connection reset by peer` on the load balancer's readiness, the host kernel has no IPv6: build it with the IPv4 admin listener (step 3). |
| The apply fails: `Argo CD on the hub cannot load state from these clusters`, quoting `https://127.0.0.1:<port>` | That member has no `cluster_api_url_overrides` entry (step 4), so it is registered at the host's loopback, which the hub's pods cannot reach. Add `https://<cluster>-control-plane:6443` for it and apply again. |
| Image pulls fail with `429 Too Many Requests` | Docker Hub's anonymous pull limit: each cluster pulls its own images. Pull an image once on the host and copy it in with `kind load docker-image <image> --name <cluster>`, or point the nodes' containerd at a mirror (kind's `containerdConfigPatches`). |
| `kind create cluster` fails to start containers, with `oom_score_adj` errors in the kubelet log | The host is itself a restricted container. Create the clusters with a kind config whose `containerdConfigPatches` sets `restrict_oom_score_adj = true` under `[plugins."io.containerd.grpc.v1.cri"]`. |
| An Application shows a ComparisonError about the repo | The hub's Argo CD cannot pull `gitops_app_repo_url` at `gitops_app_repo_revision`: check the URL and that the branch is pushed. |
