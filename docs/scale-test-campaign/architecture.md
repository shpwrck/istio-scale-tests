# Scale-test campaign — architecture diagrams

These diagrams show the **shape** of the test bed: an ACM/GitOps hub (outside the mesh)
driving `N` spoke clusters joined into one multi-primary, multi-network Istio mesh
(`mesh1`). The high-level topology is here; each measurement suite's own harness diagram
lives in its `tests/<suite>/README.md` (linked under [Per-suite diagrams](#per-suite-test-harness-diagrams)).

The topology is identical at any size; only the spoke count and per-spoke workload change.
The diagrams below are parameterized for an illustrative **20-spoke × 500-services-per-spoke
(= 10,000 services)** run. The naming follows the repo convention — the hub is `cluster-1`
and the mesh members are `spoke-002 … spoke-021` (as in the `rosa-002…` contexts from the
2026-06-04 clean pass).

> These numbers are a parameterization, not a logged result. The recorded passes in
> [`docs/campaigns/`](../campaigns/) are the **10-spoke** clean pass (100 services) and the
> **500-spoke** target profile in [`README.md`](./README.md). Trust the *shapes* and
> *cross-cluster overheads*, not these absolute magnitudes.

## Diagram conventions

Every diagram in this campaign — the topology below **and** the per-suite harness diagrams
in each `tests/<suite>/README.md` — uses this one legend. Arrow styles and box colors always
mean the same thing regardless of which suite they appear in (e.g. a namespace is always a
red box), so the diagrams read as one consistent system.

```mermaid
graph TB
    subgraph ARROWS["arrows — how to read the lines"]
        direction LR
        a1(( )) -->|"primary flow — config / request propagation the test exercises"| a2(( ))
        b1(( )) -.->|"observation or setup — scrape / poll, deploy, trust bootstrap"| b2(( ))
        c1(( )) ==>|"recorded output — edge into the results node"| c2(( ))
        d1(( )) <-->|"bidirectional peer link — full mesh / cross-network mTLS"| d2(( ))
    end

    subgraph BOXES["boxes — what each color means"]
        direction LR
        k0["mesh<br/>(logical boundary)"]
        k1["cluster / spoke"]
        k2["namespace"]
        k3["control plane<br/>(istiod)"]
        k4["data plane<br/>(workloads · sidecars · gateways)"]
        k5["test harness<br/>(driver · probe · operator)"]
        k6["recorded output"]
    end

    classDef mesh fill:#ffffff,stroke:#5c6bc0,stroke-width:2px,stroke-dasharray:6 5,color:#000;
    classDef cluster fill:#eceff1,stroke:#90a4ae,color:#000;
    classDef namespace fill:#ffebee,stroke:#e53935,color:#000;
    classDef controlplane fill:#e3f2fd,stroke:#1e88e5,color:#000;
    classDef dataplane fill:#e8f5e9,stroke:#43a047,color:#000;
    classDef harness fill:#f3e5f5,stroke:#8e24aa,color:#000;
    classDef output fill:#fff8e1,stroke:#f9a825,color:#000;
    classDef dot fill:#555,stroke:#555,color:#fff;
    class a1,a2,b1,b2,c1,c2,d1,d2 dot;
    class k0 mesh;
    class k1 cluster;
    class k2 namespace;
    class k3 controlplane;
    class k4 dataplane;
    class k5 harness;
    class k6 output;
```

- **Arrows** — solid = primary flow (config / request propagation the test exercises);
  dotted = observation or setup (scrape / poll, deploy, trust bootstrap); bold = recorded
  output (edge into a results node); double-headed = bidirectional peer link (full mesh /
  cross-network mTLS).
- **Box colors** — dashed indigo = mesh (logical boundary); gray = cluster / spoke; red =
  namespace; blue = control plane (istiod); green = data plane (workloads / sidecars /
  gateways); purple = test harness (driver / probe / operator); amber = recorded output.

## Overall architecture

```mermaid
graph TB
    subgraph HUB["cluster-1 — ACM/GitOps HUB (NOT a mesh member)"]
        ARGO["Argo CD<br/>app-of-apps + ApplicationSets"]
        ACM["ACM MultiClusterHub<br/>Placement to spoke selection"]
        CA["cert-manager<br/>root CA + ClusterIssuer<br/>+ per-cluster intermediates"]
        ESO["External Secrets Operator<br/>PushSecrets: cacerts / kubeconfig / remote-secrets"]
    end

    subgraph MESH["mesh1 — multi-primary, multi-network · 20 identical spokes (spoke-002 … spoke-021)"]
        direction LR
        subgraph SREP["representative spoke — every spoke is identical (x20)"]
            direction TB
            subgraph NSIS["namespace: istio-system"]
                subgraph PILOT["istiod — 3 replicas (Guaranteed QoS)"]
                    D1["istiod-1"]
                    D2["istiod-2"]
                    D3["istiod-3"]
                end
                EW["east-west-gw<br/>:15443 / nodePort 31443"]
                IN["ingress-gw"]
            end
            subgraph NSWL["workload namespaces"]
                W["five per-suite namespaces:<br/>controlplane-test · dataplane-test · churn-test<br/>churn-dataplane-test · propagation-test<br/>— — —<br/>500 Services x 1 endpoint · Envoy sidecar each"]
                MV["mesh-verify · standalone cross-cluster<br/>wiring / echo probe (own ApplicationSet, not a suite)"]
            end
        end
        OTHERS["spoke-003 … spoke-021<br/>19 more identical spokes"]
    end

    ARGO -.->|"GitOps sync (Sail op, Istio CRs, gateways)"| MESH
    ACM -.->|"label istio-mesh-member=true"| MESH
    CA -.->|"plug-in CA trust"| MESH
    ESO -.->|"push cacerts + remote secrets"| MESH

    EW <-->|"full east-west mesh<br/>every spoke ↔ every other"| OTHERS

    classDef mesh fill:#ffffff,stroke:#5c6bc0,stroke-width:2px,stroke-dasharray:6 5,color:#000;
    classDef cluster fill:#eceff1,stroke:#90a4ae,color:#000;
    classDef namespace fill:#ffebee,stroke:#e53935,color:#000;
    classDef controlplane fill:#e3f2fd,stroke:#1e88e5,color:#000;
    classDef dataplane fill:#e8f5e9,stroke:#43a047,color:#000;
    classDef harness fill:#f3e5f5,stroke:#8e24aa,color:#000;
    classDef output fill:#fff8e1,stroke:#f9a825,color:#000;
    class MESH mesh;
    class HUB,SREP,OTHERS cluster;
    class ARGO,ACM,CA,ESO harness;
    class NSIS,NSWL namespace;
    class PILOT,D1,D2,D3 controlplane;
    class EW,IN,W,MV dataplane;
```

- The **hub** (`cluster-1`) is GitOps/ACM control infrastructure only — never labeled
  `istio-mesh-member=true`, never a mesh member.
- Every spoke is identical, so only one is drawn in full: **istiod at 3 replicas** plus the
  east-west and ingress gateways in `istio-system`, and its workloads in per-suite namespaces
  (`controlplane-test`, `dataplane-test`, …). `mesh-verify` is a standalone cross-cluster
  wiring / echo probe with its own ApplicationSet — **not** one of the five suites.
- **East-west is full mesh** — every spoke reaches every other spoke's east-west gateway
  (the one labeled edge stands in for all 20 × 19 cross-network paths).

## Per-suite test-harness diagrams

Each suite's measurement mechanism is drawn in its own README, using the same
[legend](#diagram-conventions) as above:

- **Control-plane** — istiod CPU/mem/xDS vs mesh size, 3-phase delta window —
  [`tests/controlplane/README.md`](../../tests/controlplane/README.md#architecture)
- **Data-plane** — cross-cluster latency/QPS through the east-west gateways —
  [`tests/dataplane/README.md`](../../tests/dataplane/README.md#architecture)
- **Propagation** — config-change freshness (P1 → P2 → P3) —
  [`tests/propagation/README.md`](../../tests/propagation/README.md#architecture)
- **Churn** — control-plane convergence + push amplification under endpoint churn —
  [`tests/churn/README.md`](../../tests/churn/README.md#architecture)
- **Churn × data-plane** — p99 degradation while istiod is busy with churn —
  [`tests/churn-dataplane/README.md`](../../tests/churn-dataplane/README.md#architecture)

> Source for every diagram is the inline ` ```mermaid ` block — GitHub renders them
> natively. To rasterize one, copy its block into a `<name>.mmd` file and run
> `mmdc -i <name>.mmd -o <name>.png -b white`.
