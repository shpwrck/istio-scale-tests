# Scale-test campaign — architecture diagrams

These diagrams show the **shape** of the test bed: an ACM/GitOps hub (outside the mesh)
driving `N` spoke clusters joined into one multi-primary, multi-network Istio mesh
(`mesh1`), plus the per-spoke internals the five test suites measure.

The topology is identical at any size; only the spoke count and per-spoke workload change.
The diagrams below are parameterized for an illustrative **20-spoke × 500-services-per-spoke
(= 10,000 services)** run. The naming follows the repo convention — the hub is `cluster-1`
and the mesh members are `spoke-002 … spoke-021` (as in the `rosa-002…` contexts from the
2026-06-04 clean pass).

> These numbers are a parameterization, not a logged result. The recorded passes in
> [`docs/campaigns/`](../campaigns/) are the **10-spoke** clean pass (100 services) and the
> **500-spoke** target profile in [`README.md`](./README.md). Trust the *shapes* and
> *cross-cluster overheads*, not these absolute magnitudes.

## Overall architecture

```mermaid
graph TB
    subgraph HUB["cluster-1 — ACM/GitOps HUB (NOT a mesh member)"]
        ARGO["Argo CD<br/>app-of-apps + ApplicationSets"]
        ACM["ACM MultiClusterHub<br/>Placement to spoke selection"]
        CA["cert-manager<br/>root CA + ClusterIssuer<br/>+ per-cluster intermediates"]
        ESO["External Secrets Operator<br/>PushSecrets: cacerts / kubeconfig / remote-secrets"]
    end

    subgraph MESH["mesh1 — multi-primary, multi-network mesh (spoke-002 … spoke-021 = 20 spokes)"]
        direction LR
        subgraph S1["spoke-002 (network-2)"]
            D1["istiod (pinned K replicas)"]
            EW1["east-west-gw :15443"]
            IN1["ingress-gw"]
            W1["500 svc x N replicas<br/>(sidecar-injected)"]
        end
        subgraph S2["spoke-003 (network-3)"]
            D2["istiod"]
            EW2["east-west-gw :15443"]
            IN2["ingress-gw"]
            W2["500 svc x N replicas"]
        end
        DOTS["· · ·<br/>spoke-004 … spoke-020<br/>(16 more identical spokes)"]
        subgraph SN["spoke-021 (network-21)"]
            DN["istiod"]
            EWN["east-west-gw :15443"]
            INN["ingress-gw"]
            WN["500 svc x N replicas"]
        end
    end

    ARGO -->|"GitOps sync waves 8 to 30<br/>(Sail op, Istio CRs, gateways)"| MESH
    ACM -->|"label istio-mesh-member=true"| MESH
    CA -.->|"plug-in CA trust"| MESH
    ESO -->|"push cacerts + remote secrets<br/>(quadratic fan-out)"| MESH

    EW1 <-->|"cross-network mTLS<br/>xDS / EDS endpoints"| EW2
    EW2 <--> DOTS
    DOTS <--> EWN
    EW1 <-->|"full east-west mesh<br/>(every spoke ↔ every spoke)"| EWN

    classDef hub fill:#e8f0fe,stroke:#4285f4,color:#000;
    classDef spoke fill:#e6f4ea,stroke:#34a853,color:#000;
    classDef dots fill:#fff,stroke:#999,stroke-dasharray:5 5,color:#555;
    class HUB,ARGO,ACM,CA,ESO hub;
    class S1,S2,SN,D1,D2,DN,EW1,EW2,EWN,IN1,IN2,INN,W1,W2,WN spoke;
    class DOTS dots;
```

- The **hub** (`cluster-1`) is GitOps/ACM control infrastructure only — never labeled
  `istio-mesh-member=true`, never a mesh member.
- Each **spoke** is its own network with its own istiod (multi-primary), an east-west
  gateway (`:15443`, or nodePort `31443`), an ingress gateway, and its sidecar-injected
  workload.
- **East-west is full mesh** — every spoke reaches every other spoke's east-west gateway.
  The chain is drawn through the `· · ·` continuation node to imply all 20 spokes.

## Per-spoke internals + test harness

```mermaid
graph LR
    subgraph SPOKE["each spoke cluster (spoke-002 … spoke-021, x20)"]
        ISTIOD["istiod<br/>autoscale OFF, replicas pinned<br/>multi-primary control plane"]
        SIDE["workload pods<br/>500 Services<br/>Envoy sidecar each"]
        EWG["east-west gateway<br/>:15443 / nodePort 31443<br/>cross-network entry"]
        ISTIOD -->|"xDS push (LDS/CDS/EDS/RDS)"| SIDE
        ISTIOD -->|"local + remote endpoints"| EWG
    end

    subgraph PROBES["test harness (run serially)"]
        P1["propagation - xDS latency"]
        P2["churn - convergence under churn"]
        P3["controlplane - istiod CPU/mem vs mesh size"]
        P4["dataplane - cross-cluster latency/QPS"]
        P5["churn-dataplane - p99 delta under churn"]
    end

    REMOTE["remote secrets<br/>istio/multiCluster=true"] -->|"discover peer endpoints"| ISTIOD
    PROBES -.->|"scrape /metrics, drive load"| ISTIOD
    P4 -.->|"traffic via"| EWG
```

- istiod (autoscale off, pinned replica count — required for measurement fidelity) pushes
  xDS to the local sidecars and programs the east-west gateway with local + remote endpoints.
- Remote secrets (`istio/multiCluster=true`) give istiod its view of peer-cluster endpoints.
- The five suites run **serially** against the same istiod (concurrent runs contaminate each
  other's xDS counters/histograms/CPU), scraping `/metrics` and driving load through the
  east-west gateway.

> Source for these diagrams is inline above — GitHub renders the ` ```mermaid ` blocks
> natively. To regenerate PNGs locally: `mmdc -i <file>.mmd -o <file>.png -b white`.
