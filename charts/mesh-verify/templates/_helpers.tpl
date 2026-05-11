{{- define "mesh-verify.labels" -}}
app: mesh-verify-echo
app.kubernetes.io/name: mesh-verify
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "mesh-verify.selectorLabels" -}}
app: mesh-verify-echo
{{- end }}
