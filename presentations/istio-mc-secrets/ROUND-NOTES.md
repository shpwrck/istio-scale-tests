# Round 4 — implementer notes

This file is overwritten each round. It documents any findings the implementer
genuinely disagreed with and skipped, so reviewers can re-raise or drop them
next round.

## R6 — `--c-secret` color choice

The R6 finding literally suggested `--c-secret: #047857` (emerald), but
`--c-workload` is already `#047857`. Adopting the literal value would have
created a new collision (workload boxes and Secret boxes drawn with the same
stroke colour, both appearing together on slide 9). The reviewer also stated
their intent: "distinct from all other palette colors."

To honor that stated intent I picked a colour that does not collide with any
other palette entry: `--c-secret: #a21caf` (fuchsia). It breaks the original
purple-on-purple problem with `--c-hub`, and is distinct from `--c-workload`
(emerald), `--c-eso` (dark teal), `--c-spoke-a` (teal), `--c-gateway` (rose),
and `--c-acm` (red). Reviewer can re-raise if they have a different colour
preference; the constraint set was tight.

No other findings were skipped.
