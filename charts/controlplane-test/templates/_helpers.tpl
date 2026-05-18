{{- define "controlplane-test.labels" -}}
app.kubernetes.io/name: controlplane-test
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "controlplane-test.selectorLabels" -}}
app.kubernetes.io/name: controlplane-test
{{- end }}
