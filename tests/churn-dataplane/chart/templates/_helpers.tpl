{{- define "churn-dataplane.labels" -}}
app.kubernetes.io/name: churn-dataplane-test
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "churn-dataplane.churn-target.selectorLabels" -}}
app: churn-target
{{- end }}

{{- define "churn-dataplane.fortio-server.selectorLabels" -}}
app: fortio-server
{{- end }}

{{- define "churn-dataplane.fortio-client.selectorLabels" -}}
app: fortio-client
{{- end }}
