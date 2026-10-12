{{- define "spoke-ossm-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "spoke-ossm-operator.labels" -}}
app.kubernetes.io/name: {{ include "spoke-ossm-operator.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end }}
