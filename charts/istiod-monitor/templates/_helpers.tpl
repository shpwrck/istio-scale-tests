{{- define "istiod-monitor.labels" -}}
app.kubernetes.io/name: istiod-monitor
app.kubernetes.io/instance: {{ .Release.Name }}
{{- with .Values.extraLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}
