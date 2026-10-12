{{- define "spoke-ossm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "spoke-ossm.labels" -}}
app.kubernetes.io/name: {{ include "spoke-ossm.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end }}
