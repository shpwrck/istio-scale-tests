{{- define "churn-test.labels" -}}
app.kubernetes.io/name: churn-test
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "churn-test.watcher.labels" -}}
app: churn-watcher
{{ include "churn-test.labels" . }}
{{- end }}

{{- define "churn-test.watcher.selectorLabels" -}}
app: churn-watcher
{{- end }}
