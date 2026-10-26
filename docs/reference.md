# Reference: what a run records and how it behaves

The rules every suite shares. Start with the [README](../README.md) and
[Reading results](reading-results.md); come here when a report, a preamble key or a sweep's exit
code needs explaining.

## What every result records

Every TSV preamble has these keys, and each suite's report repeats them, merged over its inputs
(tuning 004 compares them pass by pass):

| Key | What it means | Where it comes from |
| --- | --- | --- |
| `HARNESS_SHA` | The harness that wrote the result: `git describe --always --abbrev=7`, plus `-dirty.<8hex>` when git lists a changed tracked file, or an untracked file it does not ignore, under `tests/`, `config/`, `charts/` or `terraform/` (a run's own results never count; `tests/<suite>/configs/*.local.env` is ignored); the hex hashes the diff against `HEAD` and those untracked files' names and contents, so two different edits read as two harnesses | `harness_sha`, [tests/lib/common.sh](../tests/lib/common.sh) |
| `RUN_CONFIG`, `RUN_CONFIG_SHA256` | The `--config` file (its path from the repo root, or only its name outside the repo) and its SHA-256; `none` without one | `config_preamble_lines`, [tests/lib/config.sh](../tests/lib/config.sh) |
| `ISTIO_VERSION`, `ISTIO_VERSION_PIN`, `ISTIO_VERSION_SOURCE` | The version the members run ([below](#the-istio-version-check)), the pin (`ISTIO_VERSION` in `config/versions.env`), and `live`, or `pin` in a `--dry-run`, which reads nothing | `istio_version_kv`, [tests/lib/preamble.sh](../tests/lib/preamble.sh) |
| `ISTIO_VERSION_BY_CONTEXT`, `ISTIO_ACTIVE_REVISIONS`, `ISTIO_GENERATIONS` | Per member: its version, its active IstioRevision, and its Istio CR and IstioRevision generations (`<ctx>=<cr>/<revision>`); `unchecked` when not read live | `istio_version_kv` |
| `KUBE_VERSIONS` | Each member's Kubernetes server version (`unreachable` when it did not answer); the placeholder a propagation or dataplane sweep writes for a failed mesh size leaves it out | `probe_kube_versions`, `tests/lib/preamble.sh` |
| `TUNING_BASELINE`, `SIDECAR_EGRESS_HOSTS` | The baseline's tuning levers on the source member (`sidecar`, `discoverySelectors`, `telemetryFiltering`, `accessLogFiltering`, each `on` or `off`) and the root Sidecar's egress hosts (`none` without one); gateway-api records them per member (`TUNING_BASELINE[<ctx>]`) | `tuning_baseline_state`, `tests/lib/preamble.sh` |
| `PLATFORM`, `TEST_PLATFORM`, `PLATFORM_BY_CONTEXT` | `kubernetes` or `openshift` over the members (`mixed` when they run both); the override as set (`auto`, `kubernetes` or `openshift`); what each member serves, asked even with an override | `platform_preamble_lines`, [tests/lib/platform.sh](../tests/lib/platform.sh) |
| `MESH_OPERATOR_BY_CONTEXT` | `sail-operator:<tag>@<digest>` (the digest its pods run) or, on OpenShift, `servicemeshoperator3:<version>` (its CSV); `absent` when the member runs none | `platform_preamble_lines` |
| `ISTIOD_IMAGE_BY_CONTEXT`, `PROXY_IMAGE_BY_CONTEXT` | The image and digest that istiod's `discovery` container, and the ingress and east-west gateways' `istio-proxy`, ran; `none` without such a pod. The test pods' sidecars get the injector's build, which can be newer than a gateway not restarted since an upgrade | `platform_preamble_lines` |
| `ISTIOD_ENV_BY_CONTEXT` | A 12-hex digest of istiod's `discovery` env without `CLUSTER_ID`, the one variable that differs by member: a tuning profile's `spec.values.pilot.env` or a hand edit changes it | `platform_preamble_lines` |
| `NODE_PROVIDER_BY_CONTEXT` | The nodes' `spec.providerID` scheme (`kind`, `aws`, ...; nodes without one beside a provider's count as that provider's); `none`: no node has one; `no-nodes`; `unrecognized`: not `<scheme>://` | `platform_preamble_lines` |

`unknown` means not read (a failed read, which warns; a file from before the key), never none or
off; an image whose pods have not started (Pending, an operator scaled to 0) reads
`<image>@unknown`, not read either; several values on one member are `+`-joined (a rollout; a pod
already terminating counts only when no other ran). Where a report's inputs disagree, a key reads
`mixed:<a>,<b>` (per member `<ctx>=mixed:<a>;<b>`; `mixed:unknown,...` when only some inputs carry
it), with a warning in the report's body. An older harness wrote `MESH_OPERATOR_BY_CONTEXT` with a
readiness suffix (such as `/Available`) and `NODE_PROVIDER_BY_CONTEXT` as `aws+none` where some node
had no provider ID: its TSVs, pooled with newer ones, read `mixed` on those keys, with that warning.

## How a sweep ends

From its start a sweep's `sweep-outcome.txt` says `STATUS=running`. At its end, before its reports,
it records `STATUS=finished` and exits `0`, or
`4` when some cells failed (`N of M cells failed`, by reason) or it recorded a problem (the Istio
version, revision or generations, a member's platform record or `HARNESS_SHA` changed during the
sweep; each suite README lists its own). One that stops exits `1` (a bad flag or precondition, a
failed check, an error), or `3` when dataplane's or churn-dataplane's `--on-unreachable fail`
stopped it, and once started records `STATUS=stopped` with its reason; a stop wins over `4`. On
Ctrl-C, SIGTERM or SIGHUP it sends SIGTERM to the running step's process group (the step and every
process it started), SIGKILL to what still runs `SWEEP_STOP_GRACE_SEC` (30) seconds later, records
`STATUS=interrupted` with the signal and exits 128+n (130, 143, 129). One that ends early prints its
dir and the suite's cleanup command; only one killed outright (SIGKILL, out of memory, a lost host)
keeps `STATUS=running`. Every report of the dir repeats the outcome; a `sweep-outcome.txt` an older
harness wrote has no `STATUS` line: the reports read it as `UNKNOWN` and flag it (the csv format
copies the record's lines as they are). A sweep that did not finish (killed outright, or its
terminal closed, so its `clean up with:` line went to a dead terminal) may leave its test workloads
on the members: run the suite's cleanup script (each suite README names it) with `--contexts <the
sweep's members>` (and `--wait-deletion` where the script has it), then run the sweep again into a
new dir.

## The Istio version check

Before its first change, every suite reads the version each member runs: the exact `.spec.version`
of the IstioRevision its `istios.sailoperator.io default` CR names as active. A member is ready when
its CR is Healthy and reconciled, no more than one revision is in use (two or more: a migration) and
istiod is rolled out with no pod terminating (Kubernetes reports those from 1.35 on); the members
that are not are read again, together, every 5 s until they are, up to
`ISTIO_VERSION_READY_WAIT_SEC` (60 s) in all, unless their first read leaves the version unknown
(not read, or not exact). With `ISTIO_VERSION_CHECK=fail` (the default) a version unknown at the
first read (at once, with no wait for the others) or at the end of the wait, members on different
versions, a version other than the pin `ISTIO_VERSION` (keep it equal to `istioVersion` in
`charts/spoke-ossm/values.yaml`) or a member still not ready stops the suite before it changes
anything; `warn` goes on and records what the mesh runs: a sweep notes each finding in its outcome,
while a probe run on its own and the one-off Gateway API check (read-only, it only warns) print it on stderr only. A
sweep reads every member again at its end: another version or active revision, or generations that
moved (an edit of the Istio CR, or Sail rendering it again), is a problem; a member not ready or not
read then, a note.

## The platform record

The platform keys are read outside every measurement window, each read bounded by
`PLATFORM_READ_TIMEOUT` (20s; raise it for members with many nodes), `PLATFORM_READ_PARALLEL` (20;
lower it on a runner short of memory) members at a time. The Kubernetes and Istio version reads
share only `PLATFORM_READ_PARALLEL`: each of their reads has a fixed 5 s timeout. A sweep reads
the platform keys once, hands them to its steps in `platform-record.txt` and reads them
again after its last step: a value that changed is a problem. `TEST_PLATFORM` picks each suite
chart's OpenShift overlay (`auto` asks each member); the record asks each member anyway, and warns
when one differs. Compare results within one platform and mesh build: a report warns when its inputs
differ. On kind every node reports the whole host, so the controlplane report flags its capacity
figures and its SLA verdict leaves the node figures out (`CAUTION`), as for a member whose node
provider was not read; k3d (`k3s://`) and minikube clusters that share one host are not detected, so
read their node figures the same way. On kind the cross-cluster path runs through
cloud-provider-kind's userspace Envoy on the shared host, so the dataplane and churn-dataplane
reports flag their remote latency. A member that holds a tuning profile's objects makes tuning 001
and 003 refuse to start and the other sweeps warn (`tests/tuning/005-cleanup.sh` removes them).

## Run config (`--config FILE`)

Every numbered script of propagation, controlplane, dataplane, churn, churn-dataplane and the
one-off Gateway API check (gateway-api) takes `--config FILE`: one file of `KEY=value` lines (`SETUP_CONTEXTS` and the suite's
keys in `config/options.env`, the ones its README lists; not every key there, see "Environment
only" below) that describes a whole run, so setup, sweep, report and cleanup read
the same values. Each of these suites has a worked example, `tests/<suite>/configs/smoke.env` (the Gateway API
check: `misc_tests/gateway-api/configs/smoke.env`),
and a "Run config" section in its README that lists its keys. Tuning does not take one yet.

- **Precedence:** flag > `--config` > environment > default. The file loads before
  `options.env`, so the defaults derived there follow it. Each key is logged on stderr, with the
  environment value it overrides. `KEY=` (empty) means the built-in default.
- **Syntax:** the file is parsed, never sourced, so it cannot run code:
  `[export ]KEY=value [# comment]`, where the value is unquoted from `[A-Za-z0-9_.,:/@%+=-]`,
  `'...'`, or `"..."` without `"`, `$`, `` ` `` and `\`. No spaces around `=`, each key once. A
  bad line or a key outside the suite's list rejects the whole file before anything runs, with
  `file:line` and the reason.
- **Environment only:** `*_TEST_NAMESPACE` (cleanup deletes that namespace), `*_MAX_MATRIX` (the
  `--force-large-matrix` acknowledgment stays per run), `ISTIO_VERSION_CHECK` and
  `ISTIO_VERSION_READY_WAIT_SEC` (the version check above), `SWEEP_STOP_GRACE_SEC` (every sweep,
  above) and the version pins in `config/versions.env`.
- **Flags only:** run switches such as `--dry-run`, `--force-large-matrix` and `--format`, and
  what a sweep passes to each step (`--source-context`, `--remote-contexts`, `--mesh-size`, ...).
  A standalone step still takes those on the command line.
- **Sweeps:** the steps a sweep runs inherit the file's values; the flags it passes them still
  win. Before the first step a sweep checks its numeric knobs: the ones it passes its steps as
  flags (durations, QPS, connections, settle times, ...) and the ones only its steps read (setup
  and cleanup timeouts, poll intervals, ...). A value such as `5m` fails `--dry-run` instead of
  every setup, every cleanup, or the probe window (fortio would read `5m` seconds as 5 ms).
- **Context names:** keep real ones out of git. Copy an example to
  `tests/<suite>/configs/<name>.local.env` (gitignored) and set `SETUP_CONTEXTS` there.
- **Provenance:** every TSV preamble records `RUN_CONFIG` (the file's path from the repo root, or
  only its name outside the repo; `none` without `--config`) and `RUN_CONFIG_SHA256`, and every
  report format repeats them: `unknown` for files written before these keys existed, and
  `mixed:<a>,<b>` with a warning when the inputs disagree. A sweep copies the file to
  `sweep-<RUN_ID>/run-config-<RUN_ID>.env`, and every probe's per-run markdown summary has a
  `Run config` row.
- **One run per report:** a report reads every TSV under its results dir. When that dir holds
  more than one run (each `sweep-*` directory is one run; outside one, each `RUN_ID`), it stops,
  lists the runs and prints the `--results-dir <dir>/sweep-<RUN_ID>` that reports each alone.
  `--allow-multi-run` pools them on purpose, and every format then says it pools N runs and
  lists their `HARNESS_SHA` and `ISTIO_VERSION` values. A key that differs across the inputs reads
  `mixed:<a>,<b>`, never one file's value. A report repeats the `sweep-outcome.txt` of each sweep
  dir its inputs come from.

## The end-to-end echo check by hand

`tests/preflight/001-check-mesh.sh --echo` runs this check for you. By hand: deploy the echo app
and call it through any member's ingress gateway. Answers should come
from every member. The manifest keeps placeholders for the repo, the revision, the platform and the
Argo CD namespace; fill them in on the way to the hub from what the hub already syncs, so the check
runs the same charts as the mesh.

```bash
NS=argocd PLATFORM=kubernetes   # OpenShift: NS=openshift-gitops PLATFORM=openshift
read -r REPO REV < <(kubectl --context <hub-ctx> -n "$NS" \
  get applications.argoproj.io hub-gitops-root \
  -o jsonpath='{.spec.source.repoURL} {.spec.source.targetRevision}')
fill() { sed -e "s|<repo-url>|${REPO:?}|g" -e "s|<revision>|${REV:?}|g" \
  -e "s|<platform>|${PLATFORM}|g" -e "s|<gitops-namespace>|${NS}|g" charts/mesh-verify-appset.yaml; }
fill | kubectl --context <hub-ctx> apply -f -
# Wait for the echo workload on every member (Argo CD creates it within a few minutes).
for ctx in <mesh-a-ctx> <mesh-b-ctx>; do
  for i in $(seq 60); do kubectl --context "$ctx" -n mesh-verify get deploy mesh-verify-echo >/dev/null 2>&1 && break; sleep 5; done
  kubectl --context "$ctx" -n mesh-verify rollout status deploy/mesh-verify-echo --timeout=300s
done
INGRESS=$(kubectl --context <mesh-a-ctx> get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}')
: "${INGRESS:?the ingress gateway Service has no address yet (see the README's Troubleshooting)}"
for i in $(seq 10); do curl -sS -H 'Host: mesh-verify.local' "http://$INGRESS/"; done
fill | kubectl --context <hub-ctx> delete -f -
```
