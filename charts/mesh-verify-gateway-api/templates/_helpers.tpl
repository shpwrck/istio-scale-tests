{{- define "mesh-verify-gateway-api.labels" -}}
app.kubernetes.io/name: mesh-verify-gateway-api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "mesh-verify-gateway-api.selectorLabels" -}}
app: gwapi-echo
{{- end }}

{{/*
"true" on the workload member (clusterName equals a non-empty workloadCluster), else empty.
*/}}
{{- define "mesh-verify-gateway-api.isWorkload" -}}
{{- if and .Values.workloadCluster (eq (toString .Values.clusterName) (toString .Values.workloadCluster)) -}}
true
{{- end -}}
{{- end }}

{{/*
Fail an ApplicationSet render (clusterName set) whose workloadCluster is empty or not a DNS
label, so a check with no workload member is never deployed. helm lint (no clusterName) passes.
*/}}
{{- define "mesh-verify-gateway-api.validate" -}}
{{- if .Values.clusterName -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" (toString .Values.workloadCluster)) -}}
{{- fail (printf "workloadCluster %q is not an ACM ManagedCluster name: set template.source.helm.valuesObject.workloadCluster in charts/mesh-verify-gateway-api-appset.yaml to the member that runs the echo workload" (toString .Values.workloadCluster)) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
The scenario set (tests/gateway-api/README.md). tests/gateway-api/001-run-ingress-check.sh holds
the same ids, hosts, route names and backends in its SCENARIOS table, with the predicted
outcomes; change both together (tests/lib/test/gateway-api.bats checks that they agree).
workloadOnly: rendered only on the workload member. Every Service comes from the one template in
services.yaml, so the S3 stub on the other members is byte-identical to the workload's Service.
*/}}
{{- define "mesh-verify-gateway-api.scenarios" -}}
services:
  - name: echo-s1
    workloadOnly: true
  - name: echo-s2
    workloadOnly: true
  - name: echo-s3
    workloadOnly: false
  - name: echo-s4
    workloadOnly: true
  - name: echo-s5
    workloadOnly: true
httpRoutes:
  - id: S2
    name: s2
    host: s2.gwapi.test
    kind: Service
    backend: echo-s2
    workloadOnly: false
  - id: S3
    name: s3
    host: s3.gwapi.test
    kind: Service
    backend: echo-s3
    workloadOnly: false
  - id: S4
    name: s4
    host: s4.gwapi.test
    kind: Hostname
    backend: echo-s4
    workloadOnly: false
  - id: S5
    name: s5
    host: s5.gwapi.test
    kind: ServiceImport
    backend: echo-s5
    workloadOnly: false
  - id: C1
    name: c1
    host: neg.gwapi.test
    kind: Service
    backend: echo-none
    workloadOnly: false
  - id: C2
    name: c2
    host: s6.gwapi.test
    kind: Service
    backend: echo-s2
    workloadOnly: true
{{- end }}
