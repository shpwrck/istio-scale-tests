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

{{- define "propagation-test.canary.selectorLabels" -}}
app: propagation-canary
{{- end }}
