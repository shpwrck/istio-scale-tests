{{- define "spoke-ingress-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "spoke-ingress-gateway.network" -}}
{{- printf "%s-%s" .Values.clusterName .Values.networkSuffix }}
{{- end }}

{{- define "spoke-ingress-gateway.labels" -}}
app: istio-ingressgateway
istio: ingressgateway
release: istio
topology.istio.io/network: {{ include "spoke-ingress-gateway.network" . | quote }}
{{- end }}

{{- define "spoke-ingress-gateway.selectorLabels" -}}
app: istio-ingressgateway
istio: ingressgateway
{{- end }}
