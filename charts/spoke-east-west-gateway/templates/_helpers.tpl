{{- define "spoke-east-west-gateway.network" -}}
{{- printf "%s-%s" (required "clusterName is required (set per cluster by the ApplicationSet)" .Values.clusterName) .Values.networkSuffix }}
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
