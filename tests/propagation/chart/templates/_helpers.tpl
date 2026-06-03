{{- define "propagation-test.labels" -}}
app.kubernetes.io/name: propagation-test
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "propagation-test.watcher.labels" -}}
app: propagation-watcher
{{ include "propagation-test.labels" . }}
{{- end }}

{{- define "propagation-test.watcher.selectorLabels" -}}
app: propagation-watcher
{{- end }}

{{- define "propagation-test.canary.labels" -}}
app: propagation-canary
{{ include "propagation-test.labels" . }}
{{- end }}

{{/*
Deployment selector (and stable pod identity) for the pre-warmed backer. This is
ALWAYS on the pod — it does NOT gate Service membership. Service membership is
gated separately by the active-flip label (canary.activeSelectorLabels) so the
backer can be Ready-but-not-selected until t0.
*/}}
{{- define "propagation-test.canary.selectorLabels" -}}
app: propagation-canary
{{- end }}

{{/*
The active-flip label: a key/value the probe stamps onto the running backer pod
at t0 (config-only mutation, no reschedule) to add it to the Service selector. The
Service selects on BOTH the stable selectorLabels AND this label, so the endpoint
appears the instant the label is present and disappears when it is flipped off.
The key is exported separately so the probe can `kubectl label pod <key>=true`.
*/}}
{{- define "propagation-test.canary.activeLabelKey" -}}
propagation-active
{{- end }}

{{- define "propagation-test.canary.activeSelectorLabels" -}}
{{ include "propagation-test.canary.activeLabelKey" . }}: "true"
{{- end }}
