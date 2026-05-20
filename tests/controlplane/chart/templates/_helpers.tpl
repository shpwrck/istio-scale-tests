{{- define "controlplane-test.labels" -}}
app.kubernetes.io/name: controlplane-test
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "controlplane-test.selectorLabels" -}}
app.kubernetes.io/name: controlplane-test
{{- end }}

{{/*
Validate sidecarScoping is one of the supported values. Fails the render with a
clear message so operators get a single source-of-truth list.
*/}}
{{- define "controlplane-test.validateSidecarScoping" -}}
{{- $v := .Values.sidecarScoping | default "none" -}}
{{- if not (has $v (list "none" "namespace" "explicit")) -}}
{{- fail (printf "sidecarScoping must be one of [none, namespace, explicit]; got %q" $v) -}}
{{- end -}}
{{- end -}}

{{/*
Return the ordered list of workload namespaces this chart manages.
namespace          -> the primary namespace value
namespace-1, ...   -> additional namespaces when namespaceCount > 1
*/}}
{{- define "controlplane-test.namespaces" -}}
{{- $base := .Values.namespace -}}
{{- $n := int (default 1 .Values.namespaceCount) -}}
{{- if lt $n 1 -}}{{- $n = 1 -}}{{- end -}}
{{- $out := list $base -}}
{{- range $i, $_ := until (sub $n 1 | int) -}}
{{- $out = append $out (printf "%s-%d" $base (add $i 1)) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}
