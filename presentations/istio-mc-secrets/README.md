# Istio multicluster + cert-manager + ESO + ACM — presentation deck

A self-contained reveal.js deck that explains how the three Kubernetes Secrets
that make a multi-primary, multi-network Istio mesh work — `cacerts`, the
per-spoke kubeconfigs, and the Istio remote secrets — are produced and
distributed on this repository's hub-and-spoke topology.

Target length: ~20 minutes. Audience: Kubernetes / Helm / RBAC fluent
engineers new to Istio multicluster.

## View it

Everything is local — no CDN fetches.

```bash
# from anywhere
xdg-open presentations/istio-mc-secrets/index.html      # Linux
open     presentations/istio-mc-secrets/index.html      # macOS
```

Keyboard:

- `Space` / `&rarr;` — next step or slide
- `S` — open the speaker view (separate window, shows notes + timer)
- `F` — fullscreen
- `?` — full keybinding overlay

## Animations

Five hand-authored SVG animations. Each plays step-by-step as you press
`Space`, and collapses to its end state if the browser reports
`prefers-reduced-motion: reduce`.

| # | Slide title | What it shows |
| - | ----------- | ------------- |
| A | Topology: multi-primary, multi-network | Two clusters, each with istiod + workload + east-west gateway (`:15443 AUTO_PASSTHROUGH`), and a cross-cluster mTLS call traversing the remote east-west gateway. |
| B | cert-manager assembles `cacerts` | Hub root `Certificate` &rarr; `ClusterIssuer` &rarr; one intermediate `Certificate` per spoke &rarr; the four-key `cacerts` Secret (`ca-cert.pem`, `ca-key.pem`, `root-cert.pem`, `cert-chain.pem`) per cluster. |
| C | ESO `PushSecret`: hub &rarr; each spoke | Hub-side `SecretStore` + `PushSecret` CRs shipping `cacerts` and `istio-remote-secret-{cluster}` Secrets into each spoke's `istio-system`, applying `istio/multiCluster=true`. |
| D | How the remote secret drives discovery | istiod on cluster A reading the kubeconfig-shaped Secret in `istio-system`, watching cluster B's apiserver, and pushing cluster B endpoints into cluster A's sidecars via xDS. |
| E | ACM &rarr; ManagedServiceAccount &rarr; Argo &rarr; ESO &rarr; kubeconfig | `ManagedCluster` registration &rarr; ACM `ManagedServiceAccount` mints SA + token on the spoke and mirrors back to hub &rarr; `GitOpsCluster` + ACM `Placement` causes Argo CD to write `{cluster}-application-manager-cluster-secret` &rarr; ESO `ExternalSecret` templates `kubeconfig-{cluster}` on the hub. |

## Repository layout

```
presentations/istio-mc-secrets/
  index.html             # the deck
  README.md              # this file
  css/
    deck.css             # deck-local styles + visual language tokens
    step-controller.js   # tiny step-reveal helper for SVG diagrams (no animation libs)
  vendor/
    reveal.js/           # reveal.js 5.1.0, vendored. MIT licensed; see vendor/reveal.js/LICENSE
      dist/ plugin/notes/
```

reveal.js is pinned to 5.1.0. To upgrade, replace the contents of
`vendor/reveal.js/` from the upstream release tarball (`dist/` and
`plugin/notes/` are the only directories used).

## Accessibility

- WCAG AA contrast targeted on text (white-theme background, dark text/accents).
- All SVG diagrams carry `role="img"` and a descriptive `aria-label` summarizing the animation end state.
- `prefers-reduced-motion: reduce` collapses every animation to its final step on slide entry — no marching dashes, no SMIL motion.
- Reveal.js's built-in keyboard navigation and overview (`o`) are enabled.

## Conventions used in this deck

- Hand-authored SVG only. No PNG/JPG, no PDF.
- Animation via CSS transitions + SMIL `<animateMotion>`. No JS animation libraries.
- One Istio concept per color across all five diagrams (see CSS variables `--c-istiod`, `--c-workload`, `--c-gateway`, `--c-secret`, `--c-ca`, `--c-eso`, `--c-acm`, `--c-argo`).
- Placeholder names only — `cluster-a`, `cluster-b`, `hub`. No real cluster names or secret contents.
