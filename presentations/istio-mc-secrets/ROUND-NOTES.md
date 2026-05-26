# Round 5 notes

Round-2 reviewer split: R2, R3, R4, R6, R8 APPROVED; R1, R5, R7 CHANGES.

This round applies the small, non-conflicting subset of those findings and
documents the deliberate declines.

## Applied

### R1 (Istio accuracy)
- `README.md:36` — Animation A row now says "...a cross-cluster mTLS call
  traversing the remote east-west gateway." (was "...traversing both
  gateways", which contradicted the slide text we corrected last round —
  only the remote EW gateway is in the data path; the local one only
  carries inbound traffic from other networks).

### R5 (pedagogy)
- `index.html` slide 7 speaker note — "on the next animation" was a stale
  forward reference: the next animation is istiod discovery (slide 9), not
  PushSecret (slide 10). Replaced with "on the PushSecret distribution
  slide (two slides on)".
- `index.html` slide 3 vocabulary speaker note (line 65) — dropped
  "cluster ID" from the promise of later inline glosses, because the term
  never actually appears anywhere downstream. Promise now reads "others
  (mesh ID, ManagedCluster, etc.)".
- `index.html` slide 4 speaker note — added a one-line gloss for `mesh ID`
  on its first use ("Istio's name for the mesh as a whole; one string
  shared by all member clusters"). Pedagogy-friendly resolution of the
  same R5 finding, paired with the cluster-ID cleanup above.

### R7 (minimalism, pure redundancy)
- `index.html` slide 7 diagram — removed the italic sub-label
  `(one Secret per spoke; root-cert.pem identical across spokes)` under
  the cacerts box. The intermediate Certificate box upstream already
  carries `(one per spoke)`, so the "one per spoke" half was pure repeat,
  and the "root-cert.pem identical across spokes" half is a detail the
  speaker can mention if asked (it's not load-bearing for the diagram).

## Declined (R7 minimalism vs. R5 pedagogy — kept R5)

R7 round-2 asked to cut seven additional inline glosses on the grounds of
minimalism. R5 explicitly *added* those same glosses in round 1 as
first-use definitions, and verified them in round 2. Cutting them would
regress R5's already-converged findings. Per the orchestrator's
conflict-resolution rule, R5 wins and these declines are documented here
so R7 can re-raise in a future round if they still apply.

- `index.html:335-339` — `ExternalSecret (a CR that templates one Secret
  from another)` on slide 7. **Decline.** Slide 7 is the first use of
  ExternalSecret in the deck; R5 round 1 specifically asked for a gloss
  here. The gloss sits inside an already-present sentence — it does not
  add a separate line.
- `index.html:529` — `SecretStore (auth target for ESO; kubernetes
  provider)`. **Decline.** First use of SecretStore. R5 round 1 asked
  for it; R5 round 2 verified it.
- `index.html:531` — `PushSecret (ship a hub Secret to a spoke)`.
  **Decline.** Same reasoning — first use; R5 wanted the gloss.
- `index.html:591-596` — cross-pollination callout box on the ESO
  PushSecret slide. **Decline.** R5 round 1 identified
  cross-pollination as the single most counter-intuitive idea in the
  deck and asked for it to have its own animation step. R5 round 2
  verified the step. Removing the callout would directly undo that.
- `index.html:691` — `(Placement = cluster selector; GitOpsCluster
  binds Argo CD to it)` on slide 11. **Decline.** Both terms are
  ACM-specific and unfamiliar to most Istio audiences; R5 wanted
  them glossed on first use.
- `index.html:670` — `ManagedServiceAccount (ACM CR — mints SA + token
  on spoke)`. **Decline.** First use; R5 wanted the gloss.
- `index.html:657` — `ManagedCluster (ACM CR — represents a spoke)`.
  **Decline.** First use; R5 wanted the gloss. (R5 round 1 named
  ManagedCluster explicitly as a term needing first-use definition.)

R7 may re-raise any of these in a later round with a fresh argument that
isn't "they are redundant" — the orchestrator can break the tie then.

## Invariants verified

- `grep -c '<section' presentations/istio-mc-secrets/index.html` = 13.
- Playwright headless load: no page errors, no console errors.
