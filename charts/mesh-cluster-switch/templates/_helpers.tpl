{{- define "mesh-cluster-switch.labels" -}}
app.kubernetes.io/name: mesh-cluster-switch
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
