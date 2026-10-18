#!/usr/bin/env bash
# Orchestrate control-plane resource collection across the cross-product of
# six sweep axes: mesh size × service count × replicas × namespace count
# × sidecar scoping × traffic config (none / vsdr).
#
# For every combination, deploys dummy workloads, settles, scrapes istiod, and
# cleans up before moving on. Uses split-phase metrics so the deploy-time
# istiod push storm lands inside the measurement window.
#
# Usage:
#   ./tests/controlplane/003-run-sweep.sh [options]
#
# Examples:
#   # Default sweep: mesh sizes 1..N with 10 svc x 3 replicas x 1 ns:
#   ./tests/controlplane/003-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>
#
#   # Service count x Sidecar scoping at mesh size 2:
#   ./tests/controlplane/003-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> \
#     --mesh-sizes 2 --service-counts 10,100 --sidecar-scopings none,namespace,explicit
#
#   # Bare services vs a VirtualService + DestinationRule per service, back to back:
#   ./tests/controlplane/003-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> \
#     --mesh-sizes 2 --service-counts 10 --replica-counts 2 --traffic-configs none,vsdr
#
#   # Dry-run to see the planned matrix:
#   ./tests/controlplane/003-run-sweep.sh --dry-run --contexts <mesh-a-ctx>,<mesh-b-ctx>
#
#   # The whole sweep from a run config (axes, settle, results dir; flags still win):
#   ./tests/controlplane/003-run-sweep.sh --config tests/controlplane/configs/smoke.env --dry-run
# ci-dry-run: --traffic-configs none,vsdr
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# Loud ERR trap for unexpected aborts; per-combo failures become row statuses.
# sweep_err_trap prints the FATAL line and keeps it as the stop reason a sweep that
# aborts after its start records (sweep_outcome_on_exit in the EXIT trap).
trap 'sweep_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_preamble_lines
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
# The steps this sweep runs inherit them (and RUN_CONFIG*) from the environment; the
# per-combo flags it passes still win.
config_preload controlplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/config/options.env"  # SCALE_* preamble keys
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"  # now_ms for the peak poller
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"  # probe_kube_versions for the pre-created preamble
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/capacity.sh"  # cap_node_totals / cap_istiod_limits for the capacity lines
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/envelope.sh"  # cluster-infra preamble + campaign-end scale envelope
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/metrics.sh"  # extractors fanout.sh needs (growth memory guard)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"  # per-pod istiod port-forwards (growth memory guard)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/growth.sh"  # istiod heap, gateway Envoy memory (growth memory guard)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fit.sh"  # mem_guard_project / mem_guard_verdict

CONTEXTS_CSV=""
# Axes: the plural key (a CSV, PL7), else the singular key 001/002 use, else the default.
MESH_SIZES_CSV="${CONTROLPLANE_MESH_SIZES:-}"
SERVICE_COUNTS_CSV="${CONTROLPLANE_SERVICE_COUNTS:-${CONTROLPLANE_SERVICE_COUNT:-10}}"
REPLICA_COUNTS_CSV="${CONTROLPLANE_REPLICA_COUNTS:-${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}}"
NAMESPACE_COUNTS_CSV="${CONTROLPLANE_NAMESPACE_COUNTS:-${CONTROLPLANE_NAMESPACE_COUNT:-1}}"
SIDECAR_SCOPINGS_CSV="${CONTROLPLANE_SIDECAR_SCOPINGS:-${CONTROLPLANE_SIDECAR_SCOPING:-none}}"
TRAFFIC_CONFIGS_CSV="${CONTROLPLANE_TRAFFIC_CONFIGS:-${CONTROLPLANE_TRAFFIC_CONFIG:-none}}"
VSDR_EVERY="${CONTROLPLANE_VSDR_EVERY:-1}"
VSDR_SUBSETS="${CONTROLPLANE_VSDR_SUBSETS:-2}"
VSDR_APPLY="${CONTROLPLANE_VSDR_APPLY:-together}"
VSDR_APPLY_FLAG=0
# 1 when passed as a flag: --resume refuses a flag that conflicts with the resumed
# preamble, and otherwise adopts the preamble's value.
VSDR_EVERY_FLAG=0
VSDR_SUBSETS_FLAG=0
CONFIG_DUMP_SAMPLES="${CONTROLPLANE_CONFIG_DUMP_SAMPLES:-3}"
OUTPUT_DIR_BASE="$(config_repo_path "${CONTROLPLANE_RESULTS_DIR}")"
# 1 when --output-dir is passed (--resume refuses it; a results dir from the
# environment or --config does not count).
OUTPUT_DIR_FROM_FLAG=0
SETTLE_SEC="${CONTROLPLANE_SETTLE_SEC:-60}"
DRY_RUN=0
METRICS_API_STATUS="unknown"  # set by metrics_preflight; recorded in the preamble
FORCE_LARGE_MATRIX=0
MAX_MATRIX="${CONTROLPLANE_MAX_MATRIX:-64}"
# --resume: reuse an existing sweep dir + RUN_ID and skip combos that already
# have a valid row (istiod_restarted=="0" for the same six axis values).
RESUME_DIR=""
# The resume's start time (the rows' timestamp format, for the TSV and resumes.txt), set with
# RESUME_DIR below; RESUME_AT_Z: the same in UTC with Z, for prose (notes, warnings, plans).
RESUME_AT="" RESUME_AT_Z=""
# 1 when --service-counts is passed (growth mode refuses it: services = N x K).
SERVICE_COUNTS_FLAG=0
# 1 when the axis flag is passed: a --resume takes each axis flag not given from the first
# run's plan (planned-cells.txt "# PLAN=1"), not from the environment, --config or default.
MESH_SIZES_FLAG=0 REPLICA_COUNTS_FLAG=0 NAMESPACE_COUNTS_FLAG=0 SIDECAR_SCOPINGS_FLAG=0 TRAFFIC_CONFIGS_FLAG=0
# --extend-plan: a --resume may run cells no earlier run of the sweep planned.
EXTEND_PLAN="${CONTROLPLANE_EXTEND_PLAN:-0}"

# Namespace scaling (growth mode). CSV axes take the plural key (PL7), else the
# singular one 001/002 read.
SPN_CSV="${CONTROLPLANE_SERVICES_PER_NAMESPACES:-${CONTROLPLANE_SERVICES_PER_NAMESPACE:-0}}"
GROWTH_MODE="${CONTROLPLANE_GROWTH_MODE:-in-place}"
WORKLOAD_MODE="${CONTROLPLANE_WORKLOAD_MODE:-pods}"
MEASUREMENT_POD_COUNTS_CSV="${CONTROLPLANE_MEASUREMENT_POD_COUNTS:-${CONTROLPLANE_MEASUREMENT_PODS:-4}}"
OUTSIDE_NAMESPACES="${CONTROLPLANE_OUTSIDE_NAMESPACES:-0}"
OUTSIDE_MODES_CSV="${CONTROLPLANE_OUTSIDE_MODES:-${CONTROLPLANE_OUTSIDE_MODE:-none}}"
PROBE_SETTLE_SEC="${CONTROLPLANE_PROBE_SETTLE_SEC:-60}"
MEM_STOP_PCT="${CONTROLPLANE_MEM_STOP_PCT:-70}"
MEM_GUARD_CONTEXTS_CSV="${CONTROLPLANE_MEM_GUARD_CONTEXTS:-}"
SERIES_RETIRE="${CONTROLPLANE_SERIES_RETIRE:-undiscover}"
NS_DELETE_SEC_PER_NS="${CONTROLPLANE_NS_DELETE_SEC_PER_NS:-1.0}"
# A series retire is retried, then verified (no namespace of the series still discovered).
RETIRE_ATTEMPTS="${CONTROLPLANE_RETIRE_ATTEMPTS:-3}"
RETIRE_BACKOFF_S="${CONTROLPLANE_RETIRE_BACKOFF_S:-10}"
# Absolute gateway memory model of the guard (Mi per 1000 discovered Services, burst factor).
GW_MI_INTERCEPT="${CONTROLPLANE_GW_MI_INTERCEPT:-10}"
EWGW_MI_PER_1000="${CONTROLPLANE_EWGW_MI_PER_1000_SVC:-145}"
EWGW_BURST="${CONTROLPLANE_EWGW_BURST_FACTOR:-2.5}"
INGW_MI_PER_1000="${CONTROLPLANE_INGW_MI_PER_1000_SVC:-91}"
INGW_BURST="${CONTROLPLANE_INGW_BURST_FACTOR:-1.2}"
# Leftover test namespaces at a series start: undiscovered ones above this count warn.
LEFTOVER_NS_WARN="${CONTROLPLANE_LEFTOVER_NS_WARN:-100}"

NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"

