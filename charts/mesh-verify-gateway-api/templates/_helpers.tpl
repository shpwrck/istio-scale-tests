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
{{- if eq (toString .Values.remoteNamespace) (toString .Values.namespace) -}}
{{- fail (printf "remoteNamespace %q must differ from namespace: S7-S9 need a backend namespace that exists on the workload member only" (toString .Values.remoteNamespace)) -}}
{{- end -}}
{{- if or (eq (toString .Values.sharedNamespace) (toString .Values.namespace)) (eq (toString .Values.sharedNamespace) (toString .Values.remoteNamespace)) -}}
{{- fail (printf "sharedNamespace %q must differ from namespace and remoteNamespace: S7b needs a backend namespace of its own on every member" (toString .Values.sharedNamespace)) -}}
{{- end -}}
{{- if .Values.clusterName -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" (toString .Values.workloadCluster)) -}}
{{- fail (printf "workloadCluster %q is not a member's cluster name (its Argo CD cluster name; on OpenShift its ACM ManagedCluster name): set template.source.helm.valuesObject.workloadCluster in charts/mesh-verify-gateway-api-appset.yaml to the member that runs the echo workload" (toString .Values.workloadCluster)) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Id of the scenario set below, stamped on the namespaces and the Gateway API Gateway
(mesh-verify-gwapi/scenario-set) so a run can tell which chart content it measured. It must
equal SCENARIO_SET in tests/gateway-api/001-run-ingress-check.sh (gateway-api.bats checks it);
bump both together whenever a scenario, host, route, backend or namespace changes, with Chart.yaml's
version (it mirrors the set) and the render pin in gateway-api.bats, which fails CI on any render
change without a bump. Not a value: an override would defeat it.
*/}}
{{- define "mesh-verify-gateway-api.scenarioSet" -}}
v3
{{- end }}

{{/*
The scenario set (tests/gateway-api/README.md). tests/gateway-api/001-run-ingress-check.sh holds
the same ids, hosts, route names and backends in its SCENARIOS table, with the predicted
outcomes; change both together (tests/lib/test/gateway-api.bats checks that they agree).
workloadOnly: rendered only on the workload member. backendNs: where the backend lives: main
(namespace, every member), remote (remoteNamespace, the workload member only: S7-S9) or shared
(sharedNamespace, every member, its Service on the workload member only: S7b); every route stays in
namespace. Every Service comes from the one template in services.yaml, so the S3 stub on the other
members is byte-identical to the workload's Service. A kind Service route into another namespace
gets a ReferenceGrant (referencegrants.yaml) in the backend namespace, wherever that exists.
*/}}
{{- define "mesh-verify-gateway-api.scenarios" -}}
services:
  - name: echo-s1
    workloadOnly: true
    backendNs: main
  - name: echo-s2
    workloadOnly: true
    backendNs: main
  - name: echo-s3
    workloadOnly: false
    backendNs: main
  - name: echo-s4
    workloadOnly: true
    backendNs: main
  - name: echo-s5
    workloadOnly: true
    backendNs: main
  - name: echo-s7
    workloadOnly: true
    backendNs: remote
  - name: echo-s7b
    workloadOnly: true
    backendNs: shared
  - name: echo-s8
    workloadOnly: true
    backendNs: remote
  - name: echo-s9
    workloadOnly: true
    backendNs: remote
virtualServices:
  - id: S1
    name: s1
    host: s1.classic.test
    backend: echo-s1
    backendNs: main
  - id: S9
    name: s9
    host: s9.classic.test
    backend: echo-s9
    backendNs: remote
httpRoutes:
  - id: S2
    name: s2
    host: s2.gwapi.test
    kind: Service
    backend: echo-s2
    backendNs: main
    workloadOnly: false
  - id: S3
    name: s3
    host: s3.gwapi.test
    kind: Service
    backend: echo-s3
    backendNs: main
    workloadOnly: false
  - id: S4
    name: s4
    host: s4.gwapi.test
    kind: Hostname
    backend: echo-s4
    backendNs: main
    workloadOnly: false
  - id: S5
    name: s5
    host: s5.gwapi.test
    kind: ServiceImport
    backend: echo-s5
    backendNs: main
    workloadOnly: false
  - id: S7
    name: s7
    host: s7.gwapi.test
    kind: Service
    backend: echo-s7
    backendNs: remote
    workloadOnly: false
  - id: S7b
    name: s7b
    host: s7b.gwapi.test
    kind: Service
    backend: echo-s7b
    backendNs: shared
    workloadOnly: false
  - id: S8
    name: s8
    host: s8.gwapi.test
    kind: Hostname
    backend: echo-s8
    backendNs: remote
    workloadOnly: false
  - id: C1
    name: c1
    host: neg.gwapi.test
    kind: Service
    backend: echo-none
    backendNs: main
    workloadOnly: false
  - id: C2
    name: c2
    host: s6.gwapi.test
    kind: Service
    backend: echo-s2
    backendNs: main
    workloadOnly: true
{{- end }}

{{/*
The backend namespace of a scenario entry (backendNs main, remote or shared).
Call with (dict "s" <entry> "Values" .Values).
*/}}
{{- define "mesh-verify-gateway-api.backendNamespace" -}}
{{- if eq .s.backendNs "remote" -}}{{ .Values.remoteNamespace }}
{{- else if eq .s.backendNs "shared" -}}{{ .Values.sharedNamespace }}
{{- else if eq .s.backendNs "main" -}}{{ .Values.namespace }}
{{- else -}}{{ fail (printf "backendNs %q is not main, remote or shared" (toString .s.backendNs)) }}
{{- end -}}
{{- end }}

{{/*
"true" when a backendNs namespace exists on this member: main and shared everywhere, remote on
the workload member only. Call with (dict "s" <entry> "ctx" $).
*/}}
{{- define "mesh-verify-gateway-api.backendNsHere" -}}
{{- if or (ne .s.backendNs "remote") (include "mesh-verify-gateway-api.isWorkload" .ctx) -}}
true
{{- end -}}
{{- end }}

{{/*
The namespaces this member gets: namespace and sharedNamespace everywhere, remoteNamespace on the
workload member. A YAML list, for fromYamlArray.
*/}}
{{- define "mesh-verify-gateway-api.namespaces" -}}
- {{ .Values.namespace }}
- {{ .Values.sharedNamespace }}
{{- if include "mesh-verify-gateway-api.isWorkload" . }}
- {{ .Values.remoteNamespace }}
{{- end }}
{{- end }}
