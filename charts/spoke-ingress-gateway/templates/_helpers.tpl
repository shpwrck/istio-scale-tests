{{- define "spoke-ingress-gateway.network" -}}
{{- printf "%s-%s" (required "clusterName is required (set per cluster by the ApplicationSet)" .Values.clusterName) .Values.networkSuffix }}
{{- end }}

{{- define "spoke-ingress-gateway.labels" -}}
app: istio-ingressgateway
istio: ingressgateway
release: istio
{{- end }}

{{- define "spoke-ingress-gateway.podLabels" -}}
{{ include "spoke-ingress-gateway.labels" . }}
topology.istio.io/network: {{ include "spoke-ingress-gateway.network" . | quote }}
{{- end }}

{{- define "spoke-ingress-gateway.selectorLabels" -}}
app: istio-ingressgateway
istio: ingressgateway
{{- end }}