usage() {
	local mesh_sizes_default='"1,2,...,len(contexts)"'
	[[ -z "$MESH_SIZES_CSV" ]] || mesh_sizes_default="$MESH_SIZES_CSV"
	cat <<EOF
Usage: $(basename "$0") [options]

Run config:
  --config FILE               Run config of KEY=value lines (config/options.env keys; see
                              tests/controlplane/README.md, "Run config"). The steps the
                              sweep runs inherit it. Precedence: flag > --config >
                              environment > default.

Sweep dimensions (cross-product):
  --contexts CSV              All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV            Cluster counts (default: ${mesh_sizes_default}).
  --service-counts CSV        Dummy services per cluster (default: $SERVICE_COUNTS_CSV).
  --replica-counts CSV        Replicas per service (default: $REPLICA_COUNTS_CSV).
  --namespace-counts CSV      Namespaces to spread services across (default: $NAMESPACE_COUNTS_CSV).
  --sidecar-scopings CSV      Sidecar CR scoping modes: none,namespace,wide,explicit
                              (default: $SIDECAR_SCOPINGS_CSV). wide = a per-namespace
                              Sidecar with egress */* (unscoped).
  --traffic-configs CSV       Traffic management per service: none,vsdr
                              (default: $TRAFFIC_CONFIGS_CSV).
                              vsdr adds a VirtualService + DestinationRule per
                              configured service; innermost axis, so each none/vsdr
                              pair runs back to back. --traffic-config is an alias.

Traffic management (scalars, recorded in the TSV preamble):
  --vsdr-every N              Configure service i when i mod N == 0 (default: $VSDR_EVERY).
  --vsdr-subsets N            DestinationRule subsets; the service's replicas are split
                              over this many Deployments, so it must be <= every
                              --replica-counts value (default: $VSDR_SUBSETS).
  --vsdr-apply MODE           together: one apply inside the window (the pods start while
                              the VS/DR already exist); split: apply the workloads (and
                              wait for Ready) before the baseline, then only the VS/DR
                              inside the window (rows window_kind traffic; a none cell's
                              window is then idle). split separates the VS/DR push cost
                              from pod startup (BACKLOG 9.11). Default: $VSDR_APPLY.

Namespace scaling (growth mode; README "Namespace scaling"). Any K > 0 switches the
sweep to growth series: --namespace-counts is the ladder of N (ascending), services
are N x K (so --service-counts is refused), one replica count, traffic none, no
explicit scoping, no --resume.
  --services-per-namespaces CSV
                              K values, one growth series each (default: $SPN_CSV;
                              0 = the legacy sweep). --services-per-namespace is an alias.
  --growth MODE               in-place: grow one set of namespaces step by step and
                              measure a grow window plus one probe window per scoping
                              at each N; fresh: deploy and clean up every N x scoping
                              cell (the PL34 fidelity check). Default: $GROWTH_MODE.
  --workload-mode MODE        pods|config-only (default: $WORKLOAD_MODE). config-only:
                              Services without pods plus M measurement pods.
  --measurement-pod-counts CSV
                              config-only: measurement pods M, ascending (default:
                              $MEASUREMENT_POD_COUNTS_CSV). The first is the base; each further
                              value re-probes every scoping at the largest N (the
                              M-sweep: does istiod heap grow with M?). --measurement-pods
                              is an alias.
  --outside-namespaces X      Namespaces outside the mesh added at the largest N
                              (default: $OUTSIDE_NAMESPACES).
  --outside-modes CSV         unlabeled,labeled: the outside phases, in order (default:
                              $OUTSIDE_MODES_CSV; none = no phase). --outside-mode is an alias.
  --probe-settle SEC          Probe window: settle after a probe namespace is applied,
                              and again after its teardown (default: $PROBE_SETTLE_SEC).
  --mem-stop-pct PCT          Memory stop guard: skip a cell (SKIPPED_MEM_GUARD row) when
                              projected istiod heap or gateway Envoy memory exceeds PCT %
                              of its limit (default: $MEM_STOP_PCT; 0 disables).
  --mem-guard-contexts CSV    Contexts the guard samples (default: --contexts plus
                              \$SETUP_CONTEXTS: every member ingests the Services). A
                              live run adds the members the measured contexts' remote
                              secrets name, and warns about one without a kube context.
  --series-retire MODE        End of a series: undiscover (drop discovery labels, keep
                              the namespaces; 005 --undiscover --no-delete), delete (also
                              queue the namespace deletes, no wait) or keep (default:
                              $SERIES_RETIRE). undiscover and delete are retried
                              (CONTROLPLANE_RETIRE_ATTEMPTS) and verified: when a namespace
                              of the series is still discovered afterwards, the sweep
                              records RETIRE_FAILED, runs no further series and exits 1.

  The memory guard projects each component two ways and stops on either: relative
  (base + (current - base) x ratio^power, from the series start) and, for gateways,
  absolute ((CONTROLPLANE_GW_MI_INTERCEPT + Mi per 1000 Services x Services after the
  step / 1000) x burst factor; CONTROLPLANE_{EWGW,INGW}_MI_PER_1000_SVC and
  _BURST_FACTOR). It compares the container working set (kubectl top; else Envoy
  server.memory_physical_size, else server.memory_allocated) and istiod RSS with the
  limit. A live sweep also adds every mesh member its remote secrets name to the
  guard set (or warns when a member has no kube context), and refuses to start
  while a controlplane-test namespace of an earlier run is still discovered.

Other:
  --config-dump-samples N     Random pods per cluster to exec /config_dump on
                              (default: $CONFIG_DUMP_SAMPLES; 0 disables).
  --settle SEC                Seconds for the delta-window between baseline
                              and final scrape (default: $SETTLE_SEC).
  --output-dir DIR            Results base directory; each sweep gets a
                              sweep-<RUN_ID>/ subdir under it
                              (default: ${CONTROLPLANE_RESULTS_DIR}).
  --resume DIR                Resume an interrupted sweep in this sweep-<RUN_ID>/
                              dir (or a symlink to one; any other dir is refused):
                              reuse its RUN_ID and skip cells that already have a
                              valid row and did not end on a status row. A cell
                              whose last row is a status row (one that failed
                              partway or was INTERRUPTED included), or whose
                              rows name fewer members than its mesh size
                              (INCOMPLETE: cut short while they were written),
                              runs again, and from then on the reports use only
                              that new attempt (an attempt is one run: the first,
                              or a resume, which resumes.txt lists and a
                              "# RESUMED_AT=" line in the TSV marks; they say how
                              many rows of earlier attempts they leave out).
                              An axis flag not given (--mesh-sizes,
                              --service-counts, --replica-counts,
                              --namespace-counts, --sidecar-scopings,
                              --traffic-configs) takes the first run's value
                              from planned-cells.txt ("# PLAN=1"), not the
                              environment, --config or default (a sweep dir an
                              older harness started, without the file or with
                              PLANNED_SET=partial: from the TSV's "# Contexts:
                              ... Mesh sizes: ..." line; with neither, a resume
                              that does not give all six is refused); the run
                              prints the values it took, and its banner the
                              axis flags it runs with. A cell no earlier run
                              of the sweep planned is refused (nothing runs)
                              unless --extend-plan. Scalars recorded once in
                              the TSV preamble (VSDR_EVERY and VSDR_SUBSETS when
                              the run includes vsdr, PROXY_CHECK_*) are taken
                              from it; a conflicting --vsdr-every/--vsdr-subsets
                              flag is refused. Not valid with --output-dir or
                              --dry-run.
                              Refused while another run of the sweep still runs
                              in the dir (.sweep.lock holds its PID). A sweep
                              started with --config resumes only with the same
                              file (same sha256; add --config
                              <DIR>/run-config-<RUN_ID>.env); one started without
                              it warns when --config is given. --contexts must
                              name the members the sweep started on, in the same
                              order (mesh size N measures the first N), the mesh
                              must run the ISTIO_VERSION the sweep recorded, and
                              each member the active revision it recorded
                              (ISTIO_ACTIVE_REVISIONS), under either
                              ISTIO_VERSION_CHECK policy; otherwise start a new
                              sweep (also to add members for a larger mesh
                              size). Nor if the Istio CR or its active
                              IstioRevision was edited since the sweep started
                              (ISTIO_GENERATIONS), nor a sweep whose TSV preamble
                              lists a member twice (an older harness took it
                              twice). Nor is a sweep resumed whose
                              sweep-outcome.txt (or .prev.txt) records a PROBLEM
                              (the version, the active revision or the
                              generation of the Istio CR or its active
                              IstioRevision changed under it, or the
                              end-of-sweep version check failed; not that the
                              cells could not be counted, which every run
                              redoes, nor that the harness changed during the
                              sweep). The resume carries that harness PROBLEM
                              into its own outcome, still a PROBLEM (exit 4)
                              ending "(kept: <why>)": <n> row(s) of that run
                              are in the figures; the rows in the figures ran
                              more than one harness, or one not recorded; that
                              run's rows could not be counted; or its record
                              names no date, so the run it is about is not
                              known. When that run wrote no rows, or its rows
                              were all run again later, and the rows the
                              figures keep ran one harness, the outcome writes
                              it as a NOTE instead, ending "(that run wrote no
                              rows)" or "(its rows were all run again later)",
                              without the advice to run the sweep again. Before
                              its first cell, a resume (as a first run) counts
                              the controlplane-test namespaces a run cut short
                              left on the --contexts members and on the other
                              mesh members their remote secrets name, deletes
                              those on the --contexts members (005-cleanup.sh),
                              then waits --settle, so no cell runs on another's
                              leftovers or inside their deletion's pushes;
                              it deletes nothing on the other members: when
                              they hold some, it stops first and prints the 005
                              command for them. An earlier run's notes about the
                              end of the sweep are carried into the new outcome,
                              once. A resume that passes its checks marks the
                              sweep's markdown pages (sweep-, sweep-charts- and
                              scale-envelope-<RUN_ID>.md) as made before it (a
                              line under the title and one in place of the
                              outcome; front matter stale_since_resume), until it
                              writes them again at its end. The TSV keeps the
                              first run's ISTIO_NOTREADY_AT_START (the outcome
                              repeats it as a note) and HARNESS_SHA; the
                              resume records its own readiness, with its
                              start time, in a note of the sweep outcome
                              (ISTIO_NOTREADY_AT_RESUME=...), and warns when it
                              runs another harness (HARNESS_CONTENT_KEY; when
                              only git describe differs, an INFO) than the last
                              known one before it, or unknown, or reads other
                              Kubernetes server versions. resumes.txt in the
                              sweep dir keeps one line per resume (start time,
                              HARNESS_SHA, readiness, kube versions, the TSV's
                              line count, which starts its attempt, the proxy
                              versions and generations it read, the TSV it
                              applies to, its HARNESS_CONTENT_KEY); the outcome
                              notes each harness or kube version change in it,
                              each resume on an unknown harness, and each earlier
                              resume that started not ready. planned-cells.txt in
                              the sweep dir lists every cell the first run
                              planned (each resume adds its own): a cell planned
                              but never run counts as failed (NOT_RUN), and the
                              outcome names it and the full command that resumes
                              with the flags that planned it; a resume whose axis
                              flags leave planned cells out lists them at its
                              start, each with the full command that resumes with
                              them. Resume with those flags to finish the
                              sweep. A resume that added no rows (every cell of
                              its flags was done) says so, and the reports
                              leave it out of the rows' provenance.
  --extend-plan               With --resume: also run cells no earlier run of the
                              sweep planned (planned-cells.txt records them as a
                              new PLAN). Env CONTROLPLANE_EXTEND_PLAN=1 does the
                              same (not settable from --config). Default: refuse.
  --force-large-matrix        Allow matrix > $MAX_MATRIX combinations (default: refuse).
  --dry-run                   Print plan and matrix, then exit (no cluster is read: it
                              says what a live run's leftover check would do).
  -h, --help                  Show this help.

Exit codes:
  0  every cell ran; rows with istiod_restarted 1/unknown are measurement outcomes,
     counted in the report's n_total and left out of n_valid
  1  the sweep stopped: a bad flag or precondition (also another live run that holds
     the sweep dir's .sweep.lock, or a --resume whose axis flags plan a cell no earlier
     run planned, without --extend-plan: nothing was changed), an unexpected error, or a
     series that could not be retired (RETIRE_FAILED; the reports are written)
  4  the sweep finished and wrote its reports, but N cells failed (a status row
     instead of a measurement: SETUP_FAILED, PROBE_FAILED, GROW_FAILED, SWITCH_FAILED,
     or INTERRUPTED, the cell a run that stopped or was interrupted was in, unless every
     member's rows were written; or a legacy cell whose rows cover fewer members than
     its mesh size, or a member with fewer rows than its window's WINDOW_ROWS line names
     (in rows an older harness wrote one by one: than its istiod replicas), INCOMPLETE:
     cut short while its rows were written; stderr ends with "N of M cells failed" by
     reason), or the Istio version or active revision changed during the sweep (read
     again at its end), or the generation of a member's Istio CR or active
     IstioRevision went up at the same version (an edit of the Istio CR; or, the
     IstioRevision alone, an OSSM operator upgrade or a TLS security profile change),
     or that end-of-sweep version check failed, or the harness (a file under tests/,
     config/, charts/ or terraform/) changed during the sweep (HARNESS_SHA read again
     before its steps, by each step and at its end; 002 writes a "# HARNESS_CHANGED_AT="
     line in the TSV before rows that ran other harness files than the TSV records), or
     the cells could not be counted. A cell counts once, by the last row of its latest
     attempt (a --resume runs a failed or INCOMPLETE cell again; the rows of its earlier
     attempts are left out): a status row fails it, with that reason; a measurement does
     not. Proxies on another Istio version than their istiod at the start
     (ISTIO_PROXY_VERSIONS) are a note, never a failure. M covers every cell of the
     sweep's planned-cells.txt and of this run's matrix; a planned cell without a row
     fails as NOT_RUN. Cells the memory guard skipped (SKIPPED_MEM_GUARD,
     SKIPPED_SERIES_STOPPED) are counted apart, on stdout, and do not make it 4. The
     outcome is also in sweep-outcome.txt, the markdown report and the scale envelope.
     From its start until then, sweep-outcome.txt says the sweep has not finished
     (EXIT=unfinished): a sweep killed outright keeps it, and its reports say so; one
     interrupted (SIGHUP, Ctrl-C, SIGTERM: exit 129, 130, 143) adds when and by which
     signal; one that stops on an error after its start (exit 1) records the stop and
     its reason (STOPPED=1, STOP_REASON, CUT_SHORT=1). --resume runs after any of them.
     A signal sent to the sweep's process alone (kill <pid>, kill -INT <pid>) reaches
     the step that runs (001, 002, 005) and every process under it at once; any still
     running SWEEP_STOP_GRACE_SEC later get SIGKILL, and the lock is released after
     them. For a sweep in a terminal's foreground, a kill -INT or -HUP skips the
     processes in that foreground (a Ctrl-C reaches them itself): they get SIGKILL with
     no cleanup, so stop such a sweep from elsewhere with SIGTERM. The sweep's own
     commands between steps (a settle wait, the leftover counts, the Istio version and
     proxy reads, the end-of-sweep recheck) finish first, each bounded. Stopping the
     step's tree needs a ps that lists start times (procps, or macOS's), or Linux's /proc
     in its place: without either, the sweep warns at its start (a --dry-run too), and a
     stop reaches only the step's own process. While a run goes on, the sweep dir holds
     its lock (.sweep.lock, its PID): another --resume of it is refused.

Environment:
  ISTIO_VERSION_CHECK (fail, the default, or warn): stop before any change, or warn and
  record what the mesh runs, when a member's active IstioRevision version is not
  ISTIO_VERSION. ISTIO_VERSION_READY_WAIT_SEC / ISTIO_VERSION_READY_POLL_SEC (60 / 5): how
  long, and how often, to read again a member whose istiod or IstioCNI is not ready, or
  whose istiod is rolling out; a rollout still running after the wait reads as unknown.
  SETUP_CONTEXTS, CONTROLPLANE_SERVICE_COUNT, CONTROLPLANE_REPLICAS_PER_SERVICE,
  CONTROLPLANE_NAMESPACE_COUNT, CONTROLPLANE_SIDECAR_SCOPING,
  CONTROLPLANE_TRAFFIC_CONFIG, CONTROLPLANE_VSDR_EVERY, CONTROLPLANE_VSDR_SUBSETS,
  CONTROLPLANE_CONFIG_DUMP_SAMPLES, CONTROLPLANE_MAX_MATRIX.
  Axis CSVs: CONTROLPLANE_MESH_SIZES, CONTROLPLANE_SERVICE_COUNTS,
  CONTROLPLANE_REPLICA_COUNTS, CONTROLPLANE_NAMESPACE_COUNTS,
  CONTROLPLANE_SIDECAR_SCOPINGS, CONTROLPLANE_TRAFFIC_CONFIGS (each, when empty, falls
  back to the singular key above). CONTROLPLANE_SETTLE_SEC (--settle),
  CONTROLPLANE_RESULTS_DIR (--output-dir; relative to the repo root),
  CONTROLPLANE_WAIT_TIMEOUT_SEC (001's pod readiness wait). The sweep checks the knobs
  only its steps read (CONTROLPLANE_WAIT_TIMEOUT_SEC, CONTROLPLANE_SETUP_NS_WAIT_SEC,
  CONTROLPLANE_APPLY_*, CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S,
  CONTROLPLANE_NS_DELETE_TIMEOUT_SEC, CONTROLPLANE_CLEANUP_GRACE_SEC) before the first
  setup, --dry-run included.
  SCALE_SIZING_MODE (must be fixed: the sweep refuses auto, which only standalone 001
  supports), SCALE_TARGET_FRACTION (recorded in the TSV preamble).
  Growth mode: CONTROLPLANE_SERVICES_PER_NAMESPACES (else ..._SERVICES_PER_NAMESPACE),
  CONTROLPLANE_GROWTH_MODE, CONTROLPLANE_WORKLOAD_MODE,
  CONTROLPLANE_MEASUREMENT_POD_COUNTS (else ..._MEASUREMENT_PODS),
  CONTROLPLANE_MEASUREMENT_PROXY_MEM_LIMIT, CONTROLPLANE_OUTSIDE_NAMESPACES,
  CONTROLPLANE_OUTSIDE_MODES (else ..._OUTSIDE_MODE), CONTROLPLANE_PROBE_SETTLE_SEC,
  CONTROLPLANE_MEM_STOP_PCT, CONTROLPLANE_MEM_GUARD_CONTEXTS, CONTROLPLANE_SERIES_RETIRE,
  CONTROLPLANE_NS_DELETE_SEC_PER_NS (the plan's namespace-deletion estimate),
  CONTROLPLANE_RETIRE_ATTEMPTS, CONTROLPLANE_RETIRE_BACKOFF_S, CONTROLPLANE_GW_MI_INTERCEPT,
  CONTROLPLANE_EWGW_MI_PER_1000_SVC, CONTROLPLANE_EWGW_BURST_FACTOR,
  CONTROLPLANE_INGW_MI_PER_1000_SVC, CONTROLPLANE_INGW_BURST_FACTOR,
  CONTROLPLANE_LEFTOVER_NS_WARN.
  SCALE_PER_POD_CPU_M: per-pod CPU of the capacity plan; empty (default) = the live
  Istio CR's sidecar CPU request on the first context (Istio's 100m when the CR sets
  none); a value wins over the live reading. The plan compares the largest combo with
  each member's free CPU (allocatable minus what other pods request); 001 refuses a step
  that does not fit unless SCALE_CPU_PREFLIGHT_ENFORCE=0 (warn only, for a node autoscaler).
  METRICS_READY_TIMEOUT (default 120; 0 disables), METRICS_READY_INTERVAL (10):
  pre-sweep wait for 'kubectl top nodes'; warns (never aborts) if unavailable.
  CAP_TOP_TIMEOUT (default 15), CAP_TOP_ATTEMPTS (2), CAP_TOP_BACKOFF_S (2):
  timeout and retry for the kubectl top reads.
  METRICS_SCRAPE_TIMEOUT (default 30): curl --max-time for istiod /metrics.
  CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT (default 10), CONTROLPLANE_PROXY_CHECK_MIN_DIFF
  (default 2): warn when a cluster's connected proxies and its Running sidecar pods
  differ by more than max(tolerance %, min diff); recorded in the TSV preamble.
  HARNESS_SHA_CHECK_SEC (60): seconds between the sweep's harness reads (0: before every
  step); SWEEP_STOP_GRACE_SEC (30): how long a signalled sweep waits for its step's
  processes before SIGKILL; ISTIO_PROXY_READ_PARALLEL (20): members whose proxy versions
  are read at once. Environment only (config/options.env), as
  CONTROLPLANE_EXTEND_PLAN (--extend-plan).

Requires GNU timeout for a live run (002's config-dump samples, the memory guard's
Envoy-stats reads; on macOS: brew install coreutils, which installs gtimeout). Without
it a live sweep stops before any cluster change; --dry-run does not need it.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2
		;;
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--mesh-sizes)
		[[ -n "${2:-}" ]] || die "--mesh-sizes requires a value"
		MESH_SIZES_CSV="$2"
		MESH_SIZES_FLAG=1
		shift 2
		;;
	--service-counts)
		[[ -n "${2:-}" ]] || die "--service-counts requires a value"
		SERVICE_COUNTS_CSV="$2"
		SERVICE_COUNTS_FLAG=1
		shift 2
		;;
	--services-per-namespaces | --services-per-namespace)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		# PL7: the singular form (001/002 spelling) is an alias.
		[[ "$1" == --services-per-namespace ]] && echo "note: --services-per-namespace is an alias; the sweep flag is --services-per-namespaces CSV" >&2
		SPN_CSV="$2"
		shift 2
		;;
	--growth)
		[[ -n "${2:-}" ]] || die "--growth requires a value"
		GROWTH_MODE="$2"
		shift 2
		;;
	--workload-mode)
		[[ -n "${2:-}" ]] || die "--workload-mode requires a value"
		WORKLOAD_MODE="$2"
		shift 2
		;;
	--measurement-pod-counts | --measurement-pods)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		[[ "$1" == --measurement-pods ]] && echo "note: --measurement-pods is an alias; the sweep flag is --measurement-pod-counts CSV" >&2
		MEASUREMENT_POD_COUNTS_CSV="$2"
		shift 2
		;;
	--outside-namespaces)
		[[ -n "${2:-}" ]] || die "--outside-namespaces requires a value"
		OUTSIDE_NAMESPACES="$2"
		shift 2
		;;
	--outside-modes | --outside-mode)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		[[ "$1" == --outside-mode ]] && echo "note: --outside-mode is an alias; the sweep flag is --outside-modes CSV" >&2
		OUTSIDE_MODES_CSV="$2"
		shift 2
		;;
	--probe-settle)
		[[ -n "${2:-}" ]] || die "--probe-settle requires a value"
		PROBE_SETTLE_SEC="$2"
		shift 2
		;;
	--mem-stop-pct)
		[[ -n "${2:-}" ]] || die "--mem-stop-pct requires a value"
		MEM_STOP_PCT="$2"
		shift 2
		;;
	--mem-guard-contexts)
		[[ -n "${2:-}" ]] || die "--mem-guard-contexts requires a value"
		MEM_GUARD_CONTEXTS_CSV="$2"
		shift 2
		;;
	--series-retire)
		[[ -n "${2:-}" ]] || die "--series-retire requires a value"
		SERIES_RETIRE="$2"
		shift 2
		;;
	--replica-counts)
		[[ -n "${2:-}" ]] || die "--replica-counts requires a value"
		REPLICA_COUNTS_CSV="$2"
		REPLICA_COUNTS_FLAG=1
		shift 2
		;;
	--namespace-counts)
		[[ -n "${2:-}" ]] || die "--namespace-counts requires a value"
		NAMESPACE_COUNTS_CSV="$2"
		NAMESPACE_COUNTS_FLAG=1
		shift 2
		;;
	--sidecar-scopings)
		[[ -n "${2:-}" ]] || die "--sidecar-scopings requires a value"
		SIDECAR_SCOPINGS_CSV="$2"
		SIDECAR_SCOPINGS_FLAG=1
		shift 2
		;;
	--traffic-configs | --traffic-config)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		# PL7: the singular form (001/002 spelling) is a one-value alias.
		[[ "$1" == --traffic-config ]] && echo "note: --traffic-config is an alias; the sweep flag is --traffic-configs CSV" >&2
		TRAFFIC_CONFIGS_CSV="$2"
		TRAFFIC_CONFIGS_FLAG=1
		shift 2
		;;
	--vsdr-every)
		[[ -n "${2:-}" ]] || die "--vsdr-every requires a value"
		VSDR_EVERY="$2"
		VSDR_EVERY_FLAG=1
		shift 2
		;;
	--vsdr-subsets)
		[[ -n "${2:-}" ]] || die "--vsdr-subsets requires a value"
		VSDR_SUBSETS="$2"
		VSDR_SUBSETS_FLAG=1
		shift 2
		;;
	--vsdr-apply)
		[[ -n "${2:-}" ]] || die "--vsdr-apply requires a value"
		VSDR_APPLY="$2"
		VSDR_APPLY_FLAG=1
		shift 2
		;;
	--config-dump-samples)
		[[ -n "${2:-}" ]] || die "--config-dump-samples requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--config-dump-samples must be a non-negative integer; got '$2'"
		CONFIG_DUMP_SAMPLES="$2"
		shift 2
		;;
	--settle)
		[[ -n "${2:-}" ]] || die "--settle requires a value"
		SETTLE_SEC="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR_BASE="$2"
		OUTPUT_DIR_FROM_FLAG=1
		shift 2
		;;
	--resume)
		[[ -n "${2:-}" ]] || die "--resume requires a value (an existing sweep dir)"
		RESUME_DIR="$2"
		shift 2
		;;
	--force-large-matrix)
		FORCE_LARGE_MATRIX=1
		shift
		;;
	--extend-plan)
		EXTEND_PLAN=1
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

is_nonneg_int "$SETTLE_SEC" || die "--settle must be a non-negative integer (got: $SETTLE_SEC)"
is_pos_int "$MAX_MATRIX" || die "CONTROLPLANE_MAX_MATRIX must be a positive integer (got: $MAX_MATRIX)"
# 002 reads the same two knobs per combo; validate once here so a typo fails the
# sweep up front instead of turning every combo into PROBE_FAILED.
PROXY_CHECK_TOL_PCT="${CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT:-10}"
PROXY_CHECK_MIN_DIFF="${CONTROLPLANE_PROXY_CHECK_MIN_DIFF:-2}"
is_nonneg_int "$PROXY_CHECK_TOL_PCT" || die "CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT must be a non-negative integer percent (got: $PROXY_CHECK_TOL_PCT)"
is_nonneg_int "$PROXY_CHECK_MIN_DIFF" || die "CONTROLPLANE_PROXY_CHECK_MIN_DIFF must be a non-negative integer (got: $PROXY_CHECK_MIN_DIFF)"
is_nonneg_int "$CONFIG_DUMP_SAMPLES" || die "--config-dump-samples (or CONTROLPLANE_CONFIG_DUMP_SAMPLES) must be a non-negative integer (got: $CONFIG_DUMP_SAMPLES)"
# SCALE_SIZING_MODE=auto makes 001 deploy a capacity-derived service count, while every
# row would carry the sweep's --service-counts value: a flat, mislabelled scaling curve.
# Refused in every mode, before any cluster change; standalone 001 keeps auto.
case "${SCALE_SIZING_MODE:-fixed}" in
fixed) ;;
auto) die "SCALE_SIZING_MODE=auto is for a standalone 001 setup: in a sweep, 001 would deploy a capacity-derived service count while every row records the --service-counts value. Set SCALE_SIZING_MODE=fixed (environment or --config) and choose --service-counts; the capacity plan check a live sweep prints at startup says how many services fit." ;;
*) die "SCALE_SIZING_MODE must be fixed or auto (got: ${SCALE_SIZING_MODE})" ;;
esac
# Empty = read the live Istio CR's sidecar requests (capacity plan, 001 auto-sizing).
[[ -z "${SCALE_PER_POD_CPU_M:-}" ]] || is_pos_int "$SCALE_PER_POD_CPU_M" || die "SCALE_PER_POD_CPU_M must be empty (read the live sidecar request) or a positive integer of millicores (got: $SCALE_PER_POD_CPU_M)"
[[ -z "${SCALE_PER_POD_MEM_MI:-}" ]] || is_pos_int "$SCALE_PER_POD_MEM_MI" || die "SCALE_PER_POD_MEM_MI must be empty (read the live sidecar request) or a positive integer of Mi (got: $SCALE_PER_POD_MEM_MI)"
# So do 001, 002 and 005 with these; a typo would otherwise fail every setup or skip
# every cleanup mid-sweep, and pass --dry-run.
is_nonneg_int "${CONTROLPLANE_WAIT_TIMEOUT_SEC:-300}" || die "CONTROLPLANE_WAIT_TIMEOUT_SEC (read by 001) must be a non-negative integer (got: ${CONTROLPLANE_WAIT_TIMEOUT_SEC:-})"
[[ "${SCALE_CPU_PREFLIGHT_ENFORCE:-1}" =~ ^[01]$ ]] || die "SCALE_CPU_PREFLIGHT_ENFORCE (read by 001) must be 0 or 1 (got: ${SCALE_CPU_PREFLIGHT_ENFORCE:-})"
# The cleanup bound first: options.env defaults the setup wait to it.
is_pos_int "${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}" || die "CONTROLPLANE_NS_DELETE_TIMEOUT_SEC (read by 005) must be a positive integer (got: ${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-})"
is_nonneg_int "${CONTROLPLANE_SETUP_NS_WAIT_SEC:-${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}}" || die "CONTROLPLANE_SETUP_NS_WAIT_SEC (read by 001) must be a non-negative integer (got: ${CONTROLPLANE_SETUP_NS_WAIT_SEC:-})"
is_pos_int "${CONTROLPLANE_APPLY_ATTEMPTS:-3}" || die "CONTROLPLANE_APPLY_ATTEMPTS (read by 001) must be a positive integer (got: ${CONTROLPLANE_APPLY_ATTEMPTS:-})"
is_nonneg_int "${CONTROLPLANE_APPLY_BACKOFF_S:-5}" || die "CONTROLPLANE_APPLY_BACKOFF_S (read by 001) must be a non-negative integer (got: ${CONTROLPLANE_APPLY_BACKOFF_S:-})"
[[ "${CONTROLPLANE_APPLY_CHUNK_OBJECTS:-200}" =~ ^-?[0-9]+$ ]] || die "CONTROLPLANE_APPLY_CHUNK_OBJECTS (read by 001) must be an integer (got: ${CONTROLPLANE_APPLY_CHUNK_OBJECTS:-})"
is_pos_int "${CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S:-30}" || die "CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S (read by 002) must be a positive integer (got: ${CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S:-})"
is_pos_int "${CONTROLPLANE_CLEANUP_GRACE_SEC:-5}" || die "CONTROLPLANE_CLEANUP_GRACE_SEC (read by 005) must be a positive integer (got: ${CONTROLPLANE_CLEANUP_GRACE_SEC:-})"
# --resume already names the full sweep dir; refuse a custom --output-dir with it.
if [[ -n "$RESUME_DIR" ]] && ((OUTPUT_DIR_FROM_FLAG)); then
	die "--resume and --output-dir are mutually exclusive (--resume already names the full sweep dir)"
fi
[[ "$EXTEND_PLAN" =~ ^[01]$ ]] || die "CONTROLPLANE_EXTEND_PLAN must be 0 or 1 (got: ${EXTEND_PLAN})"
# A --resume finishes the sweep it resumes: each axis flag not given takes the first run's
# value from planned-cells.txt's "# PLAN=1" line (the environment, --config or the default
# may plan other cells), and the run prints the ones it took. A sweep without the file, or
# whose file an older harness's sweep started (PLANNED_SET=partial: its PLAN=1 is a
# resume's, not the first run's), takes them from its TSV's "# Contexts: ... Mesh sizes:
# ... Services: ..." line, which every harness's first run writes; with neither, a resume
# that does not give all six axis flags is refused (it would run the environment's, --config's
# or default value of each one not given, cells the sweep may never have planned).
RESUME_PLAN1_TOOK=""
if [[ -n "$RESUME_DIR" ]]; then
	_rp1="" _rp1_src='planned-cells.txt "# PLAN=1"'
	if [[ -f "${RESUME_DIR%/}/planned-cells.txt" ]]; then
		_rp1="$(awk 'index($0, "# PLANNED_SET=partial") == 1 { exit } index($0, "# PLAN=1 ") == 1 { p = index($0, ": --"); if (p) print substr($0, p + 2); exit }' "${RESUME_DIR%/}/planned-cells.txt" 2>/dev/null)" \
			|| die "--resume: could not read ${RESUME_DIR%/}/planned-cells.txt, which names the cells this sweep planned; nothing was run."
	fi
	if [[ -z "$_rp1" ]]; then
		_rp1_src='the TSV'"'"'s "# Contexts:" line: an older harness started this sweep without planned-cells.txt'
		_rp1_tsv="$(find -H "${RESUME_DIR%/}" -maxdepth 1 -name 'controlplane-*.tsv' -type f 2>/dev/null | sort | head -1)" || _rp1_tsv=""
		[[ -z "$_rp1_tsv" ]] || _rp1="$(awk '
			/^timestamp\t/ { exit }
			index($0, "# Contexts: ") == 1 {
				n = split(substr($0, 13), part, /  +/)
				fl["Mesh sizes"] = "--mesh-sizes"; fl["Services"] = "--service-counts"; fl["Replicas"] = "--replica-counts"
				fl["Namespaces"] = "--namespace-counts"; fl["Scopings"] = "--sidecar-scopings"; fl["Traffic"] = "--traffic-configs"
				for (i = 2; i <= n; i++) {
					if (!(q = index(part[i], ": "))) continue
					l = substr(part[i], 1, q - 1); v = substr(part[i], q + 2)
					gsub(/ +/, ",", v)
					if ((l in fl) && v != "") out = out (out == "" ? "" : " ") fl[l] " " v
				}
				print out
				exit
			}' "$_rp1_tsv" 2>/dev/null)" || _rp1=""
	fi
	# Refused below, once the dir is known to be a sweep dir (the checks of --resume first):
	# _rp1_none names the axis flags not given.
	_rp1_none=""
	if [[ -z "$_rp1" ]]; then
		((MESH_SIZES_FLAG)) || _rp1_none+=", --mesh-sizes"
		((SERVICE_COUNTS_FLAG)) || _rp1_none+=", --service-counts"
		((REPLICA_COUNTS_FLAG)) || _rp1_none+=", --replica-counts"
		((NAMESPACE_COUNTS_FLAG)) || _rp1_none+=", --namespace-counts"
		((SIDECAR_SCOPINGS_FLAG)) || _rp1_none+=", --sidecar-scopings"
		((TRAFFIC_CONFIGS_FLAG)) || _rp1_none+=", --traffic-configs"
		_rp1_none="${_rp1_none#, }"
	fi
	_rp1w=()
	read -r -a _rp1w <<<"$_rp1" || true
	for ((_rp_i = 0; _rp_i + 1 < ${#_rp1w[@]}; _rp_i += 2)); do
		case "${_rp1w[_rp_i]}" in
		--mesh-sizes) _rp_given="$MESH_SIZES_FLAG" _rp_c=MESH_SIZES_CSV ;;
		--service-counts) _rp_given="$SERVICE_COUNTS_FLAG" _rp_c=SERVICE_COUNTS_CSV ;;
		--replica-counts) _rp_given="$REPLICA_COUNTS_FLAG" _rp_c=REPLICA_COUNTS_CSV ;;
		--namespace-counts) _rp_given="$NAMESPACE_COUNTS_FLAG" _rp_c=NAMESPACE_COUNTS_CSV ;;
		--sidecar-scopings) _rp_given="$SIDECAR_SCOPINGS_FLAG" _rp_c=SIDECAR_SCOPINGS_CSV ;;
		--traffic-configs) _rp_given="$TRAFFIC_CONFIGS_FLAG" _rp_c=TRAFFIC_CONFIGS_CSV ;;
		*) continue ;;
		esac
		if ((_rp_given)); then continue; fi
		printf -v "$_rp_c" '%s' "${_rp1w[_rp_i + 1]}"
		RESUME_PLAN1_TOOK+="${RESUME_PLAN1_TOOK:+ }${_rp1w[_rp_i]} ${_rp1w[_rp_i + 1]}"
	done
	[[ -z "$RESUME_PLAN1_TOOK" ]] \
		|| echo "note: --resume: the axis flags not given take the first run's values (${_rp1_src}): ${RESUME_PLAN1_TOOK}" >&2
fi

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_contexts "$CONTEXTS_CSV" CONTEXTS --contexts
else
	split_contexts "$SETUP_CONTEXTS" CONTEXTS SETUP_CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

MESH_SIZES=()
if [[ -n "$MESH_SIZES_CSV" ]]; then
	split_csv "$MESH_SIZES_CSV" MESH_SIZES
else
	for ((i = 1; i <= ${#CONTEXTS[@]}; i++)); do
		MESH_SIZES+=("$i")
	done
fi
((${#MESH_SIZES[@]})) || die "no mesh sizes resolved"

SERVICE_COUNTS=()
split_csv "$SERVICE_COUNTS_CSV" SERVICE_COUNTS
((${#SERVICE_COUNTS[@]})) || die "--service-counts produced an empty list"

REPLICA_COUNTS=()
split_csv "$REPLICA_COUNTS_CSV" REPLICA_COUNTS
((${#REPLICA_COUNTS[@]})) || die "--replica-counts produced an empty list"

NAMESPACE_COUNTS=()
split_csv "$NAMESPACE_COUNTS_CSV" NAMESPACE_COUNTS
((${#NAMESPACE_COUNTS[@]})) || die "--namespace-counts produced an empty list"

SCOPINGS=()
split_csv "$SIDECAR_SCOPINGS_CSV" SCOPINGS
((${#SCOPINGS[@]})) || die "--sidecar-scopings produced an empty list"

TRAFFIC_CONFIGS=()
split_csv "$TRAFFIC_CONFIGS_CSV" TRAFFIC_CONFIGS
((${#TRAFFIC_CONFIGS[@]})) || die "--traffic-configs produced an empty list"

MAX_MESH_SIZE=0
for ms in "${MESH_SIZES[@]}"; do
	is_pos_int "$ms" || die "mesh-size '$ms' is not a positive integer"
	((ms >= 1 && ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
	((ms > MAX_MESH_SIZE)) && MAX_MESH_SIZE="$ms"
done
for sc in "${SERVICE_COUNTS[@]}"; do
	is_pos_int "$sc" || die "service-count '$sc' is not a positive integer"
done
for rc in "${REPLICA_COUNTS[@]}"; do
	is_pos_int "$rc" || die "replica-count '$rc' is not a positive integer"
done
for nc in "${NAMESPACE_COUNTS[@]}"; do
	is_pos_int "$nc" || die "namespace-count '$nc' is not a positive integer"
done
for scp in "${SCOPINGS[@]}"; do
	validate_scoping "$scp"
done
is_pos_int "$VSDR_EVERY" || die "--vsdr-every must be a positive integer (got: $VSDR_EVERY)"
is_pos_int "$VSDR_SUBSETS" || die "--vsdr-subsets must be a positive integer (got: $VSDR_SUBSETS)"
case "$VSDR_APPLY" in together | split) ;; *) die "--vsdr-apply must be together or split (got: $VSDR_APPLY)" ;; esac
# The rows' window kind: a split apply measures the VS/DR apply alone.
LEGACY_WINDOW_KIND=deploy
[[ "$VSDR_APPLY" == split ]] && LEGACY_WINDOW_KIND=traffic
HAS_VSDR=0
for tc in "${TRAFFIC_CONFIGS[@]}"; do
	validate_traffic_config "$tc"
	[[ "$tc" == vsdr ]] && HAS_VSDR=1
done

# Namespace scaling (growth mode): any K > 0 turns the sweep into growth series.
SPNS=()
split_csv "$SPN_CSV" SPNS
((${#SPNS[@]})) || die "--services-per-namespaces produced an empty list"
GROWTH=0
for k in "${SPNS[@]}"; do
	is_nonneg_int "$k" || die "services-per-namespace '$k' is not a non-negative integer"
	((k > 0)) && GROWTH=1
done
M_LIST=()
OUTSIDE_PHASES=()
if ((GROWTH)); then
	for k in "${SPNS[@]}"; do
		((k > 0)) || die "--services-per-namespaces mixes 0 (the legacy sweep) with growth series; run them separately"
	done
	# One series per mesh size x K: the report keys a series by RUN_ID, mesh size, K and
	# workload, so a repeated value would merge two series into one curve.
	[[ "$(printf '%s\n' "${SPNS[@]}" | sort -u | grep -c .)" == "${#SPNS[@]}" ]] \
		|| die "--services-per-namespaces repeats a value (${SPN_CSV}): each K is one growth series"
	[[ "$(printf '%s\n' "${MESH_SIZES[@]}" | sort -u | grep -c .)" == "${#MESH_SIZES[@]}" ]] \
		|| die "--mesh-sizes repeats a value ($(IFS=,; echo "${MESH_SIZES[*]}")): each mesh size is one growth series per K"
	((SERVICE_COUNTS_FLAG)) && die "--service-counts conflicts with --services-per-namespaces: a growth series has namespaces x services-per-namespace services"
	[[ -z "$RESUME_DIR" ]] || die "--resume is not supported for growth series; start a new sweep (one per series if needed)"
	case "$GROWTH_MODE" in in-place | fresh) ;; *) die "--growth must be in-place or fresh (got: $GROWTH_MODE)" ;; esac
	validate_workload_mode "$WORKLOAD_MODE"
	split_csv "$MEASUREMENT_POD_COUNTS_CSV" M_LIST
	((${#M_LIST[@]})) || die "--measurement-pod-counts produced an empty list"
	prev_m=0
	for m in "${M_LIST[@]}"; do
		is_pos_int "$m" || die "measurement-pod count '$m' is not a positive integer"
		((m > prev_m)) || die "--measurement-pod-counts must be strictly ascending (the M-sweep only adds measurement pods): ${MEASUREMENT_POD_COUNTS_CSV}"
		prev_m="$m"
	done
	if ((${#M_LIST[@]} > 1)) && [[ "$WORKLOAD_MODE" != config-only || "$GROWTH_MODE" != in-place ]]; then
		die "an M-sweep (several --measurement-pod-counts) needs --workload-mode config-only and --growth in-place"
	fi
	is_nonneg_int "$OUTSIDE_NAMESPACES" || die "--outside-namespaces must be a non-negative integer (got: $OUTSIDE_NAMESPACES)"
	_omodes=()
	split_csv "$OUTSIDE_MODES_CSV" _omodes
	for om in ${_omodes[@]+"${_omodes[@]}"}; do
		validate_outside_mode "$om"
		[[ "$om" == none ]] || OUTSIDE_PHASES+=("$om")
	done
	if ((${#OUTSIDE_PHASES[@]})); then
		((OUTSIDE_NAMESPACES > 0)) || die "--outside-modes ${OUTSIDE_MODES_CSV} needs --outside-namespaces > 0"
		[[ "$GROWTH_MODE" == in-place ]] || die "the outside phase (--outside-modes) runs with --growth in-place only"
	elif ((OUTSIDE_NAMESPACES > 0)); then
		echo "note: --outside-namespaces ${OUTSIDE_NAMESPACES} without an --outside-modes phase (unlabeled,labeled) adds nothing" >&2
	fi
	is_nonneg_int "$PROBE_SETTLE_SEC" || die "--probe-settle must be a non-negative integer (got: $PROBE_SETTLE_SEC)"
	[[ "$MEM_STOP_PCT" =~ ^(0|[1-9][0-9]?|100)$ ]] || die "--mem-stop-pct must be an integer 0-100 (got: $MEM_STOP_PCT)"
	case "$SERIES_RETIRE" in undiscover | delete | keep) ;; *) die "--series-retire must be undiscover, delete or keep (got: $SERIES_RETIRE)" ;; esac
	if [[ "$SERIES_RETIRE" == keep && "$GROWTH_MODE" == in-place ]] && (( ${#MESH_SIZES[@]} * ${#SPNS[@]} > 1 )); then
		die "--series-retire keep leaves a series discovered, so every later series of this sweep would run on top of it (BACKLOG 9.3/9.10); run one series per sweep with keep"
	fi
	[[ "$NS_DELETE_SEC_PER_NS" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]] || die "CONTROLPLANE_NS_DELETE_SEC_PER_NS must be a non-negative number (got: $NS_DELETE_SEC_PER_NS)"
	is_pos_int "$RETIRE_ATTEMPTS" || die "CONTROLPLANE_RETIRE_ATTEMPTS must be a positive integer (got: $RETIRE_ATTEMPTS)"
	is_nonneg_int "$RETIRE_BACKOFF_S" || die "CONTROLPLANE_RETIRE_BACKOFF_S must be a non-negative integer (got: $RETIRE_BACKOFF_S)"
	is_nonneg_int "$LEFTOVER_NS_WARN" || die "CONTROLPLANE_LEFTOVER_NS_WARN must be a non-negative integer (got: $LEFTOVER_NS_WARN)"
	for _gk in CONTROLPLANE_GW_MI_INTERCEPT:"$GW_MI_INTERCEPT" CONTROLPLANE_EWGW_MI_PER_1000_SVC:"$EWGW_MI_PER_1000" \
		CONTROLPLANE_INGW_MI_PER_1000_SVC:"$INGW_MI_PER_1000" CONTROLPLANE_EWGW_BURST_FACTOR:"$EWGW_BURST" \
		CONTROLPLANE_INGW_BURST_FACTOR:"$INGW_BURST"; do
		[[ "${_gk#*:}" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]] || die "${_gk%%:*} must be a non-negative number (got: ${_gk#*:})"
	done
	for _gk in "$EWGW_BURST" "$INGW_BURST"; do
		awk -v f="$_gk" 'BEGIN { exit !(f + 0 >= 1) }' || die "a gateway burst factor below 1 would project less than the steady state (got: $_gk)"
	done
	for scp in "${SCOPINGS[@]}"; do
		[[ "$scp" != explicit ]] || die "growth series do not support --sidecar-scopings explicit (use none, namespace and/or wide)"
	done
	for tc in "${TRAFFIC_CONFIGS[@]}"; do
		[[ "$tc" == none ]] || die "growth series do not support --traffic-configs vsdr"
	done
	[[ "$VSDR_APPLY" == together ]] || die "--vsdr-apply split is for the legacy sweep (growth series have no VS/DR)"
	((${#REPLICA_COUNTS[@]} == 1)) || die "growth series take one --replica-counts value (got: ${REPLICA_COUNTS_CSV})"
	# The ladder of N runs ascending (in place, each step adds namespaces).
	_sorted_ns="$(printf '%s\n' "${NAMESPACE_COUNTS[@]}" | sort -n -u | awk '{ printf "%s%s", (NR > 1 ? "," : ""), $0 }')"
	if [[ "$_sorted_ns" != "$(IFS=,; echo "${NAMESPACE_COUNTS[*]}")" ]]; then
		echo "note: growth series run --namespace-counts ascending without repeats: ${_sorted_ns}" >&2
	fi
	split_csv "$_sorted_ns" NAMESPACE_COUNTS
else
	# Each value of an axis is one set of cells; a repeated one would run them twice
	# under one key (combo_already_done and the outcome count it once), as growth refuses.
	for _ax in "--mesh-sizes:${MESH_SIZES[*]}" "--service-counts:${SERVICE_COUNTS[*]}" \
		"--replica-counts:${REPLICA_COUNTS[*]}" "--namespace-counts:${NAMESPACE_COUNTS[*]}" \
		"--sidecar-scopings:${SCOPINGS[*]}" "--traffic-configs:${TRAFFIC_CONFIGS[*]}"; do
		_axv="${_ax#*:}"
		[[ "$(tr ' ' '\n' <<<"$_axv" | sort -u | grep -c .)" == "$(tr ' ' '\n' <<<"$_axv" | grep -c .)" ]] \
			|| die "${_ax%%:*} repeats a value (${_axv// /,}): each value is one set of cells; list it once"
	done
	# Sizes the leftover cleanup's --timeout (legacy_leftover_preflight).
	[[ "$NS_DELETE_SEC_PER_NS" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]] || die "CONTROLPLANE_NS_DELETE_SEC_PER_NS must be a non-negative number (got: $NS_DELETE_SEC_PER_NS)"
	for sc in "${SERVICE_COUNTS[@]}"; do
		for nc in "${NAMESPACE_COUNTS[@]}"; do
			(( nc <= sc )) || die "namespace-count $nc > service-count $sc; some namespaces would be empty. Reduce --namespace-counts to at most --service-counts."
		done
	done
fi

if ((GROWTH)); then
	# Cells per series: in-place = each step's grow window plus one probe per scoping,
	# each outside phase's window plus its probes, and the M-sweep's probes; fresh =
	# one deploy cell per N x scoping.
	_S=${#SCOPINGS[@]}
	_NN=${#NAMESPACE_COUNTS[@]}
	_NO=${#OUTSIDE_PHASES[@]}
	_NM=$(( ${#M_LIST[@]} - 1 ))
	if [[ "$GROWTH_MODE" == in-place ]]; then
		CELLS_PER_SERIES=$(( _NN * (1 + _S) + _NO * (1 + _S) + _NM * _S ))
		MATRIX_FACTORS="${#MESH_SIZES[@]} mesh × ${#SPNS[@]} K × (${_NN} steps × (1 grow + ${_S} probes) + ${_NO} outside × (1 + ${_S}) + ${_NM} M-sweep × ${_S})"
	else
		CELLS_PER_SERIES=$(( _NN * _S ))
		MATRIX_FACTORS="${#MESH_SIZES[@]} mesh × ${#SPNS[@]} K × ${_NN} N × ${_S} scope (fresh)"
	fi
	MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#SPNS[@]} * CELLS_PER_SERIES ))
else
	MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#SERVICE_COUNTS[@]} * ${#REPLICA_COUNTS[@]} * ${#NAMESPACE_COUNTS[@]} * ${#SCOPINGS[@]} * ${#TRAFFIC_CONFIGS[@]} ))
	MATRIX_FACTORS="${#MESH_SIZES[@]}×${#SERVICE_COUNTS[@]}×${#REPLICA_COUNTS[@]}×${#NAMESPACE_COUNTS[@]}×${#SCOPINGS[@]}×${#TRAFFIC_CONFIGS[@]}"
fi

SCRIPT_DIR="${ROOT}/tests/controlplane"

# Resume reuses the dir + RUN_ID (002 appends to the same TSV); otherwise mint a
# fresh RUN_ID and sweep-<RUN_ID>/ subdir.
if [[ -n "$RESUME_DIR" ]]; then
	((DRY_RUN)) && die "--resume is not valid with --dry-run (nothing to resume in a plan-only run)"
	[[ -d "$RESUME_DIR" ]] || die "--resume: sweep dir not found: $RESUME_DIR"
	# A symlink such as latest -> sweep-X resumes sweep-X (find -H reads through it);
	# anything else that is not a sweep-<RUN_ID> dir is refused, since its rows would go
	# into a second TSV next to the first one, and the report would pool them.
	OUTPUT_DIR="$(_config_canon_dir "$RESUME_DIR")"
	case "${OUTPUT_DIR##*/}" in
	sweep-?*) ;;
	*)
		# A results dir holding sweeps (the usual mistake): name the newest (a RUN_ID
		# starts with its UTC start time, so the last by name).
		_resume_newest=""
		for _resume_cand in "${RESUME_DIR%/}"/sweep-?*; do [[ ! -d "$_resume_cand" ]] || _resume_newest="$_resume_cand"; done
		[[ -z "$_resume_newest" ]] || die "--resume: ${RESUME_DIR} is not a sweep-<RUN_ID> directory, nor a symlink to one. It holds sweep directories; the newest is ${_resume_newest}: pass that one (or another sweep-<RUN_ID> in it) to resume it."
		die "--resume: ${RESUME_DIR} is not a sweep-<RUN_ID> directory, nor a symlink to one (pass the sweep dir 003 created, such as ${CONTROLPLANE_RESULTS_DIR}/sweep-<RUN_ID>)"
		;;
	esac
	# The rows' own timestamp format, so "rows from <this> on" finds them directly.
	RESUME_AT="$(date -u -Iseconds)"
	RESUME_AT_Z="${RESUME_AT%+00:00}Z"
	# Recover RUN_ID from the existing TSV (controlplane-<RUN_ID>.tsv); fall back to
	# the sweep-<RUN_ID> dir name. RUN_ID must match so 002 appends to the same TSV
	# and the report/envelope filenames line up with the originals.
	_existing_tsv="$(find -H "$OUTPUT_DIR" -maxdepth 1 -name 'controlplane-*.tsv' -type f 2>/dev/null | sort | head -1)"
	if [[ -n "$_existing_tsv" ]]; then
		RUN_ID="$(basename "$_existing_tsv")"; RUN_ID="${RUN_ID#controlplane-}"; RUN_ID="${RUN_ID%.tsv}"
	else
		RUN_ID="$(basename "$OUTPUT_DIR")"; RUN_ID="${RUN_ID#sweep-}"
	fi
	[[ -n "$RUN_ID" ]] || die "--resume: could not recover RUN_ID from $RESUME_DIR (no controlplane-*.tsv and dir is not sweep-<RUN_ID>)"
	[[ -z "${_rp1_none:-}" ]] \
		|| die "--resume: ${RESUME_DIR} records none of its first run's axis values (no planned-cells.txt from its first run, no \"# Contexts:\" line in a controlplane-*.tsv), so a --resume would run the environment's, --config's or default value of each axis flag not given; nothing was run. Give all six axis flags the sweep ran with (not given: ${_rp1_none})."
	# One run per sweep dir: a --resume while the run it resumes (or another resume) still
	# runs there is refused here, before it reads or moves anything in the dir (sweep_lock;
	# a first run takes the lock in sweep_outcome_start). --release-on-exit: until the
	# sweep's own EXIT trap (below), a resume that stops on a precondition releases the lock
	# it took (only its own), so the next run finds none.
	sweep_lock --release-on-exit "$OUTPUT_DIR"
	echo "Resuming sweep RUN_ID=${RUN_ID} in ${OUTPUT_DIR} (cells already measured are skipped; failed, INCOMPLETE and INTERRUPTED ones run again)" >&2
else
	RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
	OUTPUT_DIR="${OUTPUT_DIR_BASE}/sweep-${RUN_ID}"
fi
# The harness at this run's start, for the preambles it writes and its sweep-outcome.txt (a
# resume appends to a TSV whose preamble keeps the first run's). harness_sha_for_sweep
# exports the results dir, never the value: each step records the live harness without it,
# and a harness that changes during the sweep is a problem in its outcome (exit 4).
if [[ -n "$RESUME_DIR" ]]; then
	harness_sha_for_sweep "$(dirname "$OUTPUT_DIR")"
else
	harness_sha_for_sweep "$OUTPUT_DIR_BASE"
fi

# combo_already_done <mesh> <svc> <rep> <ns> <scope> <traffic>: true if the resumed sweep
# already measured that cell: its latest attempt (controlplane_latest_attempts) has a
# valid row (the report's n_valid gate) and its last row is not a status row. A cell whose
# last row is a status row (one that failed partway included) runs again, and the reports
# then use only that new attempt. Read once, before the first cell (RESUME_DONE, below);
# keyed with the window kind the sweep measures. The VS/DR scalars are not part of the key:
# --resume pins them to the preamble's values (below).
declare -A RESUME_DONE=() RESUME_RERUN=()
RERUN_RAN=0
combo_already_done() {
	[[ -n "$RESUME_DIR" ]] || return 1
	[[ -n "${RESUME_DONE["${1}|${2}|${3}|${4}|${5}|${6}"]+x}" ]]
}

