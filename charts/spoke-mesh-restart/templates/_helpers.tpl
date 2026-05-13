{{- define "spoke-mesh-restart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "spoke-mesh-restart.labels" -}}
app.kubernetes.io/name: {{ include "spoke-mesh-restart.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end }}
