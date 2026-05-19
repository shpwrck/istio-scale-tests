{{- define "dataplane-test.labels" -}}
app.kubernetes.io/name: dataplane-test
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "dataplane-test.server.labels" -}}
app: dataplane-server
{{ include "dataplane-test.labels" . }}
{{- end }}

{{- define "dataplane-test.server.selectorLabels" -}}
app: dataplane-server
{{- end }}

{{- define "dataplane-test.client.labels" -}}
app: dataplane-client
{{ include "dataplane-test.labels" . }}
{{- end }}

{{- define "dataplane-test.client.selectorLabels" -}}
app: dataplane-client
{{- end }}