# planned-cells.txt in the sweep dir: the cells each run of a (legacy) sweep planned,
# keyed as combo_already_done keys a cell, each run's below a "# PLAN=<n> <who>: <axis
# flags>" line, and the TSV it applies to ("# TSV=controlplane-<RUN_ID>.tsv"). The first run
# writes it before its first cell; each --resume adds the cells of its matrix not listed yet
# (a cell no earlier run planned only with --extend-plan). A sweep an older harness started
# has none: a resume then starts it with "# PLANNED_SET=partial" (the first run's plan is
# not known), and every outcome after says so.
PLANNED_FILE="${OUTPUT_DIR}/planned-cells.txt"
PLANNED_PARTIAL=0
# planned_axis_flags: this run's axis flags, as a --resume repeats them.
planned_axis_flags() {
	printf -- '--mesh-sizes %s --service-counts %s --replica-counts %s --namespace-counts %s --sidecar-scopings %s --traffic-configs %s' \
		"$(IFS=,; echo "${MESH_SIZES[*]}")" "$(IFS=,; echo "${SERVICE_COUNTS[*]}")" "$(IFS=,; echo "${REPLICA_COUNTS[*]}")" \
		"$(IFS=,; echo "${NAMESPACE_COUNTS[*]}")" "$(IFS=,; echo "${SCOPINGS[*]}")" "$(IFS=,; echo "${TRAFFIC_CONFIGS[*]}")"
}
# resume_cmd_console <axis_flags>: the full command that resumes this sweep with those axis
# flags (controlplane_resume_cmd), for the console: its sweep dir, and the run config it
# needs (its run-config-<RUN_ID>.env replay copy, else the --config this run was given), as
# local paths. resume_cmd_record: the same for a shared record (sweep-outcome.txt): no
# local path ("<sweep dir>").
resume_cmd_console() {
	local cfg=""
	if [[ "${RUN_CONFIG:-none}" != none ]]; then
		cfg="${OUTPUT_DIR}/run-config-${RUN_ID}.env"
		[[ -f "$cfg" || -z "${RUN_CONFIG_PATH:-}" ]] || cfg="$RUN_CONFIG_PATH"
		cfg="$(printf '%q' "$cfg")"
	fi
	controlplane_resume_cmd "$(printf '%q' "$OUTPUT_DIR")" "$(IFS=,; echo "${CONTEXTS[*]}")" "$1" "$cfg"
}
resume_cmd_record() {
	local cfg=""
	[[ "${RUN_CONFIG:-none}" == none ]] || cfg="<sweep dir>/run-config-${RUN_ID}.env"
	controlplane_resume_cmd "<sweep dir>" "$(IFS=,; echo "${CONTEXTS[*]}")" "$1" "$cfg"
}
# matrix_cell_keys: this run's legacy matrix, one tab-separated key per line.
matrix_cell_keys() {
	local ms sc rc nc scp tc
	for ms in "${MESH_SIZES[@]}"; do for sc in "${SERVICE_COUNTS[@]}"; do for rc in "${REPLICA_COUNTS[@]}"; do
		for nc in "${NAMESPACE_COUNTS[@]}"; do for scp in "${SCOPINGS[@]}"; do for tc in "${TRAFFIC_CONFIGS[@]}"; do
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ms" "$sc" "$rc" "$nc" "$scp" "$tc" "$LEGACY_WINDOW_KIND"
		done; done; done
	done; done; done
}
# planned_cells_record: write or extend PLANNED_FILE (before the first cell; a precondition:
# a plan that cannot be recorded stops the run before any cluster change).
planned_cells_record() {
	local add n who
	if [[ ! -f "$PLANNED_FILE" ]]; then
		{
			echo "# Planned cells of controlplane sweep ${RUN_ID} (tests/controlplane/003-run-sweep.sh): each run's matrix, keyed as --resume keys a cell; a planned cell without a row in the TSV counts as NOT_RUN"
			# The TSV the plan applies to (004 applies it to no other TSV in the dir). printf: a
			# planned-cells line, not a TSV preamble key.
			printf '# TSV=controlplane-%s.tsv\n' "$RUN_ID"
			if [[ -n "$RESUME_DIR" && -f "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" ]]; then
				# printf: a planned-cells line, not a TSV preamble key (the PL36 key-set lint
				# greps echo).
				printf '%s\n' "# PLANNED_SET=partial: an older harness started this sweep without this file, so the cells its first run planned are not known"
			fi
			printf 'mesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\ttraffic_config\twindow_kind\n'
		} > "$PLANNED_FILE" || die "could not write ${PLANNED_FILE}, which records the cells this sweep plans; nothing was run."
	fi
	! grep -q '^# PLANNED_SET=partial' "$PLANNED_FILE" || PLANNED_PARTIAL=1
	add="$(matrix_cell_keys | awk -F'\t' 'NR == FNR { if (!/^#/) seen[$0] = 1; next } !($0 in seen) && !(dup[$0]++)' "$PLANNED_FILE" -)" \
		|| die "could not read ${PLANNED_FILE}; nothing was run."
	[[ -n "$add" ]] || return 0
	n="$(grep -c '^# PLAN=' "$PLANNED_FILE" || true)"
	who="the first run"
	[[ -z "$RESUME_DIR" ]] || who="the --resume at ${RESUME_AT_Z}"
	{
		printf '# PLAN=%s %s: %s\n' "$((n + 1))" "$who" "$(planned_axis_flags)"
		printf '%s\n' "$add"
	} >> "$PLANNED_FILE" || die "could not append to ${PLANNED_FILE}, which records the cells this sweep plans; nothing was run."
}

# The 66-column TSV schema header. 002 writes the same literal when it runs
# standalone; tests/lib/test/preamble.bats checks that the two are identical.
CONTROLPLANE_TSV_HEADER="timestamp\tcontext\tmesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\tistiod_mem_mi\tconvergence_p50_ms\tconvergence_p99_ms\tqueue_p50_ms\tqueue_p99_ms\txds_pushes_delta\txds_pushes_rate\txds_pushes_cds\txds_pushes_eds\txds_pushes_lds\txds_pushes_rds\txds_pushes_nds\tk8s_events_delta\tk8s_events_rate\tconnected_proxies\tconfig_size_avg_bytes\tsidecar_config_bytes_avg\tsidecar_config_bytes_p50\tsidecar_config_bytes_max\tsidecar_config_bytes_samples\tscrape_window_sec\tscrape_skew_ms\tsettle_sec\tistiod_restarted\tistiod_cpu_m_delta\tgo_heap_alloc_mi\tgo_heap_inuse_mi\tistiod_cpu_pct_of_limit\tistiod_mem_pct_of_limit\tnode_cpu_pct\tnode_mem_pct\tpods_scheduled\tpods_allocatable\tcluster_connected_proxies\tsidecar_pods\tproxy_check\ttraffic_config\tvsdr_services\tistiod_virt_services\tpush_time_avg_ms\tpushcontext_init_avg_ms\tsidecar_clusters_avg\tsidecar_cds_bytes_avg\tsidecar_rds_bytes_avg\tservices_per_namespace\tworkload_mode\tmeasurement_pods\toutside_namespaces\toutside_discovery\twindow_kind\tistiod_services\tistiod_cpu_s_delta\tsidecar_mem_mi_avg\tgateway_clusters_max\tgateway_mem_mi_max\troot_cert_configmaps\tgateway_physical_mi_max\tgateway_ws_mi_max\tleftover_test_namespaces"
CONTROLPLANE_TSV_WIDTH="$(echo -e "$CONTROLPLANE_TSV_HEADER" | awk -F'\t' '{ print NF }')"

# --resume appends to the existing TSV, so its header must have this harness's width;
# otherwise the file would mix row widths. Start a new sweep across a schema change.
if [[ -n "$RESUME_DIR" ]]; then
	_resume_tsv="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
	if [[ -f "$_resume_tsv" ]]; then
		_resume_width="$(grep -m1 '^timestamp' "$_resume_tsv" | awk -F'\t' '{ print NF }')" || _resume_width=""
		if [[ -n "$_resume_width" && "$_resume_width" != "$CONTROLPLANE_TSV_WIDTH" ]]; then
			die "--resume: $_resume_tsv has a ${_resume_width}-column header, but this harness writes ${CONTROLPLANE_TSV_WIDTH} columns. Start a new sweep instead of resuming across a schema change."
		fi
		# Sweep-level scalars live only in the preamble (pre-create skips an existing
		# one), so the resumed rows must use the recorded values; the report reads them
		# for every row. The VS/DR pair matters only when this run has vsdr cells.
		if [[ -n "$_resume_width" ]]; then
			resume_preamble_scalar "$_resume_tsv" PROXY_CHECK_TOLERANCE_PCT PROXY_CHECK_TOL_PCT CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT 0
			resume_preamble_scalar "$_resume_tsv" PROXY_CHECK_MIN_DIFF PROXY_CHECK_MIN_DIFF CONTROLPLANE_PROXY_CHECK_MIN_DIFF 0
			is_nonneg_int "$PROXY_CHECK_TOL_PCT" || die "--resume: PROXY_CHECK_TOLERANCE_PCT in $_resume_tsv is not a non-negative integer: $PROXY_CHECK_TOL_PCT"
			is_nonneg_int "$PROXY_CHECK_MIN_DIFF" || die "--resume: PROXY_CHECK_MIN_DIFF in $_resume_tsv is not a non-negative integer: $PROXY_CHECK_MIN_DIFF"
			# 002 reads these from the environment.
			export CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT="$PROXY_CHECK_TOL_PCT"
			export CONTROLPLANE_PROXY_CHECK_MIN_DIFF="$PROXY_CHECK_MIN_DIFF"
			if grep -q '^# VSDR_APPLY=' "$_resume_tsv"; then
				resume_preamble_scalar "$_resume_tsv" VSDR_APPLY VSDR_APPLY --vsdr-apply "$VSDR_APPLY_FLAG"
				LEGACY_WINDOW_KIND=deploy
				[[ "$VSDR_APPLY" == split ]] && LEGACY_WINDOW_KIND=traffic
			fi
			if ((HAS_VSDR)); then
				resume_preamble_scalar "$_resume_tsv" VSDR_EVERY VSDR_EVERY --vsdr-every "$VSDR_EVERY_FLAG"
				resume_preamble_scalar "$_resume_tsv" VSDR_SUBSETS VSDR_SUBSETS --vsdr-subsets "$VSDR_SUBSETS_FLAG"
				is_pos_int "$VSDR_EVERY" || die "--resume: VSDR_EVERY in $_resume_tsv is not a positive integer: $VSDR_EVERY"
				is_pos_int "$VSDR_SUBSETS" || die "--resume: VSDR_SUBSETS in $_resume_tsv is not a positive integer: $VSDR_SUBSETS"
			fi
		fi
	fi
fi

# --resume keeps the TSV preamble the sweep started with, RUN_CONFIG* included, so the
# new rows must come from that config. A sweep that started with --config resumes only
# with the same file (same sha256): without --config the axes would fall back to
# env/defaults, and another file would build a different matrix, either way appended
# under the recorded RUN_CONFIG. The preamble decides; the snapshot (best effort) only
# counts for a sweep whose TSV has no preamble yet. A sweep that started without one
# (RUN_CONFIG=none) still resumes with any --config, with a warning.
if [[ -n "$RESUME_DIR" ]]; then
	_resume_snapshot="${OUTPUT_DIR}/run-config-${RUN_ID}.env"
	_resume_cfg="" _resume_sha="" _resume_with_cfg=0
	if [[ -f "$_resume_tsv" ]]; then
		_resume_cfg="$(awk -v k="# RUN_CONFIG=" '/^timestamp\t/ { exit } index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$_resume_tsv")"
		_resume_sha="$(awk -v k="# RUN_CONFIG_SHA256=" '/^timestamp\t/ { exit } index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$_resume_tsv")"
	fi
	if [[ -n "$_resume_cfg" && "$_resume_cfg" != none ]]; then
		_resume_with_cfg=1
	elif [[ -z "$_resume_cfg" && -f "$_resume_snapshot" ]]; then
		_resume_with_cfg=1
		_resume_cfg="$(basename "$_resume_snapshot")"
		_resume_sha="$(_config_sha256 "$_resume_snapshot")"
	fi
	_resume_hint=""
	if [[ -f "$_resume_snapshot" ]]; then
		_resume_hint=" To resume with the same values, add --config $(printf '%q' "$_resume_snapshot"):
  $(printf '%q' "$0") --resume $(printf '%q' "$RESUME_DIR") --config $(printf '%q' "$_resume_snapshot")"
	fi
	if ((_resume_with_cfg)) && [[ "${RUN_CONFIG:-none}" == none ]]; then
		[[ -f "$_resume_snapshot" ]] && die "--resume: this sweep was started with --config ${_resume_cfg}; without it the axes and settings fall back to the environment and defaults, and the new rows would not match the recorded RUN_CONFIG.${_resume_hint}"
		die "--resume: this sweep was started with --config ${_resume_cfg} (RUN_CONFIG_SHA256=${_resume_sha:-not recorded}), and its snapshot ${_resume_snapshot} is missing. Pass --config with that file (the sha256 must match), or start a new sweep."
	elif ((_resume_with_cfg)) && [[ "$_resume_sha" != "${RUN_CONFIG_SHA256:-none}" ]]; then
		die "--resume: --config ${RUN_CONFIG} (sha256 ${RUN_CONFIG_SHA256:0:12}) is not the config this sweep started with (${_resume_cfg}, RUN_CONFIG_SHA256=${_resume_sha:-not recorded}); its rows would be credited to a config that did not produce them. Pass the original file, or start a new sweep.${_resume_hint}"
	elif ((!_resume_with_cfg)) && [[ "${RUN_CONFIG:-none}" != none ]]; then
		echo "warning: --resume: --config ${RUN_CONFIG} (sha256 ${RUN_CONFIG_SHA256:0:12}) is not the config this sweep started with (RUN_CONFIG_SHA256=${_resume_sha:-not recorded}). The TSV keeps the original provenance, and values recorded only in its preamble (SETTLE_SEC, CONFIG_DUMP_SAMPLES, ...) may not match the new rows." >&2
	fi
fi

# Each DestinationRule subset needs at least one pod, at every replica count in the
# sweep. Checked after --resume, which can adopt the recorded --vsdr-subsets.
if ((HAS_VSDR)); then
	for rc in "${REPLICA_COUNTS[@]}"; do
		(( VSDR_SUBSETS <= rc )) || die "--vsdr-subsets $VSDR_SUBSETS > replica-count $rc: each DestinationRule subset needs at least one pod. Lower --vsdr-subsets or drop replica counts below it."
	done
fi

# Pre-create controlplane-${RUN_ID}.tsv with the full preamble before the first
# combo, so provenance survives a first-combo failure; 002 and the failed-row
# emitter only append.
precreate_tsv_preamble() {
	local tsv="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
	[[ -f "$tsv" ]] && grep -q '^timestamp' "$tsv" 2>/dev/null && return 0
	mkdir -p "$OUTPUT_DIR"
	local kver
	kver="$(probe_kube_versions "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
	# Capacity provenance (read-only, source context; `unknown` on failure). These
	# are the report's denominators for the "Achieved scale vs capacity" block.
	local src_ctx="${CONTEXTS[0]}"
	local node_alloc_cpu_m="unknown" node_alloc_mem_mi="unknown"
	local istiod_cpu_limit_m="unknown" istiod_mem_limit_mi="unknown"
	local kv
	# shellcheck disable=SC2207
	local -a nt_kv=($(cap_node_totals "$src_ctx" "${KUBECTL[@]}"))
	for kv in ${nt_kv[@]+"${nt_kv[@]}"}; do
		case "$kv" in
			cpu_m=*) node_alloc_cpu_m="${kv#cpu_m=}" ;;
			mem_mi=*) node_alloc_mem_mi="${kv#mem_mi=}" ;;
		esac
	done
	# shellcheck disable=SC2207
	local -a il_kv=($(cap_istiod_limits "$src_ctx" "${KUBECTL[@]}"))
	for kv in ${il_kv[@]+"${il_kv[@]}"}; do
		case "$kv" in
			cpu_m=*) istiod_cpu_limit_m="${kv#cpu_m=}" ;;
			mem_mi=*) istiod_mem_limit_mi="${kv#mem_mi=}" ;;
		esac
	done
	# Cluster-infra block via the shared emitter (same key set as 002's standalone preamble).
	local infra_kv
	infra_kv="$(env_collect_infra "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
	# Live tuning-baseline state from the source cluster (sweep-wide scalar).
	local tb_line="TUNING_BASELINE=unknown" eh_line="SIDECAR_EGRESS_HOSTS=unknown"
	local tb_kv
	while IFS= read -r tb_kv; do
		case "$tb_kv" in
			TUNING_BASELINE=*) tb_line="$tb_kv" ;;
			SIDECAR_EGRESS_HOSTS=*) eh_line="$tb_kv" ;;
		esac
	done < <(tuning_baseline_state "$src_ctx" "${KUBECTL[@]}")
	{
		echo "# Control-plane resource metrics — $(date -u -Iseconds)"
		echo "# CONTROLPLANE_SCHEMA=66"
		echo "# CONTROLPLANE_INFRA_SCHEMA=2"
		istio_version_kv | sed 's/^/# /'
		echo "# HARNESS_SHA=${HARNESS_SHA}"
		echo "# HARNESS_CONTENT_KEY=${HARNESS_CONTENT_KEY:-unknown}"
		echo "# KUBE_VERSIONS=${kver}"
		echo "# SETTLE_SEC=${SETTLE_SEC}"
		echo "# RUN_ID=${RUN_ID}"
		echo "# PHASE=sweep"
		echo "# SIDECAR_SCOPING=${SIDECAR_SCOPINGS_CSV}"
		echo "# CONFIG_DUMP_SAMPLES=${CONFIG_DUMP_SAMPLES}"
		echo "# NODE_ALLOC_CPU_M=${node_alloc_cpu_m}"
		echo "# NODE_ALLOC_MEM_MI=${node_alloc_mem_mi}"
		echo "# ISTIOD_CPU_LIMIT_M=${istiod_cpu_limit_m}"
		echo "# ISTIOD_MEM_LIMIT_MI=${istiod_mem_limit_mi}"
		echo "# SCALE_TARGET_FRACTION=${SCALE_TARGET_FRACTION:-unknown}"
		echo "# SCALE_SIZING_MODE=${SCALE_SIZING_MODE:-unknown}"
		echo "# PROXY_CHECK_TOLERANCE_PCT=${PROXY_CHECK_TOL_PCT}"
		echo "# PROXY_CHECK_MIN_DIFF=${PROXY_CHECK_MIN_DIFF}"
		echo "# TRAFFIC_CONFIG=${TRAFFIC_CONFIGS_CSV}"
		echo "# VSDR_EVERY=${VSDR_EVERY}"
		echo "# VSDR_SUBSETS=${VSDR_SUBSETS}"
		echo "# VSDR_APPLY=${VSDR_APPLY}"
		config_preamble_lines
		# Namespace-scaling keys through the emitter 002 uses too (PL36). A legacy sweep
		# records GROWTH_MODE=off.
		local growth_mode_key="off"
		((GROWTH)) && growth_mode_key="$GROWTH_MODE"
		growth_preamble_lines SERVICES_PER_NAMESPACE="$SPN_CSV" GROWTH_MODE="$growth_mode_key" \
			WORKLOAD_MODE="$WORKLOAD_MODE" MEASUREMENT_PODS="$MEASUREMENT_POD_COUNTS_CSV" \
			MEASUREMENT_PROXY_MEM_LIMIT="${CONTROLPLANE_MEASUREMENT_PROXY_MEM_LIMIT:-unknown}" \
			OUTSIDE_NAMESPACES="$OUTSIDE_NAMESPACES" OUTSIDE_MODES="$OUTSIDE_MODES_CSV" \
			PROBE_SETTLE_SEC="$PROBE_SETTLE_SEC" MEM_STOP_PCT="$MEM_STOP_PCT" \
			MEM_GUARD_CONTEXTS="$(IFS=,; echo "${GUARD_CONTEXTS[*]:-}")" SERIES_RETIRE="$SERIES_RETIRE" \
			DISCOVERY_LABEL=istio-discovery=enabled LEFTOVER_TEST_NAMESPACES="$LEFTOVER_AT_START" \
			LEFTOVER_NS_WARN="$LEFTOVER_NS_WARN"
		echo "# ${tb_line}"
		echo "# ${eh_line}"
		echo "# METRICS_API=${METRICS_API_STATUS:-unknown}"
		# shellcheck disable=SC2086
		infra_preamble_lines $infra_kv
		echo "# NOTE=preamble pre-created by 003-run-sweep.sh so provenance survives a first-combo setup/baseline failure"
		echo "# Contexts: ${CONTEXTS[*]}  Mesh sizes: ${MESH_SIZES[*]}  Services: ${SERVICE_COUNTS_CSV}  Replicas: ${REPLICA_COUNTS_CSV}  Namespaces: ${NAMESPACE_COUNTS_CSV}  Scopings: ${SIDECAR_SCOPINGS_CSV}  Traffic: ${TRAFFIC_CONFIGS_CSV}"
	} > "$tsv"
	echo -e "$CONTROLPLANE_TSV_HEADER" >> "$tsv"
}

