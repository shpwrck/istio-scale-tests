{{- define "spoke-east-west-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "spoke-east-west-gateway.network" -}}
{{- printf "%s-%s" .Values.clusterName .Values.networkSuffix }}
{{- end }}

{{- define "spoke-east-west-gateway.labels" -}}
app: istio-eastwestgateway
istio: eastwestgateway
istio.io/rev: default
release: istio
topology.istio.io/network: {{ include "spoke-east-west-gateway.network" . | quote }}
{{- end }}

{{- define "spoke-east-west-gateway.selectorLabels" -}}
app: istio-eastwestgateway
istio: eastwestgateway
topology.istio.io/network: {{ include "spoke-east-west-gateway.network" . | quote }}
{{- end }}
