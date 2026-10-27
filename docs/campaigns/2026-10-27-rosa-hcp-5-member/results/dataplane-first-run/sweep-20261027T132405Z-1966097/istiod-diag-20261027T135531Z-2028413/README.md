# istiod restart diagnostics

Written by `tests/lib/istiod-diag.sh` when a suite detected an istiod restart
(`istiod_restarted` 1 or unknown, `POISONED_RESTART`, `RESTART`) or a changed istiod
pod set. The suite's rows are unchanged; this folder only adds evidence.

- `index.tsv`: one row per affected pod (schema in the `# ISTIOD_DIAG_SCHEMA=` line,
  columns in the header). Free text is sanitized: no IPs, node names or context names.
  The `context` column holds the context name, as the suite TSVs do.
- `NNN-<tag>-<context>/`: the raw evidence of one capture:
  - `summary.md`: sanitized summary, plus a PromQL query for the memory history
  - `pods.json`: istiod pod status (no IPs, env or managedFields)
  - `deploy-rs.json`: Deployment and ReplicaSet revisions and memory limits
  - `events.tsv`: the newest istio-system events of istiod objects
  - `<pod>.previous.log.gz`, `<pod>.log.gz`: the last ISTIOD_DIAG_LOG_BYTES of a log;
    `<pod>.startup.log.gz`: the first 256 KiB of a new pod's log
  - `<pod>.pre.metrics.gz`: the suite's last /metrics scrape before the window
  - `node-<n>.json`, `node-<n>-events.tsv`: node conditions, memory and events
  - `*.unavailable`: why that piece could not be fetched
- `.seen`, `.reported`: the keys of the restarts that have a folder or only a row, so
  a later call writes `already_captured` or `already_reported` instead of counting a
  restart twice.

Redaction: the raw evidence keeps host and node names (stack traces need them); IPs,
bearer tokens and JWTs are masked. Never commit this folder (its `.gitignore` ignores
everything in it, wherever the results dir is). Quote only `index.tsv` or `summary.md`,
after replacing context names with placeholders.