# Plan-time capacity warning: compare the largest combo's sidecar CPU request
# (pods x the per-pod request) with the free node CPU of the tightest measured member
# (allocatable minus what other pods already request). The per-pod
# request is SCALE_PER_POD_CPU_M when set, else the live Istio CR's sidecar request
# (the test pods' app containers request nothing; BACKLOG 9.7), else Istio's 100m.
# Warn only; 001's preflight is the hard gate. Dry-run prints only the requested cores
# (no cluster contact).
capacity_plan_warn() {
	local ppr per_pod_cpu_m per_pod_src live
	if ((DRY_RUN)) || ! ((${#KUBECTL[@]})); then
		ppr="$(cap_per_pod_requests "" "${SCALE_PER_POD_CPU_M:-}" "${SCALE_PER_POD_MEM_MI:-}")"
	else
		ppr="$(cap_per_pod_requests "${CONTEXTS[0]}" "${SCALE_PER_POD_CPU_M:-}" "${SCALE_PER_POD_MEM_MI:-}" "${KUBECTL[@]}")"
	fi
	per_pod_cpu_m="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^cpu_m=/) print substr($i, 7) }' <<<"$ppr")"
	per_pod_src="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^cpu_src=/) print substr($i, 9) }' <<<"$ppr" | tr '_' ' ')"
	live="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^live=/) print substr($i, 6) }' <<<"$ppr")"
	if [[ -n "${SCALE_PER_POD_CPU_M:-}" && "$live" != none && "${live%%/*}" != "$per_pod_cpu_m" ]]; then
		per_pod_src="${per_pod_src}; the live Istio CR requests ${live%%/*}m, SCALE_PER_POD_CPU_M wins"
	fi
	# Largest combo: max service_count × max replica_count.
	local max_sc=0 max_rc=0 v
	for v in "${SERVICE_COUNTS[@]}"; do (( v > max_sc )) && max_sc="$v"; done
	for v in "${REPLICA_COUNTS[@]}"; do (( v > max_rc )) && max_rc="$v"; done
	local needed_pods=$(( max_sc * max_rc )) combo_label="${max_sc} svc × ${max_rc} rep"
	if ((GROWTH)); then
		# Growth series: pods mode runs every Service's pods at the largest step;
		# config-only runs only the measurement pods.
		local max_n=0 max_k=0 max_m="${M_LIST[${#M_LIST[@]}-1]}"
		for v in "${NAMESPACE_COUNTS[@]}"; do (( v > max_n )) && max_n="$v"; done
		for v in "${SPNS[@]}"; do (( v > max_k )) && max_k="$v"; done
		if [[ "$WORKLOAD_MODE" == config-only ]]; then
			needed_pods=$(( max_m < max_n ? max_m : max_n ))
			combo_label="config-only: ${needed_pods} measurement pods"
		else
			needed_pods=$(( max_n * max_k * max_rc ))
			combo_label="growth: ${max_n} namespaces × ${max_k} svc × ${max_rc} rep"
		fi
		max_sc=$(( max_n * max_k ))
	fi
	local needed_cpu_m=$(( needed_pods * per_pod_cpu_m ))
	echo "--- Capacity plan check (largest combo: ${combo_label}) ---" >&2
	echo "  requested: ${needed_pods} sidecar-pods × ${per_pod_cpu_m}m = ~$(awk -v m="$needed_cpu_m" 'BEGIN { printf "%.1f", m / 1000 }') cores/cluster (per pod: ${per_pod_src})" >&2

	if ((DRY_RUN)); then
		echo "  WARN: dry-run does not contact clusters; free-capacity comparison skipped. Run without --dry-run for the services-that-fit estimate." >&2
		echo "" >&2
		return 0
	fi
	(( ${#KUBECTL[@]} )) || { echo "  WARN: no oc/kubectl; cannot read node capacity for the fit estimate." >&2; echo "" >&2; return 0; }

	# cores <millicores>: one decimal (a few small pods must not read as "~0 cores").
	cores() { awk -v m="$1" 'BEGIN { printf "%.1f", m / 1000 }'; }
	# Free CPU per measured member = worker allocatable − the CPU other pods already
	# request (what the scheduler sees: OpenShift, istiod, gateways, monitoring). The
	# test's own pods are left out: needed_pods already counts the whole largest combo.
	# The tightest member decides. When the pod list is unreadable, fall back to
	# allocatable − istiod's limit × replicas, which overstates the free CPU.
	local ctx kv alloc_cpu_m workers req_cpu_m istiod_cpu_m istiod_rep free_cpu_m min_free="" min_ctx=""
	local -A seen=()
	for ctx in "${CONTEXTS[@]}"; do
		[[ -n "${seen[$ctx]:-}" ]] && continue
		seen[$ctx]=1
		alloc_cpu_m="" workers="" req_cpu_m="" istiod_cpu_m="" istiod_rep=""
		# shellcheck disable=SC2207
		local -a nt=($(cap_node_totals "$ctx" "${KUBECTL[@]}"))
		for kv in ${nt[@]+"${nt[@]}"}; do
			case "$kv" in
				cpu_m=*) alloc_cpu_m="${kv#cpu_m=}" ;;
				names=*) workers="${kv#names=}" ;;
			esac
		done
		if ! [[ "$alloc_cpu_m" =~ ^[0-9]+$ ]]; then
			echo "  $ctx: WARN: node allocatable CPU unreadable; left out of the fit estimate." >&2
			continue
		fi
		# shellcheck disable=SC2207
		local -a rq=($(cap_requested "$ctx" "$workers" "app.kubernetes.io/instance=controlplane-test" "${KUBECTL[@]}"))
		for kv in ${rq[@]+"${rq[@]}"}; do case "$kv" in cpu_m=*) req_cpu_m="${kv#cpu_m=}" ;; esac; done
		if [[ "$req_cpu_m" =~ ^[0-9]+$ ]]; then
			free_cpu_m=$(( alloc_cpu_m - req_cpu_m ))
			(( free_cpu_m < 0 )) && free_cpu_m=0
			echo "  $ctx: node alloc CPU ~$(cores "$alloc_cpu_m") cores; requested by other pods ~$(cores "$req_cpu_m") -> ~$(cores "$free_cpu_m") cores free" >&2
		else
			# shellcheck disable=SC2207
			local -a il=($(cap_istiod_limits "$ctx" "${KUBECTL[@]}"))
			for kv in ${il[@]+"${il[@]}"}; do
				case "$kv" in
					cpu_m=*) istiod_cpu_m="${kv#cpu_m=}" ;;
					replicas=*) istiod_rep="${kv#replicas=}" ;;
				esac
			done
			local istiod_baseline_m=0
			if [[ "$istiod_cpu_m" =~ ^[0-9]+$ && "$istiod_rep" =~ ^[0-9]+$ ]]; then
				istiod_baseline_m=$(( istiod_cpu_m * istiod_rep ))
			fi
			free_cpu_m=$(( alloc_cpu_m - istiod_baseline_m ))
			(( free_cpu_m < 0 )) && free_cpu_m=0
			echo "  $ctx: node alloc CPU ~$(cores "$alloc_cpu_m") cores; pod requests unreadable, istiod baseline ~$(cores "$istiod_baseline_m") cores (${istiod_cpu_m:-unknown}m × ${istiod_rep:-unknown} rep) -> ~$(cores "$free_cpu_m") cores free (an overstatement)" >&2
		fi
		if [[ -z "$min_free" ]] || (( free_cpu_m < min_free )); then
			min_free="$free_cpu_m"
			min_ctx="$ctx"
		fi
	done
	if [[ -z "$min_free" ]]; then
		echo "  WARN: node allocatable CPU unreadable on every context; cannot estimate services-that-fit." >&2
		echo "" >&2
		return 0
	fi
	free_cpu_m="$min_free"
	local max_services=0
	if (( max_rc > 0 && per_pod_cpu_m > 0 )); then
		max_services=$(( free_cpu_m / (max_rc * per_pod_cpu_m) ))
	fi
	# Growth series in config-only mode run only measurement pods: report pods, not services.
	local fit_label="~${max_services} services would fit at ${max_rc} replicas"
	if ((GROWTH)) && [[ "$WORKLOAD_MODE" == config-only ]] && ((per_pod_cpu_m > 0)); then
		fit_label="~$(( free_cpu_m / per_pod_cpu_m )) pods would fit"
	fi
	if (( needed_cpu_m > free_cpu_m )); then
		echo "  WARN: combo needs ~$(cores "$needed_cpu_m") cores/cluster, ~$(cores "$free_cpu_m") free on ${min_ctx} (${fit_label}). Reduce the workload, add nodes, or expect 001 to refuse (or FailedScheduling/SETUP_FAILED on) the largest combo." >&2
	else
		echo "  OK: largest combo fits (~$(cores "$needed_cpu_m") needed <= ~$(cores "$free_cpu_m") free on ${min_ctx}; ${fit_label})." >&2
	fi
	echo "" >&2
}

# Metrics-API readiness gate for the utilization-% columns (kubectl top). Polls
# each context up to METRICS_READY_TIMEOUT, records METRICS_API_STATUS for the
# preamble and warns; never aborts. METRICS_READY_TIMEOUT=0 disables it.
metrics_preflight() {
	local timeout="${METRICS_READY_TIMEOUT:-120}" interval="${METRICS_READY_INTERVAL:-10}"
	if (( timeout <= 0 )); then
		echo "Metrics-API preflight: disabled (METRICS_READY_TIMEOUT=0)." >&2
		METRICS_API_STATUS="unknown"
		return 0
	fi
	local deadline=$(( SECONDS + timeout ))
	local -a pending=("${CONTEXTS[@]}")
	echo "Metrics-API preflight: probing 'kubectl top nodes' on ${#pending[@]} context(s) (timeout ${timeout}s)..." >&2
	while :; do
		local -a still=()
		local ctx
		for ctx in "${pending[@]}"; do
			[[ "$(cap_metrics_ready "$ctx" "${KUBECTL[@]}")" == ready ]] || still+=("$ctx")
		done
		pending=("${still[@]}")
		(( ${#pending[@]} == 0 )) && break
		(( SECONDS >= deadline )) && break
		echo "  metrics not ready on ${#pending[@]} context(s): ${pending[*]}; retrying in ${interval}s..." >&2
		sleep "$interval"
	done
	if (( ${#pending[@]} == 0 )); then
		METRICS_API_STATUS="available"
		echo "  metrics API available on all contexts." >&2
	else
		local csv; csv=$(IFS=,; echo "${pending[*]}")
		METRICS_API_STATUS="unavailable:${csv}"
		echo "  WARN: metrics API unavailable on ${csv} after ${timeout}s." >&2
		echo "  WARN: utilization-% columns (istiod_*_pct_of_limit, node_*_pct) will be N/A for combos on those contexts;" >&2
		echo "  WARN: the run PROCEEDS (utilization is observability) — verify metrics-server and re-run if you need utilization-%." >&2
	fi
}

# Record a failed combo as a degraded row (context column = status, restarted =
# unknown, numerics N/A): counted in n_total, excluded from n_valid. The sweep
# continues. <status> is PROBE_FAILED or SETUP_FAILED; growth series also record
# GROW_FAILED, SWITCH_FAILED, SKIPPED_MEM_GUARD, SKIPPED_SERIES_STOPPED and
# RETIRE_FAILED (window_kind retire; the sweep stops after it).
# Optional args 8-13 are the growth columns 52-57 (services_per_namespace,
# workload_mode, measurement_pods, outside_namespaces, outside_discovery,
# window_kind); a legacy cell defaults to 0 pods <svc x replicas> 0 none deploy.
emit_failed_row() {
	local status="$1" ms="$2" sc="$3" rc="$4" nc="$5" scp="$6" tc="$7"
	local g_spn="${8:-0}" g_wm="${9:-pods}" g_mp="${10:-$(( $3 * $4 ))}" g_ox="${11:-0}" g_od="${12:-none}" g_wk="${13:-deploy}"
	local tsv="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
	# Configured VS+DR services for the cell (0 for none), like service_count.
	local vsdr_svcs=0
	[[ "$tc" == vsdr ]] && vsdr_svcs="$(vsdr_service_count "$sc" "$VSDR_EVERY")"
	# Defensive: ensure header exists (pre-create runs before the loop, but keep this
	# idempotent guard so a row is never written into a header-less file).
	if ! grep -q '^timestamp' "$tsv" 2>/dev/null; then
		precreate_tsv_preamble
	fi
	# A window write cut short (a full disk, a step killed while it appended) leaves the
	# last line without its newline: end it, so this row is not merged onto a cut row (the
	# merged line would read as that member's measurement, and the cell as done).
	tsv_end_line "$tsv" || die "could not end the last line of ${tsv} (a write cut short left it without a newline), so the cell's ${status} row cannot start a line of its own. Fix the sweep dir (permissions, disk space)."
	# 66 fields: cols 41-43 (cluster proxies, sidecar pods, proxy check) are N/A too;
	# cols 44-45 keep the cell's traffic config, cols 46-51 are N/A; cols 52-57 keep
	# the cell's growth metadata, cols 58-66 are N/A.
	echo -e "$(date -u -Iseconds)\t${status}\t${ms}\t${sc}\t${rc}\t${nc}\t${scp}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${SETTLE_SEC}\tunknown\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${tc}\t${vsdr_svcs}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${g_spn}\t${g_wm}\t${g_mp}\t${g_ox}\t${g_od}\t${g_wk}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A" >> "$tsv"
}

# Growth memory guard contexts: every member whose istiod and gateways ingest the
# series' Services through remote discovery (PL38), not only the measured ones.
GUARD_CONTEXTS=()
if ((GROWTH)); then
	if [[ -n "$MEM_GUARD_CONTEXTS_CSV" ]]; then
		split_contexts "$MEM_GUARD_CONTEXTS_CSV" GUARD_CONTEXTS "--mem-guard-contexts (or CONTROLPLANE_MEM_GUARD_CONTEXTS)"
	else
		_setup_ctxs=()
		split_csv "${SETUP_CONTEXTS:-}" _setup_ctxs
		declare -A _gseen=()
		for _c in "${CONTEXTS[@]}" ${_setup_ctxs[@]+"${_setup_ctxs[@]}"}; do
			[[ -n "${_gseen[$_c]:-}" ]] && continue
			_gseen[$_c]=1
			GUARD_CONTEXTS+=("$_c")
		done
		unset _gseen
	fi
fi
# guard_add_mesh_members: in a live growth sweep, add every mesh member the measured
# contexts' Istio remote secrets name (BACKLOG 9.6: without --config the guard sampled
# only --contexts + SETUP_CONTEXTS and missed the third member). Context names equal
# cluster names in the repo's kubeconfigs. A member with no kube context of its name
# stops the sweep (an unguarded member could OOM mid-series) unless
# --mem-guard-contexts was given, which only warns.
guard_add_mesh_members() {
	((GROWTH && !DRY_RUN && MEM_STOP_PCT > 0)) || return 0
	((${#KUBECTL[@]})) || return 0
	local -A have=() known=()
	local c m members
	local -a missing=() new_members=()
	for c in "${GUARD_CONTEXTS[@]}"; do have[$c]=1; done
	while IFS= read -r c; do [[ -n "$c" ]] && known[$c]=1; done < <("${KUBECTL[@]}" config get-contexts -o name 2>/dev/null)
	for c in "${CONTEXTS[@]:0:${MAX_MESH_SIZE}}"; do
		if ! members="$(growth_mesh_members "$c" "${KUBECTL[@]}")"; then
			echo "warn: memory guard: cannot list the Istio remote secrets on ${c}; the guard samples ${GUARD_CONTEXTS[*]}" >&2
			continue
		fi
		while IFS= read -r m; do
			[[ -n "$m" && -z "${have[$m]:-}" ]] || continue
			have[$m]=1
			if [[ -n "$MEM_GUARD_CONTEXTS_CSV" ]]; then missing+=("$m")
			elif [[ -n "${known[$m]:-}" ]]; then GUARD_CONTEXTS+=("$m"); new_members+=("$m")
			else missing+=("$m")
			fi
		done <<<"$members"
	done
	((${#new_members[@]} == 0)) || echo "Memory guard: added mesh member(s) ${new_members[*]} (named by the remote secrets); samples ${GUARD_CONTEXTS[*]}"
	((${#missing[@]})) || return 0
	if [[ -n "$MEM_GUARD_CONTEXTS_CSV" ]]; then
		echo "WARNING: memory guard: mesh member(s) ${missing[*]} ingest the series' Services but are not in --mem-guard-contexts (${MEM_GUARD_CONTEXTS_CSV}); their istiod and gateways are not guarded unless a context of another name covers them." >&2
		return 0
	fi
	die "memory guard: mesh member(s) ${missing[*]} (named by the Istio remote secrets) have no kube context of that name, so their istiod and gateways could not be guarded. Pass --mem-guard-contexts with a context for every member (or the subset you accept), or set MEM_STOP_PCT 0 to run unguarded."
}

# leftover_preflight: before a live growth sweep, count the controlplane-test namespaces
# on every measured context (BACKLOG 9.10: thousands of undiscovered leftovers stayed in
# istiod's informers and inflated later series). A discovered one stops the sweep (it
# would add its Services to every cell); undiscovered ones above
# CONTROLPLANE_LEFTOVER_NS_WARN warn. LEFTOVER_AT_START (<ctx>=<total>/<discovered>,...)
# goes into the preamble.
LEFTOVER_AT_START="n/a"
leftover_preflight() {
	if ((DRY_RUN)); then
		((GROWTH)) || echo "Leftover check: a live run counts the controlplane-test namespaces on the members (and on the mesh members their Istio remote secrets name), deletes those an earlier run left on the --contexts members through 005-cleanup.sh before the first cell, then waits --settle (${SETTLE_SEC}s) before it; it deletes nothing on the other mesh members, and stops first when they hold some; a dry run reads no cluster." >&2
		return 0
	fi
	((${#KUBECTL[@]})) || return 0
	if ! ((GROWTH)); then
		legacy_leftover_preflight
		return 0
	fi
	local c kv total disc out="" bad=""
	for c in "${CONTEXTS[@]:0:${MAX_MESH_SIZE}}"; do
		kv="$(growth_test_ns_counts "$c" "${KUBECTL[@]}")"
		total="$(_growth_kv total "$kv")"
		disc="$(_growth_kv discovered "$kv")"
		out="${out:+${out},}${c}=${total}/${disc}"
		if [[ "$disc" =~ ^[0-9]+$ ]] && ((disc > 0)); then
			bad="${bad:+${bad}; }${c}: ${disc} discovered"
		elif [[ "$total" =~ ^[0-9]+$ ]] && ((total > LEFTOVER_NS_WARN)); then
			echo "WARNING: ${c} holds ${total} undiscovered controlplane-test namespaces from earlier runs. They stay in istiod's informers, so this sweep's absolute istiod figures (heap, RSS) are inflated; deltas within a series stay valid. Delete them for clean numbers: ${SCRIPT_DIR}/005-cleanup.sh --contexts ${c} --timeout <about 1 s per namespace>." >&2
		elif ! [[ "$total" =~ ^[0-9]+$ ]]; then
			echo "warn: could not count the controlplane-test namespaces on ${c}" >&2
		fi
	done
	LEFTOVER_AT_START="$out"
	[[ -z "$bad" ]] || die "controlplane-test namespaces of an earlier run are still discovered (${bad}); every cell would include their Services. Retire them first: ${SCRIPT_DIR}/005-cleanup.sh --contexts <ctx> --undiscover --no-delete (all series), then start the sweep again."
}

# leftover_counts <dir> <ctx>...: the controlplane-test namespaces on every context, counted at
# once (one background list each, growth_test_ns_counts, into <dir>), then one line per
# context in order: "<ctx>\t<total>" (N/A: not read). Nothing here stops the sweep.
leftover_counts() {
	local dir="$1" i=0 ctx pid
	shift
	local -a lc_pids=()
	mkdir -p "$dir" 2>/dev/null || true
	for ctx in "$@"; do
		(_growth_kv total "$(growth_test_ns_counts "$ctx" "${KUBECTL[@]}")" > "${dir}/${i}" 2>/dev/null) &
		lc_pids+=("$!")
		i=$((i + 1))
	done
	for pid in ${lc_pids[@]+"${lc_pids[@]}"}; do wait "$pid" 2>/dev/null || true; done
	i=0
	for ctx in "$@"; do
		printf '%s\t%s\n' "$ctx" "$(cat "${dir}/${i}" 2>/dev/null || echo N/A)"
		i=$((i + 1))
	done
}

# legacy_leftover_preflight: a legacy cell deploys its controlplane-test namespaces and
# deletes them at its end (005-cleanup.sh deletes every one, growth series' kept ones
# included), so any found before the first cell were left by a run cut short (or a growth
# series), and a cell would measure on top of them: a re-run cell's apply finds its objects
# in place (no push storm in its window, a valid row of almost nothing), another cell counts
# their Services. Every cell's cleanup deletes them anyway, so this deletes them once more,
# before the first cell (005-cleanup.sh: a first run and a --resume alike, so the operator
# runs one command, not two), then counts again: any still there stop the sweep before its
# start, as a precondition (nothing measured yet). A member whose namespaces cannot be
# counted only warns. It reads the measured members (--contexts, up to the largest mesh
# size) and the other mesh members their Istio remote secrets name that have a kube context
# of that name (their Services reach every member's istiod through remote discovery,
# multi-primary); a member without one is named in a warning. Every count runs on all of
# them at once. It deletes only on members the operator named (--contexts): leftovers on
# another mesh member stop the sweep before any change, with the 005 command for them.
# LEFTOVER_AT_START records the counts (and that 005 deleted them), for a first run's
# preamble; the outcome says so too (INFO). When it deleted anything, the first cell waits
# SETTLE_SEC first, as after every cell's cleanup (LEFTOVER_DELETED): its baseline must not
# land inside the deletion's push storm.
LEFTOVER_DELETED=0
legacy_leftover_preflight() {
	local ctx total m members found="" found_kv="" unread="" csv max=0 sized
	local -a lp_members=("${CONTEXTS[@]:0:${MAX_MESH_SIZE}}") lp_nokube=() lp_del=() lp_other=()
	local -A lp_have=() lp_known=() lp_given=()
	local other="" omax=0
	for ctx in "${lp_members[@]}"; do lp_have[$ctx]=1; done
	for ctx in "${CONTEXTS[@]}"; do lp_given[$ctx]=1; done
	while IFS= read -r ctx; do [[ -z "$ctx" ]] || lp_known[$ctx]=1; done < <("${KUBECTL[@]}" config get-contexts -o name 2>/dev/null || true)
	# The mesh members the measured ones' remote secrets name, read on all of them at once.
	local i=0 pid
	local -a lp_pids=()
	mkdir -p "${SWEEP_TMP}/mesh-members" 2>/dev/null || true
	for ctx in "${CONTEXTS[@]:0:${MAX_MESH_SIZE}}"; do
		(growth_mesh_members "$ctx" "${KUBECTL[@]}" > "${SWEEP_TMP}/mesh-members/${i}" 2>/dev/null) &
		lp_pids+=("$!")
		i=$((i + 1))
	done
	for pid in ${lp_pids[@]+"${lp_pids[@]}"}; do wait "$pid" 2>/dev/null || true; done
	for ((i = 0; i < MAX_MESH_SIZE; i++)); do
		members="$(cat "${SWEEP_TMP}/mesh-members/${i}" 2>/dev/null || true)"
		while IFS= read -r m; do
			[[ -n "$m" && -z "${lp_have[$m]:-}" ]] || continue
			lp_have[$m]=1
			if [[ -n "${lp_known[$m]:-}" ]]; then lp_members+=("$m"); else lp_nokube+=("$m"); fi
		done <<<"$members"
	done
	((${#lp_members[@]} == MAX_MESH_SIZE)) || echo "Leftover check: also counts on mesh member(s) ${lp_members[*]:${MAX_MESH_SIZE}} (named by the Istio remote secrets, not measured): their Services reach every member's istiod" >&2
	((${#lp_nokube[@]} == 0)) || echo "warn: mesh member(s) ${lp_nokube[*]} (named by the Istio remote secrets) have no kube context of that name, so their controlplane-test namespaces are not counted, though their Services reach every member's istiod; check each with: kubectl --context <its context> get namespaces -l app.kubernetes.io/instance=controlplane-test" >&2
	while IFS=$'\t' read -r ctx total; do
		if ! [[ "$total" =~ ^[0-9]+$ ]]; then
			unread="${unread:+${unread}, }${ctx}"
		elif ((total > 0)) && [[ -z "${lp_given[$ctx]:-}" ]]; then
			other="${other:+${other}, }${ctx}: ${total}"
			lp_other+=("$ctx")
			if ((total > omax)); then omax="$total"; fi
		elif ((total > 0)); then
			found="${found:+${found}, }${ctx}: ${total}"
			found_kv="${found_kv:+${found_kv},}${ctx}=${total}"
			lp_del+=("$ctx")
			if ((total > max)); then max="$total"; fi
		fi
	done < <(leftover_counts "${SWEEP_TMP}/leftover-1" "${lp_members[@]}")
	# Not on a cluster the operator did not name: those stop the sweep, before any change.
	if [[ -n "$other" ]]; then
		sized="$(awk -v n="$omax" -v r="$NS_DELETE_SEC_PER_NS" -v d="${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}" 'BEGIN { t = int(n * r + 0.999); if (t < d + 0) t = d + 0; print t }')"
		die "controlplane-test namespaces an earlier run left are on mesh members outside --contexts (${other}; named by the Istio remote secrets of the measured members): their Services reach every member's istiod, so a cell would measure on top of them. The sweep deletes leftovers only on the --contexts members, so nothing was deleted or measured. Delete these with: ${SCRIPT_DIR}/005-cleanup.sh --contexts $(IFS=,; echo "${lp_other[*]}") --timeout ${sized} (about ${NS_DELETE_SEC_PER_NS} s per namespace), then run this command again${found:+ (it then deletes those on the --contexts members: ${found})}."
	fi
	[[ -z "$unread" ]] || echo "warn: could not count the controlplane-test namespaces on ${unread}, so a cell there may run on top of an earlier run's leftovers; check with: kubectl --context <ctx> get namespaces -l app.kubernetes.io/instance=controlplane-test" >&2
	if [[ -z "$found" ]]; then
		LEFTOVER_AT_START="none"
		[[ -z "$unread" ]] || LEFTOVER_AT_START="none counted (unread: ${unread// /})"
		return 0
	fi
	csv="$(IFS=,; echo "${lp_del[*]}")"
	# About 1 s per namespace (CONTROLPLANE_NS_DELETE_SEC_PER_NS), and never less than
	# 005's own default: the members are cleaned at once, so the largest count sizes it.
	sized="$(awk -v n="$max" -v r="$NS_DELETE_SEC_PER_NS" -v d="${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}" 'BEGIN { t = int(n * r + 0.999); if (t < d + 0) t = d + 0; print t }')"
	echo "note: controlplane-test namespaces are left on the members (${found}) by a run cut short or a growth series. A cell would measure on top of them, and every cell deletes them at its end anyway, so 005-cleanup.sh deletes them now, before the first cell. Its --timeout is ${sized} s (about ${NS_DELETE_SEC_PER_NS} s per namespace, ${max} on the fullest member), and the first cell then waits ${SETTLE_SEC}s for the deletion's pushes to settle." >&2
	sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$csv" --timeout "$sized" \
		|| echo "warn: 005-cleanup.sh reported a failure; counting the namespaces again" >&2
	LEFTOVER_DELETED=1
	LEFTOVER_AT_START="${found_kv} (deleted by 005-cleanup.sh before the first cell)"
	RESUME_NOTES+=(--info "the leftover check found controlplane-test namespaces an earlier run left (${found}) and 005-cleanup.sh deleted them before the first cell, which waited SETTLE_SEC=${SETTLE_SEC}s after")
	found=""
	while IFS=$'\t' read -r ctx total; do
		if [[ "$total" =~ ^[0-9]+$ ]] && ((total > 0)); then
			found="${found:+${found}, }${ctx}: ${total}"
		fi
	done < <(leftover_counts "${SWEEP_TMP}/leftover-2" "${lp_members[@]}")
	[[ -z "$found" ]] || die "controlplane-test namespaces are still on the members after 005-cleanup.sh (${found}: still Terminating, or the delete failed), and a cell would measure on top of them; nothing was measured. Run ${SCRIPT_DIR}/005-cleanup.sh --contexts ${csv} until it leaves none, then run this command again. Give it --timeout ${sized} (about ${NS_DELETE_SEC_PER_NS} s per namespace, ${max} on the fullest member; its default is ${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300} s)."
}

# Series ids: unique per run (namespaces of an earlier run may still exist,
# undiscovered or Terminating), DNS-safe: s<MMDDhhmmss>-<n>.
SERIES_PREFIX="s${RUN_ID:4:4}${RUN_ID:9:6}"
LIFECYCLE_FILE="${OUTPUT_DIR}/ns-lifecycle-${RUN_ID}.tsv"
GUARD_FILE="${OUTPUT_DIR}/mem-guard-${RUN_ID}.tsv"

{
	echo "=========================================="
	echo "  Control-Plane Resource Sweep"
	echo "=========================================="
	echo "Contexts:          ${CONTEXTS[*]}"
	echo "Mesh sizes:        ${MESH_SIZES[*]}"
	if ((GROWTH)); then
		echo "Growth series:     K=${SPNS[*]} services per namespace, ${GROWTH_MODE}, workload ${WORKLOAD_MODE}"
		echo "Namespace counts:  ${NAMESPACE_COUNTS[*]} (ascending ladder)"
		[[ "$WORKLOAD_MODE" == config-only ]] && echo "Measurement pods:  ${M_LIST[*]} (first = base$( ((${#M_LIST[@]} > 1)) && echo '; the rest = M-sweep at the largest N'))"
		echo "Replicas:          ${REPLICA_COUNTS[*]}$([[ "$WORKLOAD_MODE" == config-only ]] && echo ' (pods mode only; measurement pods run 1)')"
		echo "Outside:           ${OUTSIDE_NAMESPACES} namespace(s), phases: ${OUTSIDE_PHASES[*]:-none}"
		echo "Probe settle:      ${PROBE_SETTLE_SEC}s"
		echo "Memory guard:      stop at ${MEM_STOP_PCT}% of the istiod / gateway memory limit$( ((MEM_STOP_PCT == 0)) && echo ' (disabled)'); samples ${GUARD_CONTEXTS[*]}"
		echo "Series retire:     ${SERIES_RETIRE}"
	else
		echo "Service counts:    ${SERVICE_COUNTS[*]}"
		echo "Replica counts:    ${REPLICA_COUNTS[*]}"
		echo "Namespace counts:  ${NAMESPACE_COUNTS[*]}"
	fi
	echo "Sidecar scopings:  ${SCOPINGS[*]}"
	echo "Traffic configs:   ${TRAFFIC_CONFIGS[*]}  (vsdr: every ${VSDR_EVERY}, ${VSDR_SUBSETS} subsets; apply ${VSDR_APPLY}$([[ "$VSDR_APPLY" == split ]] && echo ': workloads before the baseline, the window measures the VS/DR apply only'))"
	if [[ -n "$RESUME_DIR" ]] && ! ((GROWTH)); then
		echo "Resume axis flags: $(planned_axis_flags)"
	fi
	echo "Config-dump samples: ${CONFIG_DUMP_SAMPLES}"
	echo "Settle time:       ${SETTLE_SEC}s"
	echo "Run ID:            ${RUN_ID}"
	echo "Output:            ${OUTPUT_DIR}"
	if [[ "${RUN_CONFIG:-none}" != none ]]; then
		echo "Run config:        ${RUN_CONFIG} (sha256 ${RUN_CONFIG_SHA256:0:12})"
	fi
	echo ""
	if ((GROWTH)); then
		echo "Planned matrix:    ${MATRIX_SIZE} cells = ${MATRIX_FACTORS}"
	else
		echo "Planned matrix:    ${MATRIX_SIZE} = ${MATRIX_FACTORS} (mesh × svc × rep × ns × scope × traffic)"
	fi
	echo ""
} >&2

if ((MATRIX_SIZE > MAX_MATRIX)) && ! ((FORCE_LARGE_MATRIX)); then
	if ((GROWTH)); then
		die "growth plan has $MATRIX_SIZE cells = ${MATRIX_FACTORS}, above the safety limit $MAX_MATRIX; re-run with --force-large-matrix to proceed"
	fi
	die "matrix size $MATRIX_SIZE = ${MATRIX_FACTORS} (mesh × svc × rep × ns × scope × traffic) exceeds safety limit $MAX_MATRIX; re-run with --force-large-matrix to proceed"
fi
# A --resume runs only the cells an earlier run of the sweep planned (planned-cells.txt),
# unless --extend-plan (or CONTROLPLANE_EXTEND_PLAN=1): a cell no run planned is refused
# here, before any cluster change, so a resume with other axis values never grows the sweep
# by accident. A sweep whose first run's plan is not known (PLANNED_SET=partial, an older
# harness started it) cannot tell, so it only notes them.
((EXTEND_PLAN == 0)) || [[ -n "$RESUME_DIR" ]] || echo "note: --extend-plan applies to a --resume only; this run plans its own cells" >&2
if [[ -n "$RESUME_DIR" && -f "${OUTPUT_DIR}/planned-cells.txt" ]] && ! ((GROWTH)); then
	_xp_new="$(matrix_cell_keys | awk -F'\t' 'NR == FNR { if (!/^#/) seen[$0] = 1; next } !($0 in seen) && !(dup[$0]++)' "${OUTPUT_DIR}/planned-cells.txt" -)" \
		|| die "--resume: could not read ${OUTPUT_DIR}/planned-cells.txt, which names the cells this sweep planned; nothing was run."
	if [[ -n "$_xp_new" ]]; then
		_xp_n="$(grep -c . <<<"$_xp_new")"
		_xp_list="$(awk -F'\t' 'NR <= 5 { printf "%smesh=%s svcs=%s reps=%s ns=%s scope=%s traffic=%s%s", (NR > 1 ? "; " : ""), $1, $2, $3, $4, $5, $6, ($7 == "deploy" ? "" : " window=" $7) } END { if (NR > 5) printf "; and %d more", NR - 5 }' <<<"$_xp_new")"
		if grep -q '^# PLANNED_SET=partial' "${OUTPUT_DIR}/planned-cells.txt"; then
			echo "note: --resume: ${_xp_n} cell(s) of this run's axis flags are in no plan planned-cells.txt records (${_xp_list}); the first run's plan is not known (PLANNED_SET=partial), so they run, and planned-cells.txt adds them" >&2
		elif ((EXTEND_PLAN)); then
			echo "note: --resume --extend-plan: this run adds ${_xp_n} cell(s) no earlier run of this sweep planned (${_xp_list}); planned-cells.txt records them as a new PLAN" >&2
		else
			# Each plan with the command that resumes with its axis flags (local paths: the
			# console only).
			_xp_cmds=""
			while IFS= read -r _xp_l; do
				[[ "$_xp_l" == *": --"* ]] || continue
				_xp_cmds+=$'\n'"  PLAN ${_xp_l#"# PLAN="}"$'\n'"    $(resume_cmd_console "--${_xp_l#*: --}")"
			done < <(grep '^# PLAN=' "${OUTPUT_DIR}/planned-cells.txt" 2>/dev/null)
			die "--resume: this run's axis flags plan ${_xp_n} cell(s) no earlier run of this sweep planned (${_xp_list}). A --resume finishes the sweep it resumes; nothing was run. Resume with the planned axis flags (an axis flag not given takes the first run's), add --extend-plan to add these cells to this sweep (planned-cells.txt records them as a new PLAN), or start a new sweep for them. The plans so far, each with the command that resumes with its axis flags:${_xp_cmds}"
		fi
	fi
fi

# The dry-run plan needs no CLI, so tolerate a missing one here (resolve_kubectl dies).
if command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
elif command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
else
	KUBECTL=()
fi
# 002's config-dump samples and the growth memory guard's Envoy-stats reads run under
# timeout/gtimeout; a live sweep without either stops here, before any cluster change,
# instead of recording every sample N/A. The plan (--dry-run) does not need it.
((DRY_RUN)) || require_timeout
# SWEEP_TMP: this run's scratch files (the cells' attempts and count, the leftover counts,
# the memory guard's scrapes, the envelope's stderr), in one dir that every exit removes:
# this trap (which also releases a resume's lock) until the sweep's own EXIT trap (below)
# replaces it, which removes it too.
SWEEP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/controlplane-sweep.XXXXXX")" \
	|| die "could not create a scratch dir under ${TMPDIR:-/tmp}; nothing was run."
trap 'rm -rf "$SWEEP_TMP" 2>/dev/null || true; _sweep_unlock 2>/dev/null || true' EXIT
# --resume appends to a TSV whose preamble names the version the sweep started on: rows
# measured on another one would be credited to it. Like the RUN_CONFIG rule, this stops
# under either ISTIO_VERSION_CHECK policy (warn only lets a new run record what it finds).
_resume_iv=""
RESUME_NOTES=()
# The notes about this --resume's own harness or Kubernetes change (kept out of its outcome
# when it adds no rows: it measured nothing on them).
RESUME_OWN_NOTES=()
if [[ -n "$RESUME_DIR" ]] && ! ((DRY_RUN)); then
	_resume_iv="$(grep -m1 '^# ISTIO_VERSION=' "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" 2>/dev/null || true)"
	_resume_iv="${_resume_iv#*=}"
	# Unknown is never a match, not even unknown == unknown: the rows already recorded
	# ran on a version nobody read, so no later read can vouch for the new ones. That is
	# known from the TSV alone, so it stops before the live read (and its readiness wait).
	case "/${_resume_iv#mixed:}/" in
	*/unknown/*) die "--resume: this sweep recorded ISTIO_VERSION=${_resume_iv}: a member's version could not be read or confirmed when it started (unreadable, its Istio CR not settled, or an istiod rollout in progress), so the version its rows ran on is not known and it cannot be resumed. Start a new sweep once every member's Istio CR is settled and Healthy." ;;
	esac
	# Nor a sweep whose outcome recorded a problem with the mesh (the Istio version, the
	# active revision or the generation of the Istio CR or its IstioRevision changing under
	# it, or the end-of-sweep check failing): its rows are not all from one configuration,
	# or that is not known, so no later read can vouch for them (.prev too: a resume that
	# died). Two PROBLEMs do not stop it: a cell count that failed (every run counts again
	# from the TSV), and the harness changing during the sweep (_harness_sha_sweep_end's
	# "the harness changed during the sweep", or an earlier resume's carried copy of it):
	# the TSV marks the rows of the changed harness (HARNESS_CHANGED_AT, every report reads
	# it), and the resume carries the PROBLEM into its own outcome (below).
	for _resume_rec in sweep-outcome.txt sweep-outcome.prev.txt; do
		[[ -f "${OUTPUT_DIR}/${_resume_rec}" ]] || continue
		_resume_problem="$(awk -v c="PROBLEM=could not count the sweep's " -v h="the harness changed during the sweep" -v e="an earlier run of this sweep (" '
			/^PROBLEM=/ {
				p = substr($0, 9)
				if (index($0, c) == 1 || index(p, h) == 1 || (index(p, e) == 1 && index(p, ") recorded: " h))) next
				print p; exit
			}' "${OUTPUT_DIR}/${_resume_rec}")"
		[[ -z "$_resume_problem" ]] || die "--resume: this sweep's ${_resume_rec} records a problem (${_resume_problem}), so no later run can vouch for its rows, and a resume would write an outcome without it. Start a new sweep."
	done
	# Nor on other members than it started on: a renamed or other context would be
	# compared with nothing below, and its rows would join another mesh's. Nor in another
	# order: mesh size N measures the first N contexts, and the first carries the capacity
	# reads. The preamble lists them, in the first run's order, in ISTIO_ACTIVE_REVISIONS,
	# else ISTIO_VERSION_BY_CONTEXT; the refusal prints that order. A member given twice now
	# never gets here (split_contexts refused it above). A preamble that lists one twice
	# (an older harness took --contexts ci-a,ci-a) is refused on its own: its mesh sizes
	# counted that member twice, no --contexts can repeat them, so only a new sweep can.
	# A first run interrupted before it wrote its TSV leaves nothing to check (and the
	# TSV this run writes records both keys): no note then.
	_resume_hastsv=0
	[[ ! -f "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" ]] || _resume_hastsv=1
	_resume_set="$(awk -v a="# ISTIO_ACTIVE_REVISIONS=" -v b="# ISTIO_VERSION_BY_CONTEXT=" '
		/^timestamp\t/ { exit }
		index($0, a) == 1 { r = substr($0, length(a) + 1) }
		index($0, b) == 1 { v = substr($0, length(b) + 1) }
		END { if (r ~ /=/) print "ISTIO_ACTIVE_REVISIONS\t" r; else if (v ~ /=/) print "ISTIO_VERSION_BY_CONTEXT\t" v }' \
		"${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" 2>/dev/null || true)"
	if [[ -n "$_resume_set" ]]; then
		_resume_setdiff="$(awk -v s="${_resume_set#*$'\t'}" -v now="$(IFS=,; echo "${CONTEXTS[*]}")" 'BEGIN {
			n = split(s, p, ",")
			for (i = 1; i <= n; i++) if (match(p[i], /=[^=]*$/)) {
				c = substr(p[i], 1, RSTART - 1)
				if (c in was) rdup = rdup (rdup == "" ? "" : ", ") c
				was[c] = 1; wo[++nw] = c; rec = rec (rec == "" ? "" : ",") c
			}
			if (rdup != "") { print "recorded twice: " rdup "\037" rec; exit }
			m = split(now, q, ",")
			for (i = 1; i <= m; i++) {
				is[q[i]] = 1
				if (!(q[i] in was)) add = add (add == "" ? "" : ", ") q[i]
			}
			for (i = 1; i <= nw; i++) if (!(wo[i] in is)) miss = miss (miss == "" ? "" : ", ") wo[i]
			if (miss != "") out = "started on, not given now: " miss
			if (add != "") out = out (out == "" ? "" : "; ") "given now, not started on: " add
			if (out == "") for (i = 1; i <= nw; i++) if (wo[i] != q[i]) { out = "given in another order: " now; break }
			if (out != "") print out "\037" rec
		}')"
		case "$_resume_setdiff" in
		"recorded twice: "*)
			_resume_setdiff="${_resume_setdiff%%$'\037'*}"
			die "--resume: this sweep's TSV preamble lists ${_resume_setdiff#recorded twice: } twice in ${_resume_set%%$'\t'*} (${_resume_set#*$'\t'}): an older harness took that member twice, so its mesh sizes counted it twice and no --contexts can repeat them (each member is now listed once). Start a new sweep with each mesh member listed once."
			;;
		esac
		# The same members in another order are named so.
		_resume_who="these are not the members this sweep started on, in its order"
		[[ "$_resume_setdiff" != "given in another order: "* ]] || _resume_who="these are the members this sweep started on, but not in its order"
		[[ -z "$_resume_setdiff" ]] || die "--resume: ${_resume_who} (${_resume_setdiff%%$'\037'*}; its TSV preamble lists them in ${_resume_set%%$'\t'*}): mesh size N measures the first N contexts, so the new rows would not measure what the earlier ones did. Resume with --contexts ${_resume_setdiff#*$'\037'} (that order), or start a new sweep (also to add members for a larger mesh size)."
	elif ((_resume_hastsv)); then
		echo "warning: --resume: this sweep's TSV records neither ISTIO_ACTIVE_REVISIONS nor ISTIO_VERSION_BY_CONTEXT, so whether it runs on the members it started on is not checked." >&2
		RESUME_NOTES+=(--note "this sweep's TSV records neither ISTIO_ACTIVE_REVISIONS nor ISTIO_VERSION_BY_CONTEXT, so no --resume of it (the latest at ${RESUME_AT_Z}) could check that it ran on the members the sweep started on")
	fi
fi
# The Istio version every member runs, read once before any cluster change and
# exported, so 001, 002 and 005 record it (ISTIO_VERSION_CHECK=fail stops here on a
# mismatch). --dry-run reads nothing: the pin, ISTIO_VERSION_SOURCE=pin. A --resume
# appends to a TSV whose preamble keeps the first run's ISTIO_NOTREADY_AT_START, so the
# outcome records this resume's own start condition, with its UTC start time.
_iv_resume_args=()
[[ -z "$RESUME_DIR" ]] || _iv_resume_args=(--resumed-at "$RESUME_AT_Z")
istio_version_resolve ${_iv_resume_args[@]+"${_iv_resume_args[@]}"} "$(IFS=,; echo "${CONTEXTS[*]}")" "$DRY_RUN" ${KUBECTL[@]+"${KUBECTL[@]}"}
echo "Istio version:     $(istio_version_label)" >&2
if [[ -n "$RESUME_DIR" && "$ISTIO_VERSION_SOURCE" == live ]]; then
	case "/${ISTIO_VERSION#mixed:}/" in
	*/unknown/*)
		# A check that stopped unexpectedly read nothing (ISTIO_READY_WAITED_SEC is
		# unchecked only then, on a live read): say so, not "fix access".
		[[ -z "$_resume_iv" || "${ISTIO_READY_WAITED_SEC:-}" != unchecked ]] \
			|| die "--resume: this sweep recorded ISTIO_VERSION=${_resume_iv}, but the Istio version check stopped unexpectedly (its error is above), so the version the mesh runs now is not known. Fix what that error shows, then run the same --resume again."
		[[ -z "$_resume_iv" ]] || die "--resume: this sweep recorded ISTIO_VERSION=${_resume_iv}, but the running version cannot be read now on every member (ISTIO_VERSION=${ISTIO_VERSION}; the members are listed above). Fix access to them (kubeconfig, login, network) or wait until their Istio CR is settled, then run the same --resume again."
		;;
	esac
	if [[ -n "$_resume_iv" && "${_resume_iv#v}" != "${ISTIO_VERSION#v}" ]]; then
		die "--resume: this sweep recorded ISTIO_VERSION=${_resume_iv}, but the mesh now runs ${ISTIO_VERSION}, so its new rows would be credited to ${_resume_iv}. Start a new sweep: --resume never mixes Istio versions in one TSV, whatever ISTIO_VERSION_CHECK says."
	fi
	# The same version on another active revision (a run killed before its end check,
	# then InPlace moved to RevisionBased, or the Istio CR recreated with the other
	# updateStrategy) is another control plane. The preamble records each member's
	# (ISTIO_ACTIVE_REVISIONS); a TSV from before it cannot be checked, which the outcome
	# notes. The members are grouped by their old and new revision.
	_resume_revs="$(awk -v k="# ISTIO_ACTIVE_REVISIONS=" '/^timestamp\t/ { exit } index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" 2>/dev/null || true)"
	case "$_resume_revs" in
	*=*)
		_resume_revdiff="$(awk -v a="$_resume_revs" -v b="${_ISTIO_VERSION_REVS:-}" 'BEGIN {
			n = split(a, p, ",")
			for (i = 1; i <= n; i++) if (match(p[i], /=[^=]*$/)) s[substr(p[i], 1, RSTART - 1)] = substr(p[i], RSTART + 1)
			n = split(b, p, ",")
			for (i = 1; i <= n; i++) if (match(p[i], /=[^=]*$/)) {
				c = substr(p[i], 1, RSTART - 1); v = substr(p[i], RSTART + 1)
				if (!((c in s) && s[c] != "" && v != "" && s[c] != v)) continue
				g = s[c] " when the sweep started, " v " now"
				if (g in gm) gm[g] = gm[g] ", " c
				else { go[++ng] = g; gm[g] = c }
			}
			for (i = 1; i <= ng; i++) out = out (out == "" ? "" : "; ") gm[go[i]] ": " go[i]
			print out
		}')"
		[[ -z "$_resume_revdiff" ]] || die "--resume: the members' active Istio revision is not the one this sweep started on (${_resume_revdiff}; activeRevisionName of their Istio CR), at the same Istio version: another control plane, so the new rows would not be comparable with the earlier ones. Start a new sweep."
		;;
	*)
		# An older harness wrote no key; unknown or unchecked (no revision was read)
		# is not that. Nor a sweep without a TSV yet (nothing to check).
		if ((_resume_hastsv)); then
			_resume_revwhy="ISTIO_ACTIVE_REVISIONS; an older harness started it"
			[[ -z "$_resume_revs" ]] || _resume_revwhy="ISTIO_ACTIVE_REVISIONS=${_resume_revs}"
			echo "warning: --resume: this sweep's TSV does not record its members' active Istio revisions (${_resume_revwhy}), so whether one changed since it started, at the same version, is not checked." >&2
			RESUME_NOTES+=(--note "this sweep's TSV does not record its members' active Istio revisions (${_resume_revwhy}), so no --resume of it (the latest at ${RESUME_AT_Z}) could check that each member still runs the revision the sweep started on")
		fi
		;;
	esac
	# Nor once the Istio CR or its active IstioRevision was edited since the sweep
	# started (a version changed and changed back, or a values change): its generation is
	# not the TSV preamble's ISTIO_GENERATIONS. A part not read on either side is not
	# compared; a TSV from before ISTIO_GENERATIONS cannot tell (a note, as for the revisions).
	_resume_gens="$(awk -v k="# ISTIO_GENERATIONS=" '/^timestamp\t/ { exit } index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" 2>/dev/null || true)"
	case "$_resume_gens" in
	*=*/*)
		_resume_gendiff="$(awk -v a="$_resume_gens" -v b="${ISTIO_GENERATIONS:-}" 'BEGIN {
			n = split(a, p, ",")
			for (i = 1; i <= n; i++) if (match(p[i], /=[^=]*$/)) s[substr(p[i], 1, RSTART - 1)] = substr(p[i], RSTART + 1)
			n = split(b, p, ",")
			for (i = 1; i <= n; i++) if (match(p[i], /=[^=]*$/)) {
				c = substr(p[i], 1, RSTART - 1)
				if (!(c in s)) continue
				split(s[c], o, "/"); split(substr(p[i], RSTART + 1), w, "/"); d = ""
				if (o[1] ~ /^[0-9]+$/ && w[1] ~ /^[0-9]+$/ && o[1] != w[1]) d = "Istio CR generation " o[1] " when the sweep started, " w[1] " now"
				if (o[2] ~ /^[0-9]+$/ && w[2] ~ /^[0-9]+$/ && o[2] != w[2]) d = d (d == "" ? "" : ", ") "IstioRevision generation " o[2] " when the sweep started, " w[2] " now"
				if (d != "") out = out (out == "" ? "" : "; ") c ": " d
			}
			print out
		}')"
		_resume_gencause=0
		[[ "$_resume_gendiff" != *"Istio CR generation"* ]] || _resume_gencause=1
		[[ -z "$_resume_gendiff" ]] || die "--resume: the Istio CR or its active IstioRevision was edited since this sweep started (${_resume_gendiff}; ISTIO_GENERATIONS), at the same version and active revision: $(istio_generation_causes "$_resume_gencause"), so the new rows may not measure the control plane the earlier ones did. Start a new sweep."
		;;
	*)
		if ((_resume_hastsv)); then
			_resume_genwhy="ISTIO_GENERATIONS; an older harness started it"
			[[ -z "$_resume_gens" ]] || _resume_genwhy="ISTIO_GENERATIONS=${_resume_gens}"
			echo "warning: --resume: this sweep's TSV does not record its Istio CR and IstioRevision generations (${_resume_genwhy}), so whether either was edited since it started is not checked." >&2
			RESUME_NOTES+=(--note "this sweep's TSV does not record its Istio CR and IstioRevision generations (${_resume_genwhy}), so no --resume of it (the latest at ${RESUME_AT_Z}) could check that neither was edited since the sweep started")
		fi
		;;
	esac
fi
# Which cells the resumed sweep already measured, read once before the first cell, from
# each cell's latest attempt (controlplane_latest_attempts) by the rule 004 also uses
# (CP_CELL_AWK cp_cell_state): done when it has a valid row, its last row is not a status
# row, and its rows name as many members as its mesh size. A cell with a valid row that is
# not done failed partway (a status row after it, INTERRUPTED included) or was cut short
# while its member rows were written (INCOMPLETE): RESUME_RERUN, it runs again, its line
# says so, and the reports then use only that new attempt (never two attempts pooled).
# INTERRUPTED: the row the EXIT trap writes for the cell in progress when the sweep is
# interrupted or stops (CELL_IN_PROGRESS).
CELL_STATUS_RE='^(SETUP_FAILED|PROBE_FAILED|GROW_FAILED|SWITCH_FAILED|SKIPPED_MEM_GUARD|SKIPPED_SERIES_STOPPED|RETIRE_FAILED|INTERRUPTED)$'
if [[ -n "$RESUME_DIR" && -f "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" ]] && ! ((GROWTH)); then
	_cells_dir="${SWEEP_TMP}/resume-cells"
	mkdir -p "$_cells_dir" || die "--resume: could not create ${_cells_dir}; nothing was run."
	controlplane_latest_attempts "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" "${OUTPUT_DIR}/resumes.txt" "${_cells_dir}/tsv" > /dev/null 2> "${_cells_dir}/err" \
		|| die "--resume: could not tell the cells' attempts apart in controlplane-${RUN_ID}.tsv ($(head -n 1 "${_cells_dir}/err")); no cell was run. Run the same --resume again."
	while IFS=$'\t' read -r _rd_key _rd_state; do
		[[ -n "$_rd_key" ]] || continue
		if [[ "$_rd_state" == "done" ]]; then RESUME_DONE["$_rd_key"]=1; else RESUME_RERUN["$_rd_key"]="$_rd_state"; fi
	done < <(awk -F'\t' -v wk="$LEGACY_WINDOW_KIND" -v st="$CELL_STATUS_RE" "${CP_CELL_AWK}"'
		/^timestamp\t/ { cp_header(); next }
		/^#/ { cp_comment(); next }
		!cp_isrow() { next }
		{ k = cp_key(); split(k, kp, SUBSEP) }
		kp[7] != wk { next }
		{ if (!(k in seen)) { seen[k] = 1; order[++n] = k }; cp_cell_row(k, st) }
		END {
			cp_end()
			for (i = 1; i <= n; i++) {
				k = order[i]
				if (!(k in cp_valid)) continue
				split(k, kp, SUBSEP)
				s = cp_cell_state(k)
				if (s == "INCOMPLETE") s = "INCOMPLETE: " (cp_why[k] != "" ? cp_why[k] : "rows of " (cp_nm[k] + 0) " of its " kp[1] " members")
				print kp[1] "|" kp[2] "|" kp[3] "|" kp[4] "|" kp[5] "|" kp[6] "\t" (s == "" ? "done" : s)
			}
		}' \
		"${_cells_dir}/tsv")
	rm -rf "$_cells_dir"
	_cells_dir=""
fi
# A --resume whose axis flags leave planned cells out says so now, before the leftover
# cleanup, the capacity check and its first cell: those not done yet (never ran, failed,
# INCOMPLETE) will not run and count as failed at its end (NOT_RUN, or their last state),
# and it names the axis flags that planned them, each with the full command that resumes
# with them, so the operator can stop here instead of finding out at the end.
if [[ -n "$RESUME_DIR" && -f "$PLANNED_FILE" ]] && ! ((GROWTH || DRY_RUN)); then
	declare -A _np_matrix=()
	while IFS= read -r _np_k; do _np_matrix["$_np_k"]=1; done < <(matrix_cell_keys)
	_np_list=() _np_plans=() _np_plan=""
	while IFS= read -r _np_line; do
		case "$_np_line" in
		"# PLAN="*)
			_np_plan="${_np_line#"# PLAN="}"
			_np_plan="${_np_plan%% *}"
			continue
			;;
		"#"* | mesh_size$'\t'* | "") continue ;;
		esac
		[[ -z "${_np_matrix["$_np_line"]+x}" ]] || continue
		IFS=$'\t' read -r _np_ms _np_sc _np_rc _np_nc _np_scp _np_tc _np_wk <<<"$_np_line"
		[[ "$_np_wk" == "$LEGACY_WINDOW_KIND" ]] || continue
		[[ -z "${RESUME_DONE["${_np_ms}|${_np_sc}|${_np_rc}|${_np_nc}|${_np_scp}|${_np_tc}"]+x}" ]] || continue
		_np_list+=("mesh=${_np_ms} svcs=${_np_sc} reps=${_np_rc} ns=${_np_nc} scope=${_np_scp} traffic=${_np_tc}")
		[[ " ${_np_plans[*]-} " == *" ${_np_plan} "* ]] || _np_plans+=("$_np_plan")
	done < "$PLANNED_FILE"
	if ((${#_np_list[@]})); then
		_np_s="$(printf '%s; ' "${_np_list[@]:0:5}")"
		_np_s="${_np_s%; }"
		((${#_np_list[@]} <= 5)) || _np_s+="; and $((${#_np_list[@]} - 5)) more"
		echo "note: --resume: this run's axis flags leave out ${#_np_list[@]} planned cell(s) not done yet (never ran, failed or INCOMPLETE), which will not run and count as failed at its end (NOT_RUN, or their last state): ${_np_s}. No cell has run yet: to run them in this resume, stop it now (Ctrl-C) and --resume with the axis flags that planned them (cells already measured are skipped):" >&2
		for _np_p in ${_np_plans[@]+"${_np_plans[@]}"}; do
			_np_l="$(grep -m 1 "^# PLAN=${_np_p} " "$PLANNED_FILE" 2>/dev/null)" || _np_l=""
			[[ "$_np_l" == *": --"* ]] || continue
			echo "  ${_np_l#"# PLAN=${_np_p} "}" >&2
			echo "    $(resume_cmd_console "--${_np_l#*: --}")" >&2
		done
	fi
	unset _np_matrix
fi
# The cleanup to run when SIGKILL cut a step's own cleanup short (sweep_step's warning;
# console only), from the repo root as the other sweeps name theirs.
# shellcheck disable=SC2034  # read by sweep_step (tests/lib/common.sh)
SWEEP_CLEANUP_CMD="./tests/controlplane/005-cleanup.sh --contexts $(IFS=,; echo "${CONTEXTS[*]}")"
((GROWTH)) || SWEEP_CLEANUP_CMD+="; a --resume of this sweep also deletes the namespaces before its first cell"
capacity_plan_warn
guard_add_mesh_members
leftover_preflight
# What a stop from here to the first cell has changed: the leftover check may have deleted an
# earlier run's namespaces (LEFTOVER_DELETED), and nothing else has run.
NO_CELL_RAN="no cell ran, and nothing was changed on the cluster"
((LEFTOVER_DELETED == 0)) || NO_CELL_RAN="no cell ran (the leftover check had already deleted an earlier run's controlplane-test namespaces with 005-cleanup.sh; nothing else was changed on the cluster)"

# The first run's start condition stays in the TSV preamble (ISTIO_NOTREADY_AT_START,
# with ISTIO_READY_WAITED_SEC), which every resume keeps: each resume's outcome rebuilds its
# note from there, dated with the preamble's first line (an outcome carries none from an
# earlier one, and a first run that died wrote none), so it is there once.
if [[ -n "$RESUME_DIR" ]] && ! ((DRY_RUN)); then
	_resume_nr0="" _resume_w0="" _resume_d0=""
	IFS=$'\037' read -r _resume_nr0 _resume_w0 _resume_d0 < <(awk -v OFS='\037' -v a="# ISTIO_NOTREADY_AT_START=" -v b="# ISTIO_READY_WAITED_SEC=" '
		NR == 1 && /^# Control-plane resource metrics/ && $NF ~ /^[0-9][0-9][0-9][0-9]-/ { d = $NF }
		/^timestamp\t/ { exit }
		index($0, a) == 1 { nr = substr($0, length(a) + 1) }
		index($0, b) == 1 { w = substr($0, length(b) + 1) }
		END { print nr, w, d }' "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" 2>/dev/null) || true
	_istio_notready_notes RESUME_NOTES first "$_resume_nr0" "$_resume_w0" "$_resume_d0"
fi
# An earlier run's end notes (its Istio version unconfirmed at the end, istiod or
# IstioCNI not ready at the end, its steps' own harness reads not checked) are about rows
# that stay in the TSV: this run's outcome carries them, from the newest record
# (sweep-outcome.txt, or sweep-outcome.prev.txt when the resume after it died), as "an
# earlier run of this sweep (outcome of <DATE>) noted: ...". A note that already starts
# "an earlier run of this sweep (" (one of these, or a harness PROBLEM made a NOTE, below)
# is carried as it is, so each is kept once.
if [[ -n "$RESUME_DIR" ]] && ! ((DRY_RUN)); then
	_resume_rec="${OUTPUT_DIR}/sweep-outcome.txt"
	# A run that died left its not-finished record, with no notes (or the stop
	# record of a run cut short, CUT_SHORT=1): the newest finished one is then
	# sweep-outcome.prev.txt (when an earlier run wrote one).
	if [[ ! -f "$_resume_rec" ]] || sweep_outcome_cut_short "$_resume_rec"; then
		_resume_rec="${OUTPUT_DIR}/sweep-outcome.prev.txt"
	fi
	_resume_carry=()
	[[ ! -f "$_resume_rec" ]] || mapfile -t _resume_carry < <(awk -v p="an earlier run of this sweep (outcome of " \
		-v l="the steps' own harness reads could not be checked: " '
		/^# DATE=/ { d = substr($0, 8) }
		/^NOTE=/ {
			n = substr($0, 6)
			if (index(n, "an earlier run of this sweep (") == 1) { print "N" n; next }
			if (index(n, "the Istio version at the end of the sweep is unconfirmed: ") == 1 \
				|| index(n, "istiod or IstioCNI was not ready at the end of the sweep") == 1 \
				|| index(n, "not ready at the end: ") == 1 || index(n, l) == 1)
				print "N" p (d == "" ? "an unknown date" : d) ") noted: " n
		}
		# A harness change during the sweep stays a PROBLEM in later outcomes (exit 4) while
		# rows of the changed harness may still be among the figures (the end of the sweep
		# makes it a NOTE once they are not).
		/^PROBLEM=/ {
			n = substr($0, 9)
			if (index(n, "an earlier run of this sweep (") == 1 && index(n, ") recorded: the harness changed during the sweep")) print "P" n
			else if (index(n, "the harness changed during the sweep") == 1) print "P" p (d == "" ? "an unknown date" : d) ") recorded: " n
		}' "$_resume_rec")
	# A run that was interrupted or stopped wrote its harness change and its steps' reads
	# not checked in its not-finished or stop record (a NOTE or PROBLEM line), which this
	# run replaces: carried too, the first as a PROBLEM, the second as a NOTE. So is what
	# that run had carried, as it is: a harness change stays a PROBLEM unless it ends as
	# the NOTE an end of the sweep made of it (below).
	if [[ "$_resume_rec" != "${OUTPUT_DIR}/sweep-outcome.txt" && -f "${OUTPUT_DIR}/sweep-outcome.txt" ]]; then
		mapfile -t -O "${#_resume_carry[@]}" _resume_carry < <(awk -v p="an earlier run of this sweep (" \
			-v h="the harness changed during the sweep" -v l="the steps' own harness reads could not be checked: " '
			/^STARTED_AT=/ { d = substr($0, 12) }
			/^(NOTE|PROBLEM)=/ {
				x = substr($0, index($0, "=") + 1)
				if (index(x, p) == 1) {
					t[++k] = "N"
					if (index(x, ") recorded: " h) && x !~ / \((its rows were all run again later|that run wrote no rows)\)$/) t[k] = "P"
					n[k] = x
				} else if (index(x, h) == 1) { t[++k] = "P"; v[k] = "recorded"; n[k] = x }
				else if (index(x, l) == 1) { t[++k] = "N"; v[k] = "noted"; n[k] = x }
			}
			END { for (i = 1; i <= k; i++) print t[i] (v[i] == "" ? "" : p "started at " (d == "" ? "an unknown time" : d) ", not finished) " v[i] ": ") n[i] }' "${OUTPUT_DIR}/sweep-outcome.txt")
	fi
	_resume_seen=()
	for _resume_n in ${_resume_carry[@]+"${_resume_carry[@]}"}; do
		# Why an earlier run kept a PROBLEM is its own: this run's end says it again.
		_resume_n="${_resume_n% (kept: *)}"
		for _resume_s in ${_resume_seen[@]+"${_resume_seen[@]}"}; do [[ "$_resume_s" != "$_resume_n" ]] || continue 2; done
		_resume_seen+=("$_resume_n")
		case "$_resume_n" in
		P*) RESUME_NOTES+=(--problem "${_resume_n#P}") ;;
		*) RESUME_NOTES+=(--note "${_resume_n#N}") ;;
		esac
	done
fi
# A resumed sweep writes a new outcome at its end; the interrupted run's record (when it got
# that far) no longer describes the sweep, and its reports must not show it meanwhile. It is
# kept as sweep-outcome.prev.txt (reports show it, after a warning, only while there is
# no sweep-outcome.txt); only once the preflights passed, so a resume that stops in one
# leaves the record where it was. A run that died left its not-finished record, not an
# outcome (nor is the stop record of a run cut short, CUT_SHORT=1): it is not moved
# (sweep-outcome.prev.txt keeps the last finished one), and this run's own not-finished
# record replaces it below.
if [[ -n "$RESUME_DIR" && -f "${OUTPUT_DIR}/sweep-outcome.txt" ]] && ! ((DRY_RUN)) \
	&& ! sweep_outcome_cut_short "${OUTPUT_DIR}/sweep-outcome.txt"; then
	mv -f "${OUTPUT_DIR}/sweep-outcome.txt" "${OUTPUT_DIR}/sweep-outcome.prev.txt"
fi
# The sweep's markdown pages (sweep-, sweep-charts- and scale-envelope-<RUN_ID>.md) show the
# sweep before this resume: until the resume writes them again at its end, each says so
# under its title (where 004 puts its warnings) and in place of its outcome section (a "not
# written yet" line with SWEEP_OUTCOME_PENDING_MARK, which sweep_outcome --md removes), and
# a page with front matter gets stale_since_resume: <this resume's start, Z> (004 never
# writes that key: its pages are written whole), so a page left by a resume that died, was
# interrupted or stopped is not read as a finished sweep on one harness. An earlier
# resume's lines and key give way to this one's.
if [[ -n "$RESUME_DIR" ]] && ! ((DRY_RUN)); then
	_resume_stale="> **Sweep outcome**: not written yet: a --resume of this sweep started at ${RESUME_AT_Z}, and this page is from before it (its figures, provenance and outcome). The resume writes it again at its end; a page that still shows this line is from a resume that did not finish (it died, was interrupted or stopped): its sweep-outcome.txt says how it ended, and the next --resume writes the page again. ${SWEEP_OUTCOME_PENDING_MARK}"
	for _resume_page in sweep sweep-charts scale-envelope; do
		_resume_page="${OUTPUT_DIR}/${_resume_page}-${RUN_ID}.md"
		[[ -f "$_resume_page" ]] || continue
		if ! STALE="$_resume_stale" FM="stale_since_resume: \"${RESUME_AT_Z}\"" awk -v m="$SWEEP_OUTCOME_PENDING_MARK" '
				NR == 1 && $0 == "---" { fm = 1; l[++n] = $0; next }
				fm && index($0, "stale_since_resume:") == 1 { next }
				fm && $0 == "---" { fm = 0; l[++n] = ENVIRON["FM"]; l[++n] = $0; next }
				fm { l[++n] = $0; next }
				index($0, m) { skip = 1; next }
				skip && $0 == "" { skip = 0; next }
				$0 == "## Sweep outcome" || $0 == "## Sweep outcome: stopped" { exit }
				!titled && /^#/ { titled = 1; skip = 0; l[++n] = $0; l[++n] = ""; l[++n] = ENVIRON["STALE"]; next }
				{ skip = 0; l[++n] = $0 }
				END { while (n > 0 && l[n] == "") n--; for (i = 1; i <= n; i++) print l[i]; printf "\n%s\n", ENVIRON["STALE"] }' \
			"$_resume_page" > "${_resume_page}.new" || ! mv -f "${_resume_page}.new" "$_resume_page"; then
			rm -f "${_resume_page}.new"
			echo "warning: could not mark ${_resume_page} as made before this --resume" >&2
		fi
	done
fi
# The TSV preamble names the harness the sweep started on, and each resume appends
# rows from its own. resumes.txt in the sweep dir is append-only: one line per resume that
# passed its preflights (this one, and one that dies later, included), with its start time
# in the format of the rows' timestamp column, its HARNESS_SHA, its own
# ISTIO_NOTREADY_AT_RESUME and its KUBE_VERSIONS (a file an older harness started
# keeps its three columns). TSV_LINES, the TSV's line count when the resume started, where
# the rows of its attempts begin (controlplane_latest_attempts; a file an older harness
# started keeps its columns, and its rows are told apart by RESUMED_AT). Then the proxy
# versions and generations this resume read at its start (ISTIO_PROXY_VERSIONS,
# ISTIO_GENERATIONS: the TSV preamble keeps the first run's), the TSV the line is about
# (TSV: a resumes.txt applies only to its TSV) and its HARNESS_CONTENT_KEY. Columns are only
# ever added at the end; a file keeps the columns its first line names. The resume also
# writes a "# RESUMED_AT=<time> TSV_LINES=<n> HARNESS_SHA=<sha> HARNESS_CONTENT_KEY=<key>
# ISTIO_NOTREADY_AT_RESUME=<...> ISTIO_GENERATIONS=<...> ISTIO_PROXY_VERSIONS=<...>
# KUBE_VERSIONS=<ctx=ver,...>" line into the TSV itself, where its rows begin, so a TSV
# copied without resumes.txt still keeps its attempts apart and names each attempt's
# harness, Istio reads and Kubernetes versions (KUBE_VERSIONS last: the rest of the line;
# 002 compares its harness with this line's). From that file the outcome notes every
# earlier resume that started with a member not ready (this one's is the version recheck's
# note), and the harness segments: a note per resume whose harness files differ from the
# run before it (another HARNESS_CONTENT_KEY; another HARNESS_SHA when a key is not
# recorded), with the time from which the rows are that harness's, and until when when a
# later resume changed it again. unknown cannot be compared: each resume that ran it gets
# a note of its own. This resume also warns when it runs unknown, or a harness other than
# the last known one before it.
if [[ -n "$RESUME_DIR" && -f "${_resume_tsv:-}" ]] && ! ((DRY_RUN)); then
	_resumes_log="${OUTPUT_DIR}/resumes.txt"
	[[ -s "$_resumes_log" ]] || printf 'RESUMED_AT\tHARNESS_SHA\tISTIO_NOTREADY_AT_RESUME\tKUBE_VERSIONS\tTSV_LINES\tISTIO_PROXY_VERSIONS\tISTIO_GENERATIONS\tTSV\tHARNESS_CONTENT_KEY\n' >> "$_resumes_log" \
		|| die "--resume: could not append to ${_resumes_log}, which tells this run's rows from earlier ones; ${NO_CELL_RAN}. Fix the sweep dir (permissions, disk space), then run the same --resume again."
	# A run killed while it appended a window can leave the TSV's last line without its
	# newline: end that line first, so this resume's "# RESUMED_AT=" line starts one of its
	# own and TSV_LINES counts it.
	tsv_end_line "$_resume_tsv" \
		|| die "--resume: could not end the last line of ${_resume_tsv} (a run cut short left it without a newline); ${NO_CELL_RAN}. Fix the sweep dir (permissions, disk space), then run the same --resume again."
	# A TSV without its header line holds no row yet, and precreate_tsv_preamble writes it
	# again: every row of it is this run's (0).
	_resume_lines=0
	! grep -q '^timestamp' "$_resume_tsv" 2>/dev/null || _resume_lines="$(wc -l < "$_resume_tsv" | tr -d ' ')"
	_resume_line="$(printf '%s\t%s\t%s' "$RESUME_AT" "$HARNESS_SHA" "${ISTIO_NOTREADY_AT_START:-unchecked}")"
	# Read once: resumes.txt's column and the TSV's own resume line record the same value.
	_resume_kv="$(probe_kube_versions "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
	# Unreadable: no column is known, and the append below says what failed.
	_resume_hdr="$(head -n 1 "$_resumes_log" 2>/dev/null)" || _resume_hdr=""
	# Each column the file's first line names, in its order (a file an older harness
	# started keeps its columns: only the ones it has are filled).
	for _resume_col in KUBE_VERSIONS TSV_LINES ISTIO_PROXY_VERSIONS ISTIO_GENERATIONS TSV HARNESS_CONTENT_KEY; do
		[[ $'\t'"${_resume_hdr}"$'\t' == *$'\t'"${_resume_col}"$'\t'* ]] || break
		case "$_resume_col" in
		KUBE_VERSIONS) _resume_line+=$'\t'"${_resume_kv}" ;;
		TSV_LINES) _resume_line+=$'\t'"${_resume_lines}" ;;
		ISTIO_PROXY_VERSIONS) _resume_line+=$'\t'"${ISTIO_PROXY_VERSIONS:-unchecked}" ;;
		ISTIO_GENERATIONS) _resume_line+=$'\t'"${ISTIO_GENERATIONS:-unchecked}" ;;
		TSV) _resume_line+=$'\t'"${_resume_tsv##*/}" ;;
		HARNESS_CONTENT_KEY) _resume_line+=$'\t'"${HARNESS_CONTENT_KEY:-unknown}" ;;
		esac
	done
	# The reports tell this run's rows from earlier attempts by these two lines: without
	# them they would pool two attempts of a re-run cell, so a resume that cannot record
	# them stops here, before any cell (NO_CELL_RAN). printf: a boundary line, not a preamble
	# key.
	printf '%s\n' "$_resume_line" >> "$_resumes_log" \
		|| die "--resume: could not append to ${_resumes_log}, which tells this run's rows from earlier ones; ${NO_CELL_RAN}. Fix the sweep dir (permissions, disk space), then run the same --resume again."
	((_resume_lines == 0)) || printf '# RESUMED_AT=%s TSV_LINES=%s HARNESS_SHA=%s HARNESS_CONTENT_KEY=%s ISTIO_NOTREADY_AT_RESUME=%s ISTIO_GENERATIONS=%s ISTIO_PROXY_VERSIONS=%s KUBE_VERSIONS=%s\n' \
		"$RESUME_AT" "$_resume_lines" "$HARNESS_SHA" "${HARNESS_CONTENT_KEY:-unknown}" "${ISTIO_NOTREADY_AT_START:-unchecked}" \
		"${ISTIO_GENERATIONS:-unchecked}" "${ISTIO_PROXY_VERSIONS:-unchecked}" "$_resume_kv" >> "$_resume_tsv" \
		|| die "--resume: could not append the resume's start line to ${_resume_tsv}, which tells this run's rows from earlier ones; ${NO_CELL_RAN}. Fix the sweep dir (permissions, disk space), then run the same --resume again."
	_resume_harness="$(awk -v k="# HARNESS_SHA=" '/^timestamp\t/ { exit } index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$_resume_tsv")"
	_resume_hkey0="$(awk -v k="# HARNESS_CONTENT_KEY=" '/^timestamp\t/ { exit } index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$_resume_tsv")"
	_resume_kv0="$(awk -v k="# KUBE_VERSIONS=" '/^timestamp\t/ { exit } index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$_resume_tsv")"
	# One line each, fields split by \037 (a tab is IFS whitespace: read would merge the
	# empty ones): R at notready until (an earlier resume not ready), U at until (a resume
	# on an unknown harness), C at new old old_at until (a change; old_at: the last run on
	# old, empty: the first run), D at new old key (another HARNESS_SHA on the same harness
	# files: git describe only), K at diffs (a resume that read other Kubernetes
	# server versions than the last known ones, from the preamble then each resume before
	# it, members unreachable or unknown left out; grouped by old and new), W old
	# old_at gap (this resume differs from the last known harness; gap 1: an unknown one ran
	# between them), WU (this resume's is unknown). until empty: up to the last row. A K
	# note's until is the first later resume that could not read one of its members (their
	# rows' versions are not known from there); a member read again after such a resume, on
	# another version than the first run's, is a K of its own.
	# An earlier resume that added no rows (controlplane_attempts: every cell of its flags
	# was done, or it stopped first; its rows after a harness change included) measured
	# nothing: it is left out of these notes, as the reports leave it out of the rows'
	# provenance. This one's rows are not known yet.
	_resume_zero="$(controlplane_attempts "$_resume_tsv" "$_resumes_log" 2>/dev/null \
		| awk -F'\t' -v me="$RESUME_AT" -v ip=" (in the --resume at " '
			# A change line names its run by the label (<at> as recorded, or its Z form:
			# zr maps that to <at>, $8; started_at, $11, is the Z form).
			$1 ~ /^--resume at / { if (!($8 in rows)) o[++k] = $8; rows[$8] += $4; zr[$11] = $8; next }
			(p = index($1, ip)) { t = substr($1, p + length(ip)); sub(/\)$/, "", t); if (t in zr) t = zr[t]; rows[t] += $4 }
			END { for (i = 1; i <= k; i++) if (rows[o[i]] == 0 && o[i] != me) printf "%s%s", (n++ ? "," : ""), o[i] }')" || _resume_zero=""
	_resume_changes=()
	mapfile -t _resume_changes < <(awk -F'\t' -v OFS='\037' -v h0="$_resume_harness" -v hk0="$_resume_hkey0" -v kv0="$_resume_kv0" -v zero="$_resume_zero" '
		BEGIN { nz = split(zero, zl, ","); for (i = 1; i <= nz; i++) z[zl[i]] = 1 }
		# zt(t): a time as prose prints it (UTC with Z; resumes.txt keeps +00:00).
		function zt(t) { sub(/\+00:00$/, "Z", t); return t }
		# differ(a, ak, b, bk): other harness files: another content key, or another
		# HARNESS_SHA when either key is not recorded or either HARNESS_SHA is unknown.
		function differ(a, ak, b, bk) { return (a != "unknown" && b != "unknown" && ak != "" && ak != "unknown" && bk != "" && bk != "unknown") ? (ak != bk) : (a != b) }
		$1 == "RESUMED_AT" { for (i = 1; i <= NF; i++) if ($i == "HARNESS_CONTENT_KEY") kc = i; next }
		NF < 2 || ($1 in z) { next }
		{ n++; at[n] = $1; h[n] = ($2 == "" ? "unknown" : $2); nr[n] = $3; kv[n] = (NF >= 4 ? $4 : ""); hk[n] = (kc && NF >= kc) ? $kc : "" }
		END {
			for (i = 1; i < n; i++)
				if (nr[i] != "" && nr[i] != "none" && nr[i] != "unchecked") print "R", zt(at[i]), nr[i], zt(at[i + 1])
			m = split(kv0, kq, ",")
			for (j = 1; j <= m; j++) {
				e = kq[j]; gsub(/^ +| +$/, "", e)
				if (match(e, /=[^=]*$/) && substr(e, RSTART + 1) !~ /^(unreachable|unknown)$/) {
					k0[substr(e, 1, RSTART - 1)] = substr(e, RSTART + 1)
					kpre[substr(e, 1, RSTART - 1)] = substr(e, RSTART + 1)
				}
			}
			kn = 0
			for (i = 1; i <= n; i++) {
				d = ""; ng = 0; split("", gm); split("", inv)
				m = (kv[i] == "" ? 0 : split(kv[i], kq, ","))
				for (j = 1; j <= m; j++) {
					e = kq[j]; gsub(/^ +| +$/, "", e)
					if (!match(e, /=[^=]*$/)) continue
					c = substr(e, 1, RSTART - 1); v = substr(e, RSTART + 1)
					if (v ~ /^(unreachable|unknown)$/) { if ((c in k0) || (c in kpre)) kgap[c] = 1; unr[i, c] = 1; continue }
					g = ""
					if ((c in k0) && k0[c] != v) g = k0[c] " before it, " v " then"
					else if ((c in kgap) && (c in kpre) && kpre[c] != v) g = v " again, after a resume that could not read it (the first run read " kpre[c] ")"
					if (g != "") {
						inv[c] = 1
						if (g in gm) gm[g] = gm[g] ", " c
						else { go[++ng] = g; gm[g] = c }
					}
					delete kgap[c]
					k0[c] = v
				}
				for (j = 1; j <= ng; j++) d = d (d == "" ? "" : "; ") gm[go[j]] ": " go[j]
				if (d != "") { kn++; kat[kn] = at[i]; kd[kn] = d; ki[kn] = i; for (c in inv) km[kn, c] = 1 }
			}
			for (q = 1; q <= kn; q++) {
				u = ""
				for (i = ki[q] + 1; i <= n && u == ""; i++)
					for (e in unr) { split(e, kk, SUBSEP); if (kk[1] == i && ((q, kk[2]) in km)) { u = at[i]; break } }
				print "K", zt(kat[q]), kd[q], zt(u)
			}
			seg = 0; sh[0] = (h0 == "" ? "unknown" : h0); shk[0] = hk0; sat[0] = ""; slast[0] = ""; ld = sh[0]
			for (i = 1; i <= n; i++) {
				if (differ(h[i], hk[i], sh[seg], shk[seg]) || h[i] == "unknown") { seg++; sh[seg] = h[i]; shk[seg] = hk[i]; sat[seg] = at[i] }
				else if (h[i] != ld) print "D", zt(at[i]), h[i], ld, hk[i]
				ld = h[i]
				slast[seg] = at[i]
			}
			for (s = 1; s <= seg; s++) {
				u = (s < seg ? sat[s + 1] : "")
				if (sh[s] == "unknown") print "U", zt(sat[s]), zt(u)
				else print "C", zt(sat[s]), sh[s], sh[s - 1], zt(slast[s - 1]), zt(u)
			}
			if (n < 1) exit
			if (h[n] == "unknown") { print "WU"; exit }
			lk = ""; lkk = ""; lat = ""; gap = 0
			if (h0 != "" && h0 != "unknown") { lk = h0; lkk = hk0 }
			for (i = 1; i < n; i++) if (h[i] != "unknown") { lk = h[i]; lkk = hk[i]; lat = at[i]; gap = 0 } else gap = 1
			if (lk != "" && differ(lk, lkk, h[n], hk[n])) print "W", lk, zt(lat), gap
		}' "$_resumes_log")
	for _resume_chg in ${_resume_changes[@]+"${_resume_changes[@]}"}; do
		_chg_kind="" _chg_a="" _chg_b="" _chg_c="" _chg_d="" _chg_e=""
		IFS=$'\037' read -r _chg_kind _chg_a _chg_b _chg_c _chg_d _chg_e <<<"$_resume_chg"
		case "$_chg_kind" in
		R)
			RESUME_NOTES+=(--note "istiod or IstioCNI was still not ready when the earlier --resume at ${_chg_a} started (ISTIO_NOTREADY_AT_RESUME=${_chg_b}, in resumes.txt): the first cells it ran (its rows, from ${_chg_a} until ${_chg_c}) may have run on a control plane that was not ready; check their status and istiod_restarted")
			;;
		K)
			_chg_span="rows from ${_chg_a} on ran on them, up to a later change noted here"
			[[ -z "$_chg_c" ]] || _chg_span="rows from ${_chg_a} until ${_chg_c} ran on them (the --resume at ${_chg_c} could not read every member's version, so from there on they are not known), up to a later change noted here"
			RESUME_NOTES+=(--note "the --resume at ${_chg_a} read other Kubernetes server versions than the last known ones (${_chg_b}; from the TSV preamble's KUBE_VERSIONS and resumes.txt): ${_chg_span}")
			[[ "$_chg_a" != "$RESUME_AT_Z" ]] || RESUME_OWN_NOTES+=("${RESUME_NOTES[${#RESUME_NOTES[@]} - 1]}")
			# This resume's own, at its start too (as a harness change).
			[[ "$_chg_a" != "$RESUME_AT_Z" ]] \
				|| echo "warning: --resume: this resume reads other Kubernetes server versions than the last known ones (${_chg_b}): the rows it adds (from ${RESUME_AT_Z} on) run on them. The sweep outcome records it as a note, and ${_resumes_log} lists every resume; start a new sweep if the change matters to the results." >&2
			;;
		U)
			_chg_span="from ${_chg_a} on"
			[[ -z "$_chg_b" ]] || _chg_span="from ${_chg_a} until ${_chg_b}"
			RESUME_NOTES+=(--note "the --resume at ${_chg_a} ran HARNESS_SHA=unknown (git describe failed there): rows ${_chg_span} cannot be tied to a harness")
			[[ "$_chg_a" != "$RESUME_AT_Z" ]] || RESUME_OWN_NOTES+=("${RESUME_NOTES[${#RESUME_NOTES[@]} - 1]}")
			;;
		C)
			_chg_by="the TSV preamble's, the first run's"
			[[ -z "$_chg_d" ]] || _chg_by="the --resume at ${_chg_d}"
			_chg_span="from ${_chg_a} on"
			[[ -z "$_chg_e" ]] || _chg_span="from ${_chg_a} until ${_chg_e}"
			RESUME_NOTES+=(--note "the --resume at ${_chg_a} ran HARNESS_SHA=${_chg_b}, after HARNESS_SHA=${_chg_c} (${_chg_by}): rows ${_chg_span} are ${_chg_b}'s")
			[[ "$_chg_a" != "$RESUME_AT_Z" ]] || RESUME_OWN_NOTES+=("${RESUME_NOTES[${#RESUME_NOTES[@]} - 1]}")
			;;
		D)
			RESUME_NOTES+=(--info "the --resume at ${_chg_a} ran HARNESS_SHA=${_chg_b}, after HARNESS_SHA=${_chg_c}: they differ only in git describe (a commit or tag that left the harness files as they were; the same HARNESS_CONTENT_KEY ${_chg_d}), so its rows ran the same harness")
			[[ "$_chg_a" != "$RESUME_AT_Z" ]] || RESUME_OWN_NOTES+=("${RESUME_NOTES[${#RESUME_NOTES[@]} - 1]}")
			;;
		W)
			_chg_by="the TSV preamble's, the first run's"
			[[ -z "$_chg_b" ]] || _chg_by="the --resume at ${_chg_b}"
			_chg_run="the run before it"
			[[ "$_chg_c" != 1 ]] || _chg_run="the last run before it with a known harness"
			echo "warning: --resume: this resume runs harness ${HARNESS_SHA}, and ${_chg_run} ran ${_chg_a} (${_chg_by}): the rows it adds (from ${RESUME_AT_Z} on) come from another harness. The sweep outcome records it as a note, and ${_resumes_log} lists every resume; start a new sweep if the change matters to the results." >&2
			;;
		WU)
			echo "warning: --resume: this resume runs HARNESS_SHA=unknown (git describe failed: no git, or not a checkout), so the rows it adds (from ${RESUME_AT_Z} on) cannot be tied to a harness. The sweep outcome records it as a note, and ${_resumes_log} lists every resume." >&2
			;;
		esac
	done
fi

if ((DRY_RUN)) && ! ((GROWTH)); then
	echo "--- Combinations (dry-run) ---" >&2
fi

fmt_ns_pattern() {
	local nc="$1"
	if (( nc <= 1 )); then
		printf '%s\n' "$NS"
	else
		printf '%s-0..%s-%d\n' "$NS" "$NS" "$(( nc - 1 ))"
	fi
}

ensure_output_dir() {
	[[ -d "$OUTPUT_DIR" ]] && return 0
	mkdir -p "$OUTPUT_DIR"
	echo "Output directory: $OUTPUT_DIR" >&2
}

# ---------------------------------------------------------------------------
# Background peak-memory poller for split-phase mode.
# ---------------------------------------------------------------------------
# Runs between the baseline and final 002 invocations, using the same port
# range (15014+k). Safe because 002-baseline has exited and freed its ports.
# Same sampling as 002's poll_peak_metrics; results land in the state dir.
PEAK_POLLER_PID=""
PEAK_PF_PIDS=()
BASE_PF_PORT=15014
POLL_INTERVAL=5

start_peak_metrics_poller() {
	local state_dir="$1"
	local manifest="${state_dir}/pods.tsv"
	[[ -f "$manifest" ]] || return 0
	(( ${#KUBECTL[@]} )) || return 0

	local -a pod_ctxs=() pod_names=()
	while IFS=$'\t' read -r _idx ctx pod; do
		pod_ctxs+=("$ctx")
		pod_names+=("$pod")
	done < "$manifest"
	(( ${#pod_ctxs[@]} )) || return 0

	PEAK_PF_PIDS=()
	for k in "${!pod_ctxs[@]}"; do
		local port=$(( BASE_PF_PORT + k ))
		"${KUBECTL[@]}" --context="${pod_ctxs[k]}" -n istio-system \
			port-forward "pod/${pod_names[k]}" "$port":15014 >/dev/null 2>&1 &
		PEAK_PF_PIDS+=($!)
	done
	sleep 2

	(
		trap 'exit 0' TERM
		while true; do
			for k in "${!pod_ctxs[@]}"; do
				local port=$(( BASE_PF_PORT + k ))
				local body now_t
				body=$(curl -s --max-time "${METRICS_SCRAPE_TIMEOUT:-30}" "http://localhost:${port}/metrics" 2>/dev/null) || continue
				now_t=$(now_ms)

				# Peak memory.
				local mem_val
				mem_val=$(echo "$body" | awk '/^process_resident_memory_bytes[{ ]/ && !/^#/ { print $NF+0 }')
				if [[ -n "$mem_val" && "$mem_val" != "0" ]]; then
					local prev_mem=0
					[[ -s "${state_dir}/peak-mem-${k}.val" ]] && prev_mem=$(<"${state_dir}/peak-mem-${k}.val")
					if awk -v a="$mem_val" -v b="$prev_mem" 'BEGIN{ exit !(a+0 > b+0) }'; then
						printf '%s' "$mem_val" > "${state_dir}/peak-mem-${k}.val"
					fi
				fi

				# Peak CPU rate in millicores over the measured time between samples.
				local cpu_val
				cpu_val=$(echo "$body" | awk '/^process_cpu_seconds_total[{ ]/ && !/^#/ { print $NF+0 }')
				if [[ -n "$cpu_val" && "$cpu_val" != "0" ]]; then
					local prev_cpu_file="${state_dir}/prev-cpu-${k}.val"
					if [[ -s "$prev_cpu_file" ]]; then
						local prev_cpu prev_t rate_m
						read -r prev_cpu prev_t < "$prev_cpu_file" || true
						rate_m=$(awk -v c="$cpu_val" -v p="$prev_cpu" -v dt="$(( now_t - prev_t ))" \
							'BEGIN{ if (dt <= 0) { print 0; exit }; d=(c-p)*1000000/dt; if(d<0) d=0; printf "%.0f", d }')
						local prev_peak=0
						[[ -s "${state_dir}/peak-cpu-${k}.val" ]] && prev_peak=$(<"${state_dir}/peak-cpu-${k}.val")
						if awk -v a="$rate_m" -v b="$prev_peak" 'BEGIN{ exit !(a+0 > b+0) }'; then
							printf '%s' "$rate_m" > "${state_dir}/peak-cpu-${k}.val"
						fi
					fi
					printf '%s %s\n' "$cpu_val" "$now_t" > "$prev_cpu_file"
				fi
			done
			sleep "$POLL_INTERVAL"
		done
	) &
	PEAK_POLLER_PID=$!
}

stop_peak_metrics_poller() {
	if [[ -n "$PEAK_POLLER_PID" ]]; then
		kill "$PEAK_POLLER_PID" 2>/dev/null || true
		wait "$PEAK_POLLER_PID" 2>/dev/null || true
		PEAK_POLLER_PID=""
	fi
	for pid in ${PEAK_PF_PIDS[@]+"${PEAK_PF_PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PEAK_PF_PIDS=()
}

# CELL_IN_PROGRESS: the cell whose rows are not all written yet, as the command that writes
# its status row without the status (legacy_failed, or g_row and its arguments); empty
# between cells. cell_interrupted_row (the EXIT trap) appends an INTERRUPTED row for it when
# the sweep ends there (interrupted, or stopped), so the cell's latest attempt reads as
# failed, never as measured from the rows written so far, and a --resume runs it again. A
# sweep killed outright writes none: the reports and a --resume then find it INCOMPLETE
# (fewer member rows than its mesh size) or, when all its rows were written, done. A legacy
# cell whose rows this attempt already wrote in full (002 --phase final appended every
# member's, and the sweep ended in its diagnostics or the cleanup after) gets no INTERRUPTED
# row: it is done, by the rule a --resume and the reports use (CP_CELL_AWK cp_cell_state on
# the rows after CELL_START_LINE, the TSV's line count when the cell started).
CELL_IN_PROGRESS=()
CELL_START_LINE=0
# legacy_cell_written: true when the rows after CELL_START_LINE make the current legacy cell
# (the loop's ms sc rc nc scp tc) done: every member's rows, one per istiod replica, and its
# last row a measurement row.
# shellcheck disable=SC2329  # invoked by cell_interrupted_row
legacy_cell_written() {
	local tsv="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" r
	[[ -f "$tsv" ]] || return 1
	r="$(awk -F'\t' -v s="${CELL_START_LINE:-0}" -v st="$CELL_STATUS_RE" -v ms="${ms:-}" -v sc="${sc:-}" -v rc="${rc:-}" \
		-v nc="${nc:-}" -v scp="${scp:-}" -v tc="${tc:-}" -v wk="$LEGACY_WINDOW_KIND" "${CP_CELL_AWK}"'
		BEGIN { want = ms SUBSEP sc SUBSEP rc SUBSEP nc SUBSEP scp SUBSEP tc SUBSEP wk }
		/^timestamp\t/ { cp_header(); next }
		/^#/ { cp_comment(); next }
		FNR <= s + 0 || !cp_isrow() { next }
		{ k = cp_key(); if (k == want) cp_cell_row(k, st) }
		END { cp_end(); if ((want in cp_ms) && cp_cell_state(want) == "") print "done" }' "$tsv" 2>/dev/null)" || return 1
	[[ "$r" == "done" ]]
}
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cell_interrupted_row() {
	((${#CELL_IN_PROGRESS[@]})) || return 0
	[[ "${BASHPID:-$$}" == "$$" ]] || return 0
	local -a cir=("${CELL_IN_PROGRESS[@]}")
	CELL_IN_PROGRESS=()
	if [[ "${cir[0]}" == legacy_failed ]] && legacy_cell_written; then
		echo "note: the cell in progress (${label:-the last cell}) had written every member's rows before the sweep ended: it is done (no INTERRUPTED row), and a --resume keeps it" >&2
		return 0
	fi
	# A subshell: emit_failed_row dies when it cannot end a cut last line, and an exit in
	# this EXIT trap would skip the outcome record after it.
	( "${cir[0]}" INTERRUPTED "${cir[@]:1}" ) 2>/dev/null \
		|| echo "warning: could not write the INTERRUPTED row of the cell in progress; a --resume finds it by its rows" >&2
}

# resume_added_rows: the rows (status rows too) this --resume added to the TSV after the
# line count it started at (_resume_lines); nothing when that is not known.
resume_added_rows() {
	[[ -n "$RESUME_DIR" && "${_resume_lines:-}" =~ ^[0-9]+$ ]] || return 0
	awk -F'\t' -v s="$_resume_lines" "${CP_CELL_AWK}"'/^timestamp\t/ { cp_header(); next } FNR > s + 0 && !/^#/ && cp_isrow() { n++ } END { print n + 0 }' "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" 2>/dev/null || true
}
# resume_own_notes_drop: drops this --resume's own notes (RESUME_OWN_NOTES: its harness or
# Kubernetes change) from RESUME_NOTES, which holds pairs (--note|--info, text): a resume
# that added no rows measured nothing on them.
resume_own_notes_drop() {
	local i own keep=()
	for ((i = 0; i + 1 < ${#RESUME_NOTES[@]}; i += 2)); do
		for own in ${RESUME_OWN_NOTES[@]+"${RESUME_OWN_NOTES[@]}"}; do [[ "${RESUME_NOTES[i + 1]}" != "$own" ]] || continue 2; done
		keep+=("${RESUME_NOTES[i]}" "${RESUME_NOTES[i + 1]}")
	done
	RESUME_NOTES=(${keep[@]+"${keep[@]}"})
	RESUME_OWN_NOTES=()
}
# resume_own_notes_at_exit: the EXIT trap's, for a --resume that stops or is interrupted
# before it adds a row (the sweep's end does the same, then empties RESUME_OWN_NOTES).
# shellcheck disable=SC2329  # invoked by the EXIT trap below
resume_own_notes_at_exit() {
	((${#RESUME_OWN_NOTES[@]})) || return 0
	[[ "$(resume_added_rows)" != 0 ]] || resume_own_notes_drop
}

# A step that still runs first (sweep_step_kill: after a second signal, 002 may still be
# writing rows), then the poller and scratch dir (SWEEP_TMP), then the cell in progress,
# then a run that ends before its outcome (die, an unexpected abort, Ctrl-C) says how in
# that record, stopped with its reason or interrupted, with the notes this run gathered so
# far (a --resume's, without its own when it added no row).
_sweep_rc=0 # the trap's own $?, kept before its first step changes it
trap '_sweep_rc=$?; sweep_step_kill || true; stop_peak_metrics_poller 2>/dev/null || true; rm -rf "$SWEEP_TMP" 2>/dev/null || true; cell_interrupted_row || true; resume_own_notes_at_exit || true; sweep_outcome_on_exit "$_sweep_rc" ${RESUME_NOTES[@]+"${RESUME_NOTES[@]}"} || true' EXIT

# Pre-create the TSV preamble before any combo (skipped in dry-run). A fresh sweep with
# --config also gets the run-config-<RUN_ID>.env replay copy; a resumed one keeps the
# config it started with.
if ((! DRY_RUN)); then
	ensure_output_dir
	# Until its outcome is written at the end, sweep-outcome.txt says this run has not
	# finished (a run that dies keeps it; a --resume moved a finished record to .prev above).
	# Its next step is the full command (the record is shared: "<sweep dir>", which the
	# console prints next to it); a growth series is never resumed.
	if ((GROWTH)); then
		_so_start=(--next "if it died, run the sweep again into a new dir (a growth series is not resumed)")
	else
		# The command before a closing parenthesis: a stop prints the note with a period.
		_so_start=(--next "if it died, --resume this sweep dir with the flags it ran with (the cells already measured are kept): $(resume_cmd_record "$(planned_axis_flags)") (<sweep dir> is this sweep's directory)")
	fi
	# The record's times are UTC with Z, as its STARTED_AT and ENDED_AT (RESUME_AT keeps
	# the rows' +00:00 format for the TSV and resumes.txt).
	[[ -z "$RESUME_DIR" ]] || _so_start+=(--resumed-at "$RESUME_AT_Z")
	# The console's next step after an interrupt or a stop: the same command with this
	# sweep dir's path (the record keeps "<sweep dir>").
	# shellcheck disable=SC2034  # read by sweep_outcome_on_exit (tests/lib/common.sh)
	((GROWTH)) || SWEEP_NEXT_CONSOLE="$(resume_cmd_console "$(planned_axis_flags)")"
	sweep_outcome_start "$OUTPUT_DIR" "$RUN_ID" "${_so_start[@]}"
	# The cells this run plans, before the first one.
	if ! ((GROWTH)); then
		planned_cells_record
		((PLANNED_PARTIAL == 0)) \
			|| RESUME_NOTES+=(--note "this sweep's planned cells are not all known (planned-cells.txt: an older harness started it without one), so cells its first run planned but never reached are not counted; the count covers the cells with rows and the matrix of each later run")
	fi
	metrics_preflight
	precreate_tsv_preamble
	[[ -n "$RESUME_DIR" ]] || config_snapshot "$OUTPUT_DIR" "$RUN_ID"
	if ((GROWTH)); then
		# Namespace-lifecycle timings (001/005 append) and the memory guard's decisions.
		ns_lifecycle_init "$LIFECYCLE_FILE" "$RUN_ID"
		mapfile -t _iv_kv < <(istio_version_kv)
		write_preamble "Memory stop guard (controlplane growth mode)" "$GUARD_FILE" \
			"RUN_ID=${RUN_ID}" "HARNESS_SHA=${HARNESS_SHA}" "${_iv_kv[@]}" \
			"MEM_STOP_PCT=${MEM_STOP_PCT}" "MEM_GUARD_CONTEXTS=$(IFS=,; echo "${GUARD_CONTEXTS[*]}")" \
			"GUARD_SCHEMA=2" "GW_MODEL=intercept ${GW_MI_INTERCEPT} Mi; eastwestgateway ${EWGW_MI_PER_1000} Mi per 1000 Services x ${EWGW_BURST}; ingressgateway ${INGW_MI_PER_1000} Mi per 1000 Services x ${INGW_BURST}" \
			"NOTE=rel_projected = base + (current - base) x ratio^power from the series start (ratio 1: the first step and changes that add no Services); abs_projected (gateways) = (intercept + Mi per 1000 Services x services_after / 1000) x burst factor, plus the non-heap part of a working-set reading (ws - Envoy physical heap); services_after = the context's istiod pilot_services + the Services the step adds; projected = the larger, compared with stop_pct % of limit_mi. metric: rss = istiod process_resident_memory_bytes (max over replicas, per-replica limit); ws = the gateway container's working set (kubectl top), else physical = Envoy server.memory_physical_size, else allocated = server.memory_allocated (istio-proxy limit). verdict stale_base: a gateway's Envoy allocated memory exceeded 1.5 x the model + 100 Mi at the series start (memory kept from an earlier series)."
		printf 'timestamp\tseries\tcell\tcontext\tcomponent\tmetric\tcurrent_mi\tbase_mi\tratio\tpower\trel_projected_mi\tservices_after\tabs_projected_mi\tprojected_mi\tlimit_mi\tstop_pct\tverdict\n' >> "$GUARD_FILE"
	fi
fi

# ---------------------------------------------------------------------------
# Namespace scaling (growth mode).
# ---------------------------------------------------------------------------
# One series per mesh size x K. In place, a series grows one set of namespaces up
# the --namespace-counts ladder. At each N: switch back to namespace scoping (grow
# rows are always scoping namespace), a grow window (baseline -> 001 adds namespaces
# N_prev..N-1 -> settle -> final), then per scoping a switch (001 --parts sidecars)
# and a probe window (baseline -> 001 --parts probe -> probe settle -> final); 005
# --probe then retires the probe namespace (Services and Sidecar first) and the
# probe settle runs again before the next baseline. At the largest N come the outside
# phases and the M-sweep; the series ends per --series-retire. Every step is wrapped
# (PL32): a failure becomes a status row and the sweep goes on; a failed grow stops
# the series and its remaining cells are recorded as SKIPPED_SERIES_STOPPED. Before
# each larger step the memory guard projects istiod heap and gateway memory on every
# guard context and records a cell that would cross MEM_STOP_PCT % of a limit as
# SKIPPED_MEM_GUARD.

CELL_IDX=0
PROBE_IDX=0
declare -A GUARD_BASE=()  # "<ctx>|<component>" -> MiB at the series start
declare -A GUARD_WIDE=()  # "<ctx>|istiod" -> heap MiB after the last wide probe
GUARD_WIDE_N=0            # discovered namespaces at that measurement
# Series state (set by run_growth_series / run_growth_fresh).
G_SID=""
G_K=0
G_MS=0
G_ACTIVE_CSV=""
G_REPLICAS=1
G_M=1
G_CUR_SCOPE=""
G_STOPPED=""
G_WIDE_STOPPED=0

# g_ratio <a> <b>: a / b (4 decimals); 1 when b is not positive.
g_ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (b + 0 <= 0) print 1; else printf "%.4f\n", a / b }'; }

# guard_sample_ctx <ctx> <ctx_index>: one istiod line and one line per gateway:
#   "istiod <rss_mi> rss <limit_mi> <services> istiod <heap_inuse_mi>"
#   "gw:<pod> <guard_mi> <metric> <limit_mi> <services> <kind> <allocated_mi> <physical_mi>"
# istiod: max process_resident_memory_bytes over the context's istiod pods (the RSS
# the OOM killer acts on; heap_inuse ran about half of it on ROSA), the per-replica
# limit, and pilot_services (max over pods). Gateways (BACKLOG 9.5): the container
# working set from kubectl top (metric ws), else Envoy server.memory_physical_size
# (physical: the tcmalloc heap with the freed pages it kept), else
# server.memory_allocated (allocated, an underestimate after config bursts); kind is
# the istio label; services is the context's istiod pilot_services. The port-forwards
# close on return. A context without a reachable istiod prints no istiod line (and its
# gateways read services -); nothing here can abort the sweep (PL40).
guard_sample_ctx() {
	local ctx="$1" ci="$2" ist svc="-"
	ist="$(
		local -a pids=() ports=() pods=()
		local dir i r h s max="" hmax="" smax="" lim="unknown" kv
		dir="$(mktemp -d "${SWEEP_TMP}/guard.XXXXXX")"
		trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$dir"' EXIT
		fanout_open "$ctx" "$ci" pids ports pods "${KUBECTL[@]}" 2>/dev/null
		fanout_scrape_all "$dir" g "${ports[@]}" >/dev/null 2>&1 || true
		for i in "${!ports[@]}"; do
			r="$(awk '/^process_resident_memory_bytes[ {]/ { v = $NF } END { if (v != "") printf "%.0f\n", v / 1048576 }' "${dir}/g-${i}.metrics" 2>/dev/null)"
			h="$(growth_istiod_heap_mi "${dir}/g-${i}.metrics")"
			s="$(awk '/^pilot_services[ {]/ { v += $NF; seen = 1 } END { if (seen) printf "%.0f\n", v }' "${dir}/g-${i}.metrics" 2>/dev/null)"
			if [[ "$r" =~ ^[0-9]+$ ]] && { [[ -z "$max" ]] || ((r > max)); }; then max="$r"; fi
			if [[ "$h" =~ ^[0-9]+$ ]] && { [[ -z "$hmax" ]] || ((h > hmax)); }; then hmax="$h"; fi
			if [[ "$s" =~ ^[0-9]+$ ]] && { [[ -z "$smax" ]] || ((s > smax)); }; then smax="$s"; fi
		done
		for kv in $(cap_istiod_limits "$ctx" "${KUBECTL[@]}"); do
			[[ "$kv" == mem_mi=* ]] && lim="${kv#mem_mi=}"
		done
		[[ -n "$max" ]] && echo "istiod ${max} rss ${lim} ${smax:--} istiod ${hmax:--}"
		exit 0
	)" || ist=""
	if [[ -n "$ist" ]]; then
		echo "$ist"
		svc="$(awk '{ print $5 }' <<<"$ist")"
	fi
	local pod plim kind kv mem phy ws metric val
	declare -A wsm=()
	while IFS=$'\t' read -r pod ws; do
		[[ -n "$pod" ]] && wsm[$pod]="$ws"
	done < <(growth_gateway_ws "$ctx" "${KUBECTL[@]}")
	while IFS=$'\t' read -r pod plim kind; do
		[[ -n "$pod" ]] || continue
		kv="$(growth_envoy_stats "$ctx" istio-system "$pod" "${KUBECTL[@]}")"
		mem="$(_growth_kv mem_mi "$kv")"
		phy="$(_growth_kv physical_mi "$kv")"
		ws="${wsm[$pod]:-}"
		if [[ "$ws" =~ ^[0-9]+$ ]]; then metric=ws; val="$ws"
		elif [[ "$phy" =~ ^[0-9]+$ ]]; then metric=physical; val="$phy"
		elif [[ "$mem" =~ ^[0-9]+$ ]]; then metric=allocated; val="$mem"
		else continue
		fi
		[[ "$mem" =~ ^[0-9]+$ ]] || mem="-"
		[[ "$phy" =~ ^[0-9]+$ ]] || phy="-"
		echo "gw:${pod} ${val} ${metric} ${plim} ${svc} ${kind:-unknown} ${mem} ${phy}"
	done < <(growth_gateway_pods "$ctx" "${KUBECTL[@]}")
	return 0
}

# guard_collect <assoc_name>: sample every guard context into "<ctx>|<component>" ->
# "<current_mi> <metric> <limit_mi> <services> <kind> <allocated_mi> <physical_mi>".
guard_collect() {
	local -n _gc="$1"
	_gc=()
	local ci comp rest
	for ci in "${!GUARD_CONTEXTS[@]}"; do
		while read -r comp rest; do
			[[ -n "$comp" ]] || continue
			_gc["${GUARD_CONTEXTS[ci]}|${comp}"]="$rest"
		done < <(guard_sample_ctx "${GUARD_CONTEXTS[ci]}" "$ci")
	done
}

# guard_gw_model <kind>: "<mi_per_1000_services> <burst_factor>" of the absolute model
# (an unknown kind takes the east-west figures, the larger).
guard_gw_model() {
	case "$1" in
	ingressgateway) echo "$INGW_MI_PER_1000 $INGW_BURST" ;;
	*) echo "$EWGW_MI_PER_1000 $EWGW_BURST" ;;
	esac
}

# guard_log <cell> <ctx> <component> <metric> <cur> <base> <ratio> <power> <rel_proj>
#           <services_after> <abs_proj> <projected> <limit> <verdict>
guard_log() {
	[[ -f "$GUARD_FILE" ]] || return 0
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u -Iseconds)" "$G_SID" \
		"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}" "$MEM_STOP_PCT" "${14}" >> "$GUARD_FILE"
}

# guard_baseline: the empty-mesh reference of a series (before its first step). Warns
# when a gateway already holds far more than the absolute model expects for the
# Services the mesh has now (BACKLOG 9.4: Envoy kept about 500 Mi after a series was
# undiscovered, which inflated the next series' base): restart the gateways first.
guard_baseline() {
	GUARD_BASE=()
	GUARD_WIDE=()
	GUARD_WIDE_N=0
	((MEM_STOP_PCT > 0)) || return 0
	local -A now=()
	guard_collect now
	local key cur metric lim svc kind alloc ctx amodel per burst stale=0
	for key in "${!now[@]}"; do
		read -r cur metric lim svc kind alloc _ <<<"${now[$key]}"
		GUARD_BASE[$key]="$cur"
		[[ "${key#*|}" == gw:* && "$svc" =~ ^[0-9]+$ && "$alloc" =~ ^[0-9]+$ ]] || continue
		read -r per burst <<<"$(guard_gw_model "$kind")"
		# Envoy's allocated memory tracks its live config: far above the model for the
		# Services the mesh has now (x1.5 + 100 Mi) means memory kept from earlier config.
		amodel="$(mem_guard_project_abs "$svc" "$per" "$GW_MI_INTERCEPT" 1.5)"
		[[ "$amodel" =~ ^[0-9]+$ ]] || continue
		if ((alloc > amodel + 100)); then
			stale=1
			echo "WARNING: memory guard: ${key}: Envoy allocated ${alloc} Mi at the series start, above the ${amodel} Mi the model allows for ${svc} Services (memory kept from an earlier series). Restart the gateways between series (oc -n istio-system rollout restart deploy -l 'istio in (ingressgateway,eastwestgateway)' on each member, nothing measuring) for clean numbers; the absolute projection still guards every step." >&2
			guard_log "series start" "${key%%|*}" "${key#*|}" allocated "$alloc" "$alloc" 1 1 "$alloc" "$svc" "$amodel" "$alloc" "$lim" stale_base
		fi
	done
	for ctx in "${GUARD_CONTEXTS[@]}"; do
		[[ -n "${GUARD_BASE["${ctx}|istiod"]:-}" ]] \
			|| echo "warn: memory guard: no istiod RSS readable on ${ctx}; its istiod is not guarded and its gateways get no absolute projection" >&2
	done
	echo "Memory guard baseline: ${#GUARD_BASE[@]} component(s) on ${#GUARD_CONTEXTS[@]} context(s) (stop at ${MEM_STOP_PCT}% of a limit)$( ((stale)) && echo '; stale gateway memory, see the warning')"
}

# guard_check <cell> <istiod_ratio> <istiod_power> <gateway_ratio> <use_wide>
#             <added_services>: 0 to run the cell, 1 to skip it. Each component is
# projected relative to the series start, base + (current - base) x ratio^power (with
# use_wide, istiod's "current" is its RSS after the last wide probe, GUARD_WIDE, so a
# wide cell projects quadratically from the last wide measurement; ratio 1 = current
# usage only). Gateways are also projected absolutely for the Services the mesh holds
# after the step (pilot_services + added_services; mem_guard_project_abs), which also
# covers a series' first step (ratio 1) and an inflated base (BACKLOG 9.4). The model is
# Envoy's heap; a working-set reading adds the container's non-heap memory (working set
# minus Envoy's physical heap: pilot-agent, binary, page cache; 40-200 Mi on the lab). The
# larger projection stops the cell when it exceeds MEM_STOP_PCT % of the limit.
guard_check() {
	local cell="$1" ir="$2" ip="$3" gr="$4" use_wide="${5:-0}" added="${6:-0}"
	((MEM_STOP_PCT > 0)) || return 0
	local -A now=()
	guard_collect now
	if ((${#now[@]} == 0)); then
		echo "warn: memory guard: nothing could be sampled before '${cell}'; running it unguarded" >&2
		guard_log "$cell" - - - - - - - - - - - - unknown
		return 0
	fi
	local key cur metric lim svc kind phy base r p rel abs sa per burst proj verdict stop=0 comp over
	for key in "${!now[@]}"; do
		read -r cur metric lim svc kind _ phy <<<"${now[$key]}"
		comp="${key#*|}"
		base="${GUARD_BASE[$key]:-$cur}"
		abs="-"
		sa="-"
		if [[ "$comp" == istiod ]]; then
			r="$ir"
			p="$ip"
			if ((use_wide)) && [[ -n "${GUARD_WIDE[$key]:-}" ]]; then cur="${GUARD_WIDE[$key]}"; fi
		else
			r="$gr"
			p=1
			if [[ "$svc" =~ ^[0-9]+$ ]]; then
				sa=$((svc + added))
				read -r per burst <<<"$(guard_gw_model "$kind")"
				abs="$(mem_guard_project_abs "$sa" "$per" "$GW_MI_INTERCEPT" "$burst")"
				over=0
				[[ "$metric" == ws && "${phy:-}" =~ ^[0-9]+$ ]] && ((cur > phy)) && over=$((cur - phy))
				[[ "$abs" =~ ^[0-9]+$ ]] && abs=$((abs + over))
			fi
		fi
		rel="$(mem_guard_project "$cur" "$base" "$r" "$p")"
		proj="$rel"
		if [[ "$abs" =~ ^[0-9]+$ ]] && { ! [[ "$proj" =~ ^[0-9]+$ ]] || ((abs > proj)); }; then proj="$abs"; fi
		verdict="$(mem_guard_verdict "$proj" "$lim" "$MEM_STOP_PCT")"
		guard_log "$cell" "${key%%|*}" "$comp" "$metric" "$cur" "$base" "$r" "$p" "$rel" "$sa" "$abs" "$proj" "$lim" "$verdict"
		if [[ "$verdict" == stop ]]; then
			echo "  memory guard: ${key}: projected ${proj} Mi > ${MEM_STOP_PCT}% of ${lim} Mi (${metric} now ${cur} Mi, base ${base} Mi, x ${r}^${p} = ${rel} Mi$([[ "$abs" == - ]] || echo "; model for ${sa} Services ${abs} Mi")); skipping '${cell}'" >&2
			stop=1
		fi
	done
	((stop == 0))
}

# guard_note_wide <discovered_namespaces>: remember istiod RSS after a wide probe.
guard_note_wide() {
	((MEM_STOP_PCT > 0)) || return 0
	local -A now=()
	guard_collect now
	local key cur rest
	for key in "${!now[@]}"; do
		[[ "${key#*|}" == istiod ]] || continue
		read -r cur rest <<<"${now[$key]}"
		GUARD_WIDE[$key]="$cur"
	done
	GUARD_WIDE_N="$1"
}

# g001 <args...>: 001 with the series' common arguments.
g001() {
	sweep_step "$SCRIPT_DIR/001-setup-controlplane-test.sh" --contexts "$G_ACTIVE_CSV" \
		--services-per-namespace "$G_K" --series "$G_SID" --workload-mode "$WORKLOAD_MODE" \
		--replicas "${REPLICA_COUNTS[0]}" --lifecycle-file "$LIFECYCLE_FILE" "$@"
}

# g002 <phase> <state_dir> <n> <scoping> <window_kind> <outside_x> <outside_mode> <m> [args...]
g002() {
	local phase="$1" state="$2" n="$3" scp="$4" kind="$5" ox="$6" od="$7" m="$8"
	shift 8
	sweep_step "$SCRIPT_DIR/002-collect-resource-metrics.sh" --phase "$phase" --state-dir "$state" \
		--contexts "$G_ACTIVE_CSV" --mesh-size "$G_MS" \
		--service-count "$(( n * G_K ))" --replicas "$G_REPLICAS" --namespace-count "$n" \
		--sidecar-scoping "$scp" --traffic-config none \
		--services-per-namespace "$G_K" --workload-mode "$WORKLOAD_MODE" --measurement-pods "$m" \
		--outside-namespaces "$ox" --outside-mode "$od" --window-kind "$kind" --series "$G_SID" \
		--run-id "$RUN_ID" "$@"
}

# g_row <status> <n> <scoping> <window_kind> <outside_x> <outside_mode> <m>: a status
# row for a growth cell (same growth columns 002 writes).
g_row() {
	local status="$1" n="$2" scp="$3" kind="$4" ox="$5" od="$6" m="$7" mp
	if [[ "$WORKLOAD_MODE" == config-only ]]; then
		mp=$(( m < n ? m : n ))
	else
		mp=$(( n * G_K * G_REPLICAS ))
	fi
	((ox > 0)) || od=none
	emit_failed_row "$status" "$G_MS" "$(( n * G_K ))" "$G_REPLICAS" "$n" "$scp" none \
		"$G_K" "$WORKLOAD_MODE" "$mp" "$ox" "$od" "$kind"
}

# g_skip <status> <n> <scoping> <window_kind> <outside_x> <outside_mode> <m>: a planned
# cell that does not run.
g_skip() {
	CELL_IDX=$((CELL_IDX + 1))
	printf "  [%d/%d] series=%s N=%s %s scope=%s: %s\n" "$CELL_IDX" "$MATRIX_SIZE" "$G_SID" "$2" "$4" "$3" "$1" >&2
	g_row "$@"
}

# g_window <window_kind> <n> <scoping> <outside_x> <outside_mode> <m> <settle>
#          <fail_status> <001 args...>: one measured window around one 001 call.
# Returns 1 when 001 failed (a <fail_status> row is recorded), else 0. A failed
# baseline is recorded as PROBE_FAILED and 001 still runs, so the series goes on.
g_window() {
	local kind="$1" n="$2" scp="$3" ox="$4" od="$5" m="$6" settle="$7" fail_status="$8"
	shift 8
	CELL_IDX=$((CELL_IDX + 1))
	local label="series=${G_SID} K=${G_K} N=${n} ${kind} scope=${scp} M=${m} outside=${ox}/${od}"
	local state="${OUTPUT_DIR}/state-cell-${CELL_IDX}" measured=1
	echo "=========================================="
	printf "  Growth cell [%d/%d]: %s\n" "$CELL_IDX" "$MATRIX_SIZE" "$label"
	echo "=========================================="
	mkdir -p "$state"
	CELL_IN_PROGRESS=(g_row "$n" "$scp" "$kind" "$ox" "$od" "$m")
	if ! g002 baseline "$state" "$n" "$scp" "$kind" "$ox" "$od" "$m" --settle "$settle"; then
		echo "warn: baseline probe failed for '${label}'; recording PROBE_FAILED and applying anyway" >&2
		CELL_IN_PROGRESS=()
		g_row PROBE_FAILED "$n" "$scp" "$kind" "$ox" "$od" "$m"
		measured=0
	fi
	((measured)) && start_peak_metrics_poller "$state"
	if ! g001 "$@"; then
		stop_peak_metrics_poller
		echo "warn: setup failed for '${label}'; recording ${fail_status}" >&2
		CELL_IN_PROGRESS=()
		((measured)) && g_row "$fail_status" "$n" "$scp" "$kind" "$ox" "$od" "$m"
		rm -rf "$state"
		return 1
	fi
	if ((settle > 0)); then
		echo "--- Settling ${settle}s before the final scrape ---"
		sleep "$settle"
	fi
	stop_peak_metrics_poller
	if ((measured)); then
		if ! g002 final "$state" "$n" "$scp" "$kind" "$ox" "$od" "$m" \
			--config-dump-samples "$CONFIG_DUMP_SAMPLES" --settle "$settle" --output-dir "$OUTPUT_DIR"; then
			echo "warn: final probe failed for '${label}'; recording PROBE_FAILED" >&2
			CELL_IN_PROGRESS=()
			g_row PROBE_FAILED "$n" "$scp" "$kind" "$ox" "$od" "$m"
		fi
	fi
	CELL_IN_PROGRESS=()
	rm -rf "$state"
	return 0
}

# g_switch <scoping> <n>: switch the series' n namespaces to a scoping in place.
g_switch() {
	local scp="$1" n="$2"
	echo "--- Scoping switch: series ${G_SID} -> ${scp} (${n} namespaces) ---"
	if g001 --parts sidecars --namespace-count "$n" --sidecar-scoping "$scp" --measurement-pods "$G_M"; then
		G_CUR_SCOPE="$scp"
		if ((SETTLE_SEC > 0)); then sleep "$SETTLE_SEC"; fi
		return 0
	fi
	G_CUR_SCOPE="?"
	return 1
}

# g_probe <n> <scoping> <outside_x> <outside_mode> <m>: one probe window, then the
# probe namespace's retirement and the probe settle (also after a failed apply).
g_probe() {
	local n="$1" scp="$2" ox="$3" od="$4" m="$5"
	PROBE_IDX=$((PROBE_IDX + 1))
	local pname="${NS}-${G_SID}-p${PROBE_IDX}"
	g_window probe "$n" "$scp" "$ox" "$od" "$m" "$PROBE_SETTLE_SEC" SETUP_FAILED \
		--parts probe --probe "$pname" --namespace-count "$n" --sidecar-scoping "$scp" --measurement-pods "$G_M" || true
	sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$G_ACTIVE_CSV" --probe "$pname" --lifecycle-file "$LIFECYCLE_FILE" \
		|| echo "warn: retiring probe namespace ${pname} reported a failure" >&2
	if ((PROBE_SETTLE_SEC > 0)); then
		echo "--- Probe settle ${PROBE_SETTLE_SEC}s after the probe teardown ---"
		sleep "$PROBE_SETTLE_SEC"
	fi
}

# g_probe_scopings <n> <outside_x> <outside_mode> <m> <discovered_namespaces>: one
# probe per scoping at the current step, each behind its own guard check. The scoping
# the series already has goes first (after a grow that is namespace), which saves one
# rewrite of every Sidecar of the series per step.
g_probe_scopings() {
	local n="$1" ox="$2" od="$3" m="$4" n_disc="$5" scp r
	local -a order=()
	for scp in "${SCOPINGS[@]}"; do [[ "$scp" == "$G_CUR_SCOPE" ]] && order+=("$scp"); done
	for scp in "${SCOPINGS[@]}"; do [[ "$scp" == "$G_CUR_SCOPE" ]] || order+=("$scp"); done
	for scp in "${order[@]}"; do
		if [[ -n "$G_STOPPED" ]]; then
			g_skip "$G_STOPPED" "$n" "$scp" probe "$ox" "$od" "$m"
			continue
		fi
		if [[ "$scp" == wide ]] && ((G_WIDE_STOPPED)); then
			g_skip SKIPPED_MEM_GUARD "$n" "$scp" probe "$ox" "$od" "$m"
			continue
		fi
		if [[ "$scp" != "$G_CUR_SCOPE" ]]; then
			if [[ "$scp" == wide ]]; then
				r=1
				((GUARD_WIDE_N > 0)) && r="$(g_ratio "$n_disc" "$GUARD_WIDE_N")"
				if ! guard_check "probe wide N=${n}" "$r" 2 1 1 "$G_K"; then
					G_WIDE_STOPPED=1
					g_skip SKIPPED_MEM_GUARD "$n" "$scp" probe "$ox" "$od" "$m"
					continue
				fi
			elif ! guard_check "probe ${scp} N=${n}" 1 1 1 0 "$G_K"; then
				g_skip SKIPPED_MEM_GUARD "$n" "$scp" probe "$ox" "$od" "$m"
				continue
			fi
			if ! g_switch "$scp" "$n"; then
				g_skip SWITCH_FAILED "$n" "$scp" probe "$ox" "$od" "$m"
				continue
			fi
		fi
		g_probe "$n" "$scp" "$ox" "$od" "$m"
		[[ "$scp" == wide ]] && guard_note_wide "$n_disc"
	done
	return 0
}

# SWEEP_STOPPED: set when a series could not be retired; no later series runs and the
# sweep exits 1 after its report (BACKLOG 9.3: R1b's failed retire left 2000
# namespaces discovered under the next series).
SWEEP_STOPPED=""

# g_retire_cmd <series> <cleanup args...>: retire a series' (or fresh cell's)
# namespaces through 005 and verify on the active contexts that none is still
# discovered (growth_retire_verified: CONTROLPLANE_RETIRE_ATTEMPTS tries). 1 = not.
g_retire_cmd() {
	local sid="$1"
	shift
	growth_retire_verified KUBECTL "$G_ACTIVE_CSV" "app.kubernetes.io/instance=controlplane-test,controlplane-test.series=${sid}" \
		"$RETIRE_ATTEMPTS" "$RETIRE_BACKOFF_S" -- \
		sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$G_ACTIVE_CSV" --series "$sid" --lifecycle-file "$LIFECYCLE_FILE" "$@"
}

# g_retire_failed <series> <n> <window_kind_detail>: record RETIRE_FAILED and stop the sweep.
g_retire_failed() {
	local sid="$1" n="$2"
	g_row RETIRE_FAILED "$n" namespace retire 0 none "$G_M"
	SWEEP_STOPPED="series ${sid} was not retired on ${G_ACTIVE_CSV} (the cleanup failed, or its namespaces are still discovered)"
	echo "ERROR: ${SWEEP_STOPPED}. No further series runs. Retire it by hand before any other sweep: ${SCRIPT_DIR}/005-cleanup.sh --contexts ${G_ACTIVE_CSV} --series ${sid} --undiscover --no-delete" >&2
}

# g_retire <n>: end a series per --series-retire (then the PL18 settle).
g_retire() {
	local n="$1"
	echo "--- Retiring series ${G_SID} (${SERIES_RETIRE}) ---"
	case "$SERIES_RETIRE" in
	undiscover)
		g_retire_cmd "$G_SID" --undiscover --no-delete || g_retire_failed "$G_SID" "$n"
		;;
	delete)
		g_retire_cmd "$G_SID" --undiscover --no-wait || g_retire_failed "$G_SID" "$n"
		;;
	keep)
		echo "Series ${G_SID} stays discovered (--series-retire keep); remove it later with 005 --series ${G_SID}."
		;;
	esac
	if ((SETTLE_SEC > 0)); then sleep "$SETTLE_SEC"; fi
}

# g_series_start_count: log the controlplane-test namespaces on the active contexts at a
# series start (BACKLOG 9.10) to the namespace-lifecycle TSV (action leftover-check:
# namespaces = all of them, objects = the discovered ones; status LEFTOVER above
# CONTROLPLANE_LEFTOVER_NS_WARN). Every row of the series also carries its own count
# (column leftover_test_namespaces).
g_series_start_count() {
	local c kv total disc st
	for c in "${CONTEXTS[@]:0:$G_MS}"; do
		kv="$(growth_test_ns_counts "$c" "${KUBECTL[@]}")"
		total="$(_growth_kv total "$kv")"
		disc="$(_growth_kv discovered "$kv")"
		st=OK
		[[ "$total" =~ ^[0-9]+$ ]] && ((total > LEFTOVER_NS_WARN)) && st=LEFTOVER
		echo "Series ${G_SID} start: ${c} holds ${total} controlplane-test namespace(s) from earlier series or runs (${disc} discovered)"
		ns_lifecycle_row "$LIFECYCLE_FILE" "$c" "$G_SID" 0 leftover-check "$total" "$disc" N/A N/A N/A N/A "$st"
	done
}

# run_growth_series <mesh_size> <K> <series_index>: one in-place series.
run_growth_series() {
	G_MS="$1"
	G_K="$2"
	G_SID="${SERIES_PREFIX}-$3"
	local -a active=("${CONTEXTS[@]:0:$G_MS}")
	G_ACTIVE_CSV="$(IFS=,; echo "${active[*]}")"
	G_REPLICAS="${REPLICA_COUNTS[0]}"
	[[ "$WORKLOAD_MODE" == config-only ]] && G_REPLICAS=1
	G_M="${M_LIST[0]}"
	G_CUR_SCOPE=""
	G_STOPPED=""
	G_WIDE_STOPPED=0
	echo ""
	echo "########## Growth series ${G_SID}: mesh=${G_MS} K=${G_K} on ${active[*]} ##########"
	g_series_start_count
	guard_baseline
	local n n_prev=0 r
	for n in "${NAMESPACE_COUNTS[@]}"; do
		if [[ -z "$G_STOPPED" && -n "$G_CUR_SCOPE" && "$G_CUR_SCOPE" != namespace ]]; then
			# Grow rows are always measured under namespace scoping (switch back first).
			if ! g_switch namespace "$n_prev"; then
				g_skip SWITCH_FAILED "$n" namespace grow 0 none "$G_M"
				G_STOPPED=SKIPPED_SERIES_STOPPED
				g_probe_scopings "$n" 0 none "$G_M" "$n"
				continue
			fi
		fi
		if [[ -n "$G_STOPPED" ]]; then
			g_skip "$G_STOPPED" "$n" namespace grow 0 none "$G_M"
			g_probe_scopings "$n" 0 none "$G_M" "$n"
			continue
		fi
		r=1
		((n_prev > 0)) && r="$(g_ratio "$n" "$n_prev")"
		if ! guard_check "grow ${n_prev}->${n}" "$r" 1 "$r" 0 "$(( (n - n_prev) * G_K ))"; then
			G_STOPPED=SKIPPED_MEM_GUARD
			g_skip SKIPPED_MEM_GUARD "$n" namespace grow 0 none "$G_M"
			g_probe_scopings "$n" 0 none "$G_M" "$n"
			continue
		fi
		if ! g_window grow "$n" namespace 0 none "$G_M" "$SETTLE_SEC" GROW_FAILED \
			--namespace-start "$n_prev" --namespace-count "$n" --sidecar-scoping namespace --measurement-pods "$G_M"; then
			G_STOPPED=SKIPPED_SERIES_STOPPED
			g_probe_scopings "$n" 0 none "$G_M" "$n"
			continue
		fi
		G_CUR_SCOPE=namespace
		n_prev="$n"
		g_probe_scopings "$n" 0 none "$G_M" "$n"
	done
	local n_last="$n_prev" om ox_state=0 od_state=none n_disc="$n_prev"
	# Outside phases at the largest N reached, in order (unlabeled, then the label flip).
	for om in "${OUTSIDE_PHASES[@]}"; do
		local stopped="${G_STOPPED:-}"
		((n_last > 0)) || stopped="${stopped:-SKIPPED_SERIES_STOPPED}"
		if [[ -z "$stopped" && "$G_CUR_SCOPE" != namespace ]] && ! g_switch namespace "$n_last"; then
			stopped=SWITCH_FAILED
		fi
		r=1
		local o_added=0
		[[ "$om" == labeled ]] && r="$(g_ratio "$(( n_last + OUTSIDE_NAMESPACES ))" "$n_last")" && o_added=$(( OUTSIDE_NAMESPACES * G_K ))
		if [[ -z "$stopped" ]] && ! guard_check "outside ${om} N=${n_last}" "$r" 1 "$r" 0 "$o_added"; then
			stopped=SKIPPED_MEM_GUARD
		fi
		if [[ -z "$stopped" ]] && ! g_window outside "$n_last" namespace "$OUTSIDE_NAMESPACES" "$om" "$G_M" "$SETTLE_SEC" SETUP_FAILED \
			--parts outside --outside-namespaces "$OUTSIDE_NAMESPACES" --outside-mode "$om" \
			--namespace-count "$n_last" --sidecar-scoping namespace --measurement-pods "$G_M"; then
			# The window recorded SETUP_FAILED; its probes cannot run against an unknown state.
			local scp
			for scp in "${SCOPINGS[@]}"; do g_skip SKIPPED_SERIES_STOPPED "$n_last" "$scp" probe "$OUTSIDE_NAMESPACES" "$om" "$G_M"; done
			continue
		fi
		if [[ -n "$stopped" ]]; then
			g_skip "$stopped" "$n_last" namespace outside "$OUTSIDE_NAMESPACES" "$om" "$G_M"
			local scp
			for scp in "${SCOPINGS[@]}"; do g_skip "$stopped" "$n_last" "$scp" probe "$OUTSIDE_NAMESPACES" "$om" "$G_M"; done
			continue
		fi
		G_CUR_SCOPE=namespace
		ox_state="$OUTSIDE_NAMESPACES"
		od_state="$om"
		n_disc="$n_last"
		[[ "$om" == labeled ]] && n_disc=$(( n_last + OUTSIDE_NAMESPACES ))
		g_probe_scopings "$n_last" "$ox_state" "$od_state" "$G_M" "$n_disc"
	done
	# M-sweep at the largest N: more measurement pods, every scoping again.
	local m
	for m in "${M_LIST[@]:1}"; do
		local mstop="${G_STOPPED:-}"
		((n_last > 0)) || mstop="${mstop:-SKIPPED_SERIES_STOPPED}"
		if [[ -z "$mstop" ]]; then
			echo "--- M-sweep: measurement pods ${G_M} -> ${m} (N=${n_last}) ---"
			if g001 --parts measurement --measurement-pods "$m" --namespace-count "$n_last" --sidecar-scoping namespace; then
				G_M="$m"
				if ((SETTLE_SEC > 0)); then sleep "$SETTLE_SEC"; fi
			else
				mstop=SETUP_FAILED
			fi
		fi
		if [[ -n "$mstop" ]]; then
			local scp
			for scp in "${SCOPINGS[@]}"; do g_skip "$mstop" "$n_last" "$scp" probe "$ox_state" "$od_state" "$m"; done
			continue
		fi
		g_probe_scopings "$n_last" "$ox_state" "$od_state" "$m" "$n_disc"
	done
	g_retire "$n_last"
}

# run_growth_fresh <mesh_size> <K> <series_index>: --growth fresh, one full deploy and
# cleanup per N x scoping cell (each cell its own series id, so a Terminating
# namespace of the previous cell never collides with the next).
run_growth_fresh() {
	G_MS="$1"
	G_K="$2"
	local base_sid="${SERIES_PREFIX}-$3" f=0 n scp timeout
	local -a active=("${CONTEXTS[@]:0:$G_MS}")
	G_ACTIVE_CSV="$(IFS=,; echo "${active[*]}")"
	G_REPLICAS="${REPLICA_COUNTS[0]}"
	[[ "$WORKLOAD_MODE" == config-only ]] && G_REPLICAS=1
	G_M="${M_LIST[0]}"
	G_STOPPED=""
	echo ""
	echo "########## Growth series ${base_sid} (fresh): mesh=${G_MS} K=${G_K} on ${active[*]} ##########"
	G_SID="$base_sid"
	g_series_start_count
	guard_baseline
	for n in "${NAMESPACE_COUNTS[@]}"; do
		for scp in "${SCOPINGS[@]}"; do
			f=$((f + 1))
			G_SID="${base_sid}f${f}"
			if ! guard_check "fresh N=${n} ${scp}" 1 1 1 0 "$(( n * G_K ))"; then
				g_skip SKIPPED_MEM_GUARD "$n" "$scp" deploy 0 none "$G_M"
				continue
			fi
			g_window deploy "$n" "$scp" 0 none "$G_M" "$SETTLE_SEC" SETUP_FAILED \
				--namespace-count "$n" --sidecar-scoping "$scp" --measurement-pods "$G_M" || true
			# Bounded wait (PL4/PL37), scaled to the namespaces this cell deletes. The cell
			# is verified gone or undiscovered before the next one (BACKLOG 9.3).
			timeout="$(awk -v n="$n" -v s="$NS_DELETE_SEC_PER_NS" -v t="${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}" \
				'BEGIN { v = int(2 * n * s + 60); print (v > t ? v : t) }')"
			if ! g_retire_cmd "$G_SID" --timeout "$timeout"; then
				g_retire_failed "$G_SID" "$n"
				return 0
			fi
			if ((SETTLE_SEC > 0)); then
				echo "--- Post-cleanup settle (${SETTLE_SEC}s) ---" >&2
				sleep "$SETTLE_SEC"
			fi
		done
	done
}

# print_growth_plan: the series, steps and cells; object and namespace counts; the
# later namespace-deletion estimate. Printed before a live run and by --dry-run.
print_growth_plan() {
	local ms k idx=0 n prev probes pods peak_ns deletes=0 s_list="${SCOPINGS[*]}" x=0
	((${#OUTSIDE_PHASES[@]})) && x="$OUTSIDE_NAMESPACES"
	echo "--- Growth plan (${GROWTH_MODE}) ---"
	for ms in "${MESH_SIZES[@]}"; do
		for k in "${SPNS[@]}"; do
			idx=$((idx + 1))
			echo "  series ${SERIES_PREFIX}-${idx}: mesh=${ms} K=${k} workload=${WORKLOAD_MODE} on ${CONTEXTS[*]:0:$ms}"
			if [[ "$GROWTH_MODE" == fresh ]]; then
				for n in "${NAMESPACE_COUNTS[@]}"; do
					echo "    N=${n}: one deploy cell per scoping (${s_list}): ${n} namespaces, $(( n * k )) Services each, then 005 deletes them and waits"
					deletes=$(( deletes + n * ${#SCOPINGS[@]} ))
				done
				continue
			fi
			prev=0
			probes=0
			for n in "${NAMESPACE_COUNTS[@]}"; do
				echo "    step N=${n}: +$(( n - prev )) namespaces, +$(( (n - prev) * k )) Services, +$(( n - prev )) Sidecars; cells: grow (namespace), probe ${s_list}"
				prev="$n"
				probes=$(( probes + ${#SCOPINGS[@]} ))
			done
			if ((${#OUTSIDE_PHASES[@]})); then
				echo "    outside at N=${prev}: ${OUTSIDE_NAMESPACES} namespaces outside the mesh (+$(( OUTSIDE_NAMESPACES * k )) Services), phases ${OUTSIDE_PHASES[*]}; cells per phase: outside, probe ${s_list}"
				probes=$(( probes + ${#OUTSIDE_PHASES[@]} * ${#SCOPINGS[@]} ))
			fi
			if ((${#M_LIST[@]} > 1)); then
				echo "    M-sweep at N=${prev}: measurement pods ${M_LIST[*]:1}; cells per M: probe ${s_list}"
				probes=$(( probes + (${#M_LIST[@]} - 1) * ${#SCOPINGS[@]} ))
			fi
			if [[ "$WORKLOAD_MODE" == config-only ]]; then
				pods="${M_LIST[${#M_LIST[@]}-1]}"
				((pods > prev)) && pods="$prev"
				pods="${pods} measurement pod(s)"
			else
				pods="$(( prev * k * REPLICA_COUNTS[0] )) pod(s)"
			fi
			peak_ns=$(( prev + x + 1 ))
			echo "    peak on the measured member(s): ${peak_ns} namespaces, $(( peak_ns * k )) Services, up to $(( prev + 1 )) Sidecars, ${pods}; ${probes} probe namespace(s) created and retired"
			echo "    then: ${SERIES_RETIRE}"
			# Probe namespaces are deleted during the run (each one empty).
			deletes=$(( deletes + prev + x ))
		done
	done
	echo "  namespaces left to delete afterwards: ~${deletes}, about $(awk -v n="$deletes" -v s="$NS_DELETE_SEC_PER_NS" 'BEGIN { printf "%.0f", n * s / 60 }') min at ${NS_DELETE_SEC_PER_NS} s each (CONTROLPLANE_NS_DELETE_SEC_PER_NS; calibrate with the rate 005 prints)"
	echo ""
}

# run_growth_sweep: every series, in mesh-size then K order.
run_growth_sweep() {
	local ms k idx=0
	for ms in "${MESH_SIZES[@]}"; do
		for k in "${SPNS[@]}"; do
			idx=$((idx + 1))
			if [[ -n "$SWEEP_STOPPED" ]]; then
				echo "Series ${SERIES_PREFIX}-${idx} (mesh=${ms} K=${k}) not run: ${SWEEP_STOPPED}" >&2
				continue
			fi
			if [[ "$GROWTH_MODE" == fresh ]]; then
				run_growth_fresh "$ms" "$k" "$idx"
			else
				run_growth_series "$ms" "$k" "$idx"
			fi
		done
	done
}

# legacy_failed <status>: the current legacy cell's status row (the loop's ms sc rc nc
# scp tc), with the window kind the sweep measures.
legacy_failed() {
	CELL_IN_PROGRESS=()
	emit_failed_row "$1" "$ms" "$sc" "$rc" "$nc" "$scp" "$tc" 0 pods "$(( sc * rc ))" 0 none "$LEGACY_WINDOW_KIND"
}


combo_idx=0
if ((GROWTH)); then
	print_growth_plan >&2
	if ! ((DRY_RUN)); then
		run_growth_sweep
	fi
	combo_idx="$CELL_IDX"
	((DRY_RUN)) && combo_idx="$MATRIX_SIZE"
else
# The leftover check deleted namespaces before the first cell (legacy_leftover_preflight):
# that cell's baseline waits for the deletion's pushes, as after every cell's cleanup.
if ((LEFTOVER_DELETED && SETTLE_SEC > 0)); then
	echo "--- Post-cleanup settle (${SETTLE_SEC}s) ---" >&2
	sleep "$SETTLE_SEC"
fi
for ms in "${MESH_SIZES[@]}"; do
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	active_csv=$(IFS=,; echo "${active_ctxs[*]}")
	for sc in "${SERVICE_COUNTS[@]}"; do
		for rc in "${REPLICA_COUNTS[@]}"; do
			for nc in "${NAMESPACE_COUNTS[@]}"; do
				for scp in "${SCOPINGS[@]}"; do
					# Innermost axis: a none/vsdr pair runs back to back on the same base cell.
					for tc in "${TRAFFIC_CONFIGS[@]}"; do
						combo_idx=$((combo_idx + 1))
						label="mesh=$ms svcs=$sc reps=$rc ns=$nc scope=$scp traffic=$tc"
						ns_pattern=$(fmt_ns_pattern "$nc")

						if ((DRY_RUN)); then
							printf "  [%2d/%2d] %s  (clusters: %s)  Namespaces: %s\n" \
								"$combo_idx" "$MATRIX_SIZE" "$label" "${active_ctxs[*]}" "$ns_pattern" >&2
							continue
						fi

						# Skip a combo already completed in the resumed sweep.
						if combo_already_done "$ms" "$sc" "$rc" "$nc" "$scp" "$tc"; then
							printf "  [%d/%d] %s — already has a valid row; skipping (resume)\n" \
								"$combo_idx" "$MATRIX_SIZE" "$label" >&2
							continue
						fi
						# One that failed partway, or was cut short, runs again, as a new attempt.
						_pw="${RESUME_RERUN["${ms}|${sc}|${rc}|${nc}|${scp}|${tc}"]:-}"
						if [[ "$_pw" == INCOMPLETE* ]]; then
							printf "  [%d/%d] %s — cut short while its rows were written (%s): running it again; the reports use only this new attempt (resume)\n" \
								"$combo_idx" "$MATRIX_SIZE" "$label" "$_pw" >&2
							RERUN_RAN=$((RERUN_RAN + 1))
						elif [[ -n "$_pw" ]]; then
							printf "  [%d/%d] %s — failed partway (a valid row, then %s): running it again; the reports use only this new attempt (resume)\n" \
								"$combo_idx" "$MATRIX_SIZE" "$label" "$_pw" >&2
							RERUN_RAN=$((RERUN_RAN + 1))
						fi

						ensure_output_dir

						echo "=========================================="
						printf "  Sweep [%d/%d]: %s\n" "$combo_idx" "$MATRIX_SIZE" "$label"
						echo "  Clusters:   ${active_ctxs[*]}"
						echo "  Namespaces: ${ns_pattern}"
						echo "=========================================="
						echo ""

						STATE_DIR_COMBO="${OUTPUT_DIR}/state-combo-${combo_idx}"
						# A run cut short leaves its cell's state dir (a resume reuses the cell
						# index): its peak samples would join this window's.
						rm -rf "$STATE_DIR_COMBO"
						mkdir -p "$STATE_DIR_COMBO"
						CELL_IN_PROGRESS=(legacy_failed)
						# The rows after this line are this attempt's (cell_interrupted_row).
						CELL_START_LINE="$(wc -l < "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" 2>/dev/null | tr -d ' ')" || CELL_START_LINE=0
						[[ "$CELL_START_LINE" =~ ^[0-9]+$ ]] || CELL_START_LINE=0
						# The cell's axes for 001 and 002; a split VS/DR apply measures window kind
						# traffic.
						cell_args=(--contexts "$active_csv" --service-count "$sc" --replicas "$rc" --namespace-count "$nc"
							--sidecar-scoping "$scp" --traffic-config "$tc" --vsdr-every "$VSDR_EVERY" --vsdr-subsets "$VSDR_SUBSETS")
						m002_args=("${cell_args[@]}" --mesh-size "$ms" --window-kind "$LEGACY_WINDOW_KIND" --settle "$SETTLE_SEC" --run-id "$RUN_ID")

						if [[ "$VSDR_APPLY" == split ]]; then
							# Phase 0 (outside the window): the namespaces, Services, Sidecars
							# and the per-subset Deployments, Ready before the baseline (BACKLOG
							# 9.11).
							echo "--- Deploying workloads before the window (split apply, scoping=$scp, traffic=$tc) ---"
							if ! sweep_step "$SCRIPT_DIR/001-setup-controlplane-test.sh" "${cell_args[@]}" --parts workloads; then
								echo "warn: [$combo_idx/$MATRIX_SIZE] workloads setup failed for '$label'; recording SETUP_FAILED row and continuing" >&2
								legacy_failed SETUP_FAILED
								sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
									echo "warn: cleanup after setup failure also reported failure for '$label'" >&2
								rm -rf "$STATE_DIR_COMBO"
								if (( SETTLE_SEC > 0 )); then sleep "$SETTLE_SEC"; fi
								continue
							fi
							# Let the workload pushes finish before the baseline.
							if (( SETTLE_SEC > 0 )); then
								echo "--- Settling ${SETTLE_SEC}s after the workloads before the baseline ---"
								sleep "$SETTLE_SEC"
							fi
							echo ""
						fi

						echo "--- Baseline metrics scrape (phase 1/3) ---"
						if ! sweep_step "$SCRIPT_DIR/002-collect-resource-metrics.sh" --phase baseline --state-dir "$STATE_DIR_COMBO" "${m002_args[@]}"; then
							# Baseline failed: record the combo, clean up, move on.
							echo "warn: [$combo_idx/$MATRIX_SIZE] baseline probe failed for '$label'; recording PROBE_FAILED row and continuing" >&2
							legacy_failed PROBE_FAILED
							sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
								echo "warn: cleanup after baseline failure also reported failure for '$label'" >&2
							rm -rf "$STATE_DIR_COMBO"
							if (( SETTLE_SEC > 0 )); then sleep "$SETTLE_SEC"; fi
							continue
						fi
						echo ""

						start_peak_metrics_poller "$STATE_DIR_COMBO"

						# Setup failed: stop the poller, record SETUP_FAILED, clean up, move on.
						setup_ok=1
						if [[ "$VSDR_APPLY" == split ]]; then
							if [[ "$tc" == vsdr ]]; then
								echo "--- Applying the VirtualServices and DestinationRules (phase 2/3, split apply) ---"
								sweep_step "$SCRIPT_DIR/001-setup-controlplane-test.sh" "${cell_args[@]}" --parts traffic || setup_ok=0
							else
								echo "--- Phase 2/3: nothing to apply (traffic none, split apply: an idle window over the same workloads) ---"
							fi
						else
							echo "--- Deploying workloads (phase 2/3, scoping=$scp, traffic=$tc) ---"
							sweep_step "$SCRIPT_DIR/001-setup-controlplane-test.sh" "${cell_args[@]}" || setup_ok=0
						fi
						if ! ((setup_ok)); then
							echo "warn: [$combo_idx/$MATRIX_SIZE] setup failed for '$label'; recording SETUP_FAILED row and continuing" >&2
							stop_peak_metrics_poller   # MUST stop before continue — poller runs in background
							legacy_failed SETUP_FAILED
							sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
								echo "warn: cleanup after setup failure also reported failure for '$label'" >&2
							rm -rf "$STATE_DIR_COMBO"
							if (( SETTLE_SEC > 0 )); then sleep "$SETTLE_SEC"; fi
							continue
						fi
						echo ""

						if (( SETTLE_SEC > 0 )); then
							echo "--- Settling ${SETTLE_SEC}s for steady-state before final scrape ---"
							sleep "$SETTLE_SEC"
							echo ""
						fi

						stop_peak_metrics_poller

						echo "--- Final metrics scrape + emit (phase 3/3) — window covers baseline → apply → settle ---"
						if ! sweep_step "$SCRIPT_DIR/002-collect-resource-metrics.sh" --phase final --state-dir "$STATE_DIR_COMBO" "${m002_args[@]}" \
							--config-dump-samples "$CONFIG_DUMP_SAMPLES" --output-dir "$OUTPUT_DIR"; then
							# Final scrape failed: record PROBE_FAILED; cleanup still runs below.
							echo "warn: [$combo_idx/$MATRIX_SIZE] final probe failed for '$label'; recording PROBE_FAILED row and continuing" >&2
							legacy_failed PROBE_FAILED
						fi
						CELL_IN_PROGRESS=()
						rm -rf "$STATE_DIR_COMBO"
						echo ""

						echo "--- Cleaning up ---"
						# 005 waits (bounded) for namespace termination. A failure only warns:
						# the next 001 waits for any leftover namespace before applying.
						sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
							echo "warn: [$combo_idx/$MATRIX_SIZE] cleanup reported failure for '$label'; next setup waits for the namespace to clear" >&2

						# Post-cleanup settle: when 005 deletes the test namespace,
						# istiod re-pushes a broader (no-Sidecar) config to remaining
						# proxies. Without this sleep, the next combo's baseline scrape
						# lands inside that push storm.
						if (( SETTLE_SEC > 0 )); then
							echo "--- Post-cleanup settle (${SETTLE_SEC}s) ---" >&2
							sleep "$SETTLE_SEC"
						fi
						echo ""
					done
				done
			done
		done
	done
done
fi

if ((DRY_RUN)); then
	echo "" >&2
	echo "Dry-run complete. $combo_idx combinations enumerated; no clusters touched." >&2
	exit 0
fi

echo "=========================================="
if [[ -n "$SWEEP_STOPPED" ]]; then
	echo "  Sweep STOPPED early ($combo_idx cells; see the ERROR below)"
else
	echo "  Sweep finished ($combo_idx combinations)"
fi
echo "=========================================="
echo ""
# The Istio version again, after the last window and before the reports (read-only).
IV_END=()
istio_version_recheck IV_END ${KUBECTL[@]+"${KUBECTL[@]}"}
# A harness change an earlier run recorded is carried as a PROBLEM (above). It becomes
# a NOTE when no row of that run is in the figures (controlplane_attempts: it wrote
# none, the NOTE then ending "(that run wrote no rows)", or its rows, and those of
# the harness changes in it, were all left out, a later attempt of each cell kept:
# "(its rows were all run again later)") and the rows the figures keep ran one harness
# (harness_same on every pair, one known HARNESS_SHA or HARNESS_CONTENT_KEY: the rule
# 004's verdict uses), so no figure comes from the changed harness. That run is the one
# before this resume that started last before its outcome's date (a resume can start in
# the second an outcome was written, this one or an earlier one), or at or before its
# start for a record it did not finish, the first run when none did; a record with no
# date, or rows that could not be counted, keep the PROBLEM. A PROBLEM it keeps ends
# with why, "(kept: ...)"; the NOTE drops the PROBLEM's advice to run the sweep again
# (no row of that run is left to run).
if [[ -n "$RESUME_DIR" ]] && ! ((DRY_RUN)); then
	_cr_att="$(controlplane_attempts "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" "${OUTPUT_DIR}/resumes.txt" 2>/dev/null)" || _cr_att=""
	# The harness of each attempt with kept rows; each run's start, rows and kept rows.
	_cr_hs=() _cr_runs=()
	mapfile -t _cr_hs < <(awk -F'\t' 'NF >= 11 && $9 > 0 { print $2 "\t" $10 }' <<< "$_cr_att")
	mapfile -t _cr_runs < <(awk -F'\t' 'NF >= 11 {
			if (index($1, "harness changed at ") != 1) { if (n++) print t "\t" r "\t" k; t = $11; r = 0; k = 0 }
			r += $4; k += $9
		}
		END { if (n) print t "\t" r "\t" k }' <<< "$_cr_att")
	_cr_one=0
	((${#_cr_hs[@]} == 0)) || _cr_one=1
	for _cr_a in ${_cr_hs[@]+"${_cr_hs[@]}"}; do
		[[ "$_cr_a" != $'unknown\tunknown' ]] || _cr_one=0
		for _cr_b in "${_cr_hs[@]}"; do
			harness_same "${_cr_a%%$'\t'*}" "${_cr_a#*$'\t'}" "${_cr_b%%$'\t'*}" "${_cr_b#*$'\t'}" || _cr_one=0
		done
	done
	for ((_cr_i = 0; _cr_i + 1 < ${#RESUME_NOTES[@]}; _cr_i += 2)); do
		[[ "${RESUME_NOTES[_cr_i]}" == --problem ]] || continue
		_cr_t="${RESUME_NOTES[_cr_i + 1]}"
		[[ "$_cr_t" == "an earlier run of this sweep ("*") recorded: the harness changed during the sweep"* ]] || continue
		_cr_d="${_cr_t#an earlier run of this sweep (}"
		_cr_out=0
		case "$_cr_d" in
		"outcome of "*) _cr_d="${_cr_d#outcome of }"; _cr_d="${_cr_d%%) recorded: *}"; _cr_out=1 ;;
		"started at "*) _cr_d="${_cr_d#started at }"; _cr_d="${_cr_d%%, not finished) recorded: *}" ;;
		esac
		_cr_why="its record names no date, so the run it is about is not known"
		if [[ "$_cr_d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
			_cr_run="${_cr_runs[0]:-}"
			for _cr_r in ${_cr_runs[@]+"${_cr_runs[@]}"}; do
				_cr_s="${_cr_r%%$'\t'*}"
				[[ "$_cr_s" == unknown || "$_cr_s" > "$_cr_d" || ("$_cr_out" == 1 && "$_cr_s" == "$_cr_d") || "$_cr_s" == "$RESUME_AT_Z" ]] || _cr_run="$_cr_r"
			done
			# Its rows, none kept, and the rows kept ran one harness.
			_cr_rows="" _cr_kept=""
			IFS=$'\t' read -r _ _cr_rows _cr_kept <<<"$_cr_run" || true
			if [[ "$_cr_kept" =~ ^[1-9][0-9]*$ ]]; then
				_cr_why="${_cr_kept} row(s) of that run are in the figures"
			elif [[ ! "$_cr_rows" =~ ^[0-9]+$ ]]; then
				_cr_why="that run's rows could not be counted"
			elif ! ((_cr_one)); then
				_cr_why="the rows in the figures ran more than one harness, or one not recorded"
			else
				_cr_why="its rows were all run again later"
				[[ "$_cr_rows" != 0 ]] || _cr_why="that run wrote no rows"
				RESUME_NOTES[_cr_i]=--note
				RESUME_NOTES[_cr_i + 1]="${_cr_t%; run the sweep again if the change matters} (${_cr_why})"
				continue
			fi
		fi
		RESUME_NOTES[_cr_i + 1]="${_cr_t} (kept: ${_cr_why})"
	done
fi
# These reports come before this run's outcome is written; a resume's earlier one (in
# sweep-outcome.prev.txt) is not theirs to show.
export _SWEEP_OUTCOME_PENDING=1
# The PROBLEMs that outcome will record, for the reports' verdict (env_sla_verdict: a PASS
# reads CAUTION): the end-of-sweep Istio recheck's, those carried from an earlier run, and
# a harness that changed during the sweep (the end check, read now: sweep_outcome records
# this same answer). Not that the cells could not be counted: the reports count them.
_so_hs=""
_harness_sha_sweep_end _so_hs
_so_np=0
for _so_a in ${IV_END[@]+"${IV_END[@]}"} ${RESUME_NOTES[@]+"${RESUME_NOTES[@]}"}; do
	[[ "$_so_a" != --problem ]] || _so_np=$((_so_np + 1))
done
[[ -z "$_so_hs" ]] || _so_np=$((_so_np + 1))
export _SWEEP_OUTCOME_PROBLEMS="$_so_np"
echo "Generating report..."
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR"

MD_FILE="${OUTPUT_DIR}/sweep-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR" --format markdown > "$MD_FILE"
echo "Markdown summary written to $MD_FILE"

CHARTS_FILE="${OUTPUT_DIR}/sweep-charts-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR" --format charts > "$CHARTS_FILE"
echo "Charts written to $CHARTS_FILE"

# Campaign scale envelope (docs/campaigns/TEMPLATE.md), best-effort: a render
# failure warns but never fails the sweep.
ENVELOPE_FILE="${OUTPUT_DIR}/scale-envelope-${RUN_ID}.md"
# Keep the render's stderr so the warning shows the actual reason.
ENVELOPE_ERR="${SWEEP_TMP}/envelope.err"
# Subshell: render_scale_envelope uses die(), which must not abort the sweep.
if ( render_scale_envelope "$OUTPUT_DIR" "$SCRIPT_DIR/004-report-results.sh" \
		"$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}" ) > "$ENVELOPE_FILE" 2>"$ENVELOPE_ERR"; then
	echo "Scale envelope written to $ENVELOPE_FILE"
else
	rm -f "$ENVELOPE_FILE"
	echo "warning: scale-envelope generation failed (sweep data is safe above):" >&2
	sed 's/^/  /' "$ENVELOPE_ERR" >&2
fi
rm -f "$ENVELOPE_ERR"

# Every cell without a measurement has the status row emit_failed_row wrote (its
# context column is the status); count them by reason, the memory guard's SKIPPED_* apart
# (skipped on purpose, not failed: C2), also in sweep-outcome.txt and the markdown
# summary. The RETIRE_FAILED stop (exit 1) wins over 4 (some cells failed, or the
# Istio version or active revision changed under the sweep). Once per cell, keyed
# as combo_already_done keys it (the five axes, traffic_config, window_kind), and decided
# by its latest attempt (controlplane_latest_attempts; the rows of an earlier attempt are
# left out, as in the reports) with the rule a --resume uses (CP_CELL_AWK cp_cell_state): a
# last row that is a status row fails it, with that row's reason (also after a context's
# rows: a partial failure; INTERRUPTED: the run ended inside it); a last row that is a
# measurement (valid or not) does not, unless the cell's rows name fewer members than its
# mesh size, or fewer than its WINDOW_ROWS lines name (INCOMPLETE: cut short while they
# were written). The total is every cell of the TSV, of this run's matrix and of
# planned-cells.txt (each earlier run's), so a narrower --resume never reads "2 of 1", and
# a planned cell with no row counts failed as NOT_RUN. A growth series is never
# resumed, and its cells share that key (M-sweep, outside phases), so each of its status
# rows is a cell of its own, of the plan.
CELL_KEYS=""
if ! ((GROWTH)); then
	CELL_KEYS="$(matrix_cell_keys)"
fi
# The plan's keys go in a file (in the environment, past about 4,200 cells, awk could
# not even start), and a count that does not end with its TOTAL line is a problem, never
# "all cells ran". As the report, a line shorter than 40 columns is not a row.
# A keys file that cannot be read is that too (getline -1 would end the loop and count
# the rows only). The EXIT trap removes it (SWEEP_TMP) on an interrupt.
CELL_RESULT=()
_cells_dir="${SWEEP_TMP}/cells"
mkdir -p "$_cells_dir" 2>/dev/null || true
printf '%s\n' "$CELL_KEYS" > "${_cells_dir}/keys"
_cells_plan=/dev/null
((GROWTH)) || [[ ! -f "$PLANNED_FILE" ]] || _cells_plan="$PLANNED_FILE"
_cells_rc=0
controlplane_latest_attempts "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" "${OUTPUT_DIR}/resumes.txt" "${_cells_dir}/tsv" > /dev/null 2> "${_cells_dir}/err" \
	|| _cells_rc=2
((_cells_rc)) || awk -F'\t' -v growth="$GROWTH" -v keys="${_cells_dir}/keys" -v plan="$_cells_plan" -v tname="controlplane-${RUN_ID}.tsv" -v st="$CELL_STATUS_RE" "${CP_CELL_AWK}"'
	function addkey(k, p) { if (!(k in cell)) { cell[k] = 1; ncell++; korder[++nk] = k; kplan[k] = p } }
	BEGIN {
		np = cp_plan_load(plan, tname)
		if (np < 0) { print "awk: cannot read planned-cells.txt" > "/dev/stderr"; bad = 1; exit 2 }
		for (i = 1; i <= np; i++) addkey(cp_plan_order[i], cp_plan[cp_plan_order[i]])
		while ((r = (getline line < keys)) > 0)
			if (split(line, f, "\t") >= 7) addkey(f[1] SUBSEP f[2] SUBSEP f[3] SUBSEP f[4] SUBSEP f[5] SUBSEP f[6] SUBSEP f[7], "")
		if (r < 0) { print "awk: cannot read the plan cell keys file" > "/dev/stderr"; bad = 1; exit 2 }
		close(keys)
	}
	/^timestamp\t/ { cp_header(); next }
	/^#/ { cp_comment(); next }
	!cp_isrow() { next }
	{
		k = cp_key()
		if (!(k in cell)) { cell[k] = 1; ncell++ }
		if (!(k in row)) order[++n] = k
		row[k] = 1
		if (cp_cell_row(k, st) && growth) print "FAILED\t" $2
	}
	END {
		if (bad) exit 2
		cp_end()
		print "TOTAL\t" ncell
		if (!growth) for (i = 1; i <= n; i++) {
			s = cp_cell_state(order[i])
			if (s == "") continue
			print "FAILED\t" s
			if (s == "INCOMPLETE") ninc++
			else if (order[i] in cp_valid) npw++
		}
		print "PARTWAY\t" npw + 0
		print "INCOMPLETE\t" ninc + 0
		for (i = 1; i <= nk; i++) if (!(korder[i] in row)) {
			split(korder[i], f, SUBSEP)
			printf "NOTRUN\t%s\tmesh=%s svcs=%s reps=%s ns=%s scope=%s traffic=%s\n", kplan[korder[i]], f[1], f[2], f[3], f[4], f[5], f[6]
		}
	}' "${_cells_dir}/tsv" > "${_cells_dir}/out" 2>> "${_cells_dir}/err" || _cells_rc=$?
[[ ! -f "${_cells_dir}/out" ]] || mapfile -t CELL_RESULT < "${_cells_dir}/out"
# The why goes into the record: no local path in it (the temp dir, the sweep dir).
_cells_why="$(head -n 1 "${_cells_dir}/err")"
_cells_why="${_cells_why//"$_cells_dir"/<tmp>}"
_cells_why="${_cells_why//"$OUTPUT_DIR"/<sweep dir>}"
_cells_why="${_cells_why:0:200}"
rm -rf "$_cells_dir"
_cells_dir=""
FAILED_CELLS=() CELL_COUNT_ARGS=() NOTRUN_CELLS=() NOTRUN_PLANS=()
CELLS_TOTAL="" _cells_seen="" _cells_pw=0 _cells_inc=0
for _cell_line in ${CELL_RESULT[@]+"${CELL_RESULT[@]}"}; do
	case "$_cell_line" in
	FAILED$'\t'*) FAILED_CELLS+=("${_cell_line#FAILED$'\t'}") ;;
	TOTAL$'\t'*) _cells_seen="${_cell_line#TOTAL$'\t'}" ;;
	PARTWAY$'\t'*) _cells_pw="${_cell_line#PARTWAY$'\t'}" ;;
	INCOMPLETE$'\t'*) _cells_inc="${_cell_line#INCOMPLETE$'\t'}" ;;
	NOTRUN$'\t'*)
		_cell_line="${_cell_line#NOTRUN$'\t'}"
		FAILED_CELLS+=(NOT_RUN)
		NOTRUN_CELLS+=("${_cell_line#*$'\t'}")
		[[ -z "${_cell_line%%$'\t'*}" || " ${NOTRUN_PLANS[*]-} " == *" ${_cell_line%%$'\t'*} "* ]] || NOTRUN_PLANS+=("${_cell_line%%$'\t'*}")
		;;
	esac
done
_cells_where="The report includes their status rows as placeholder rows (from each cell's latest attempt, in n_total, not n_valid)"
((${#NOTRUN_CELLS[@]} == 0)) || _cells_where+="; NOT_RUN cells have no row (planned-cells.txt lists them)"
if ((_cells_rc == 0)) && is_nonneg_int "$_cells_seen"; then
	CELLS_TOTAL="$_cells_seen"
	((GROWTH == 0 && CELLS_TOTAL > 0)) || CELLS_TOTAL="$MATRIX_SIZE"
	if is_nonneg_int "$_cells_pw" && ((_cells_pw > 0)); then
		_cells_where+="; ${_cells_pw} of them failed partway (a valid row, then a status row): the next --resume runs them again (as every failed cell), and the reports then use only that new attempt"
	fi
	if is_nonneg_int "$_cells_inc" && ((_cells_inc > 0)); then
		_cells_where+="; ${_cells_inc} of them (INCOMPLETE) were cut short while their member rows were written (fewer members have a row than the mesh size, or a member fewer rows than its window wrote, or in rows an older harness wrote one by one than its istiod replicas, and no status row): the report keeps their rows with a data warning, and the next --resume runs them again"
	fi
	((RERUN_RAN == 0)) || _cells_where+=". ${RERUN_RAN} cell(s) that had failed partway in an earlier run ran again in this one; the reports use only that new attempt"
	if ((${#NOTRUN_CELLS[@]})); then
		_nr_list="$(printf '%s; ' "${NOTRUN_CELLS[@]:0:5}")"
		_nr_list="${_nr_list%; }"
		((${#NOTRUN_CELLS[@]} <= 5)) || _nr_list+="; and $((${#NOTRUN_CELLS[@]} - 5)) more"
		# The full command of each plan that planned them (resume_cmd_record: no local path),
		# before a closing parenthesis, as NEXT: a stop prints the note with a trailing ".",
		# which a command at the end would take into its last flag on a copy-paste.
		_nr_cmds=""
		for _nr_p in ${NOTRUN_PLANS[@]+"${NOTRUN_PLANS[@]}"}; do
			_nr_l="$(grep -m 1 "^# PLAN=${_nr_p} " "$PLANNED_FILE" 2>/dev/null)" || _nr_l=""
			[[ "$_nr_l" == *": --"* ]] || continue
			_nr_cmds+="${_nr_cmds:+; }$(resume_cmd_record "--${_nr_l#*: --}")"
		done
		[[ -n "$_nr_cmds" ]] || _nr_cmds="$(resume_cmd_record "$(planned_axis_flags)")"
		RESUME_NOTES+=(--note "${#NOTRUN_CELLS[@]} planned cell(s) have no row (NOT_RUN: planned in planned-cells.txt, never reached: the run that planned them died or stopped first): ${_nr_list}. To finish this sweep, --resume it with the axis flags that planned them: ${_nr_cmds} (<sweep dir> is this sweep's directory)")
	fi
	# The rows of earlier attempts left out: every report and the envelope say so in their
	# own text (once each), so the outcome does not repeat it.
else
	FAILED_CELLS=() CELLS_TOTAL="$MATRIX_SIZE"
	# The next step: the rows are intact, and a --resume counts them again. The sweep
	# dir (a local path) goes to stderr only, below, never into the record.
	_cells_next="--resume this sweep dir with the flags it ran with to count them"
	[[ -z "$RESUME_DIR" ]] || _cells_next="run the same --resume again (with this sweep's flags) to count them"
	CELL_COUNT_ARGS=(--uncounted "${_cells_why:-awk exited ${_cells_rc} with no count}; the rows are intact: ${_cells_next}")
fi
# A --resume that added no rows (every cell of its axis flags was done) says so: the reports
# then leave it out of the rows' provenance (its harness and Kubernetes versions measured
# nothing; controlplane_attempts counts each run's rows).
if [[ "$(resume_added_rows)" == 0 ]]; then
	resume_own_notes_drop
	RESUME_NOTES+=(--info "this --resume (at ${RESUME_AT_Z}) added no rows: every cell of its axis flags was already done, so the reports leave it out of the rows' provenance (harness_shas, KUBE_VERSIONS)")
fi
# Counted: the EXIT trap need not count them again.
RESUME_OWN_NOTES=()
outcome_rc=0 stop_args=()
[[ -z "$SWEEP_STOPPED" ]] || stop_args=(--stopped 1 --stop-reason "RETIRE_FAILED: ${SWEEP_STOPPED}")
# The outcome also goes at the end of the scale envelope, when it was written: a
# campaign record pasted from it must show a version change or a failed sweep.
sweep_outcome ${stop_args[@]+"${stop_args[@]}"} ${CELL_COUNT_ARGS[@]+"${CELL_COUNT_ARGS[@]}"} ${IV_END[@]+"${IV_END[@]}"} ${RESUME_NOTES[@]+"${RESUME_NOTES[@]}"} \
	--run-id "$RUN_ID" --record "$OUTPUT_DIR" \
	--md "$MD_FILE" --md "$ENVELOPE_FILE" \
	--where "$_cells_where" \
	"$CELLS_TOTAL" ${FAILED_CELLS[@]+"${FAILED_CELLS[@]}"} || outcome_rc=$?
if ((${#CELL_COUNT_ARGS[@]})); then
	echo "The sweep dir to resume: ${OUTPUT_DIR} (--resume it with the flags this sweep ran with)." >&2
	((GROWTH)) || echo "  $(resume_cmd_console "$(planned_axis_flags)")" >&2
fi
# The full command for each plan whose cells never ran (the outcome's NOT_RUN note names
# their axis flags; the record holds no local path).
if ((${#NOTRUN_PLANS[@]})); then
	echo "To finish this sweep, --resume it with the axis flags that planned its NOT_RUN cells:" >&2
	for _nr_p in "${NOTRUN_PLANS[@]}"; do
		_nr_l="$(grep -m 1 "^# PLAN=${_nr_p} " "$PLANNED_FILE" 2>/dev/null)" || continue
		[[ "$_nr_l" == *": --"* ]] || continue
		echo "  $(resume_cmd_console "--${_nr_l#*: --}")" >&2
	done
fi
if [[ -n "$SWEEP_STOPPED" ]]; then
	echo "" >&2
	echo "ERROR: the sweep stopped early: ${SWEEP_STOPPED} (RETIRE_FAILED row in the report). The cells above it are valid; later series did not run." >&2
	exit 1
fi
exit "$outcome_rc"
