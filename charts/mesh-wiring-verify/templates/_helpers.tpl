{{- define "mesh-wiring-verify.labels" -}}
app: mesh-wiring-verify
app.kubernetes.io/name: mesh-wiring-verify
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: mesh-wiring-gate
{{- end }}

{{- define "mesh-wiring-verify.selectorLabels" -}}
app: mesh-wiring-verify
{{- end }}
