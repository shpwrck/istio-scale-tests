{{- define "spoke-istio-namespaces.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "spoke-istio-namespaces.labels" -}}
app.kubernetes.io/name: {{ include "spoke-istio-namespaces.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end }}
