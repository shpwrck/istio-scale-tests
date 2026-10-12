{{- define "controlplane-test.labels" -}}
app.kubernetes.io/name: controlplane-test
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Validate sidecarScoping is one of the supported values.
*/}}
{{- define "controlplane-test.validateSidecarScoping" -}}
{{- $v := .Values.sidecarScoping | default "none" -}}
{{- if not (has $v (list "none" "namespace" "explicit")) -}}
{{- fail (printf "sidecarScoping must be one of [none, namespace, explicit]; got %q" $v) -}}
{{- end -}}
{{- end -}}

{{/*
Namespace name for a zero-based index `i`: `<namespace>` when
namespaceCount <= 1, otherwise `<namespace>-<i>`.

Usage: {{ include "controlplane-test.namespaceName" (dict "ctx" $ "i" $i) }}
*/}}
{{- define "controlplane-test.namespaceName" -}}
{{- $ctx := .ctx -}}
{{- $base := $ctx.Values.namespace | default "controlplane-test" -}}
{{- if le ($ctx.Values.namespaceCount | int) 1 -}}
{{ $base }}
{{- else -}}
{{ $base }}-{{ .i }}
{{- end -}}
{{- end -}}

{{/*
Ordered list (YAML) of every workload namespace this chart manages.
*/}}
{{- define "controlplane-test.namespaces" -}}
{{- $n := max (.Values.namespaceCount | int) 1 | int -}}
{{- $out := list -}}
{{- range $i := until $n -}}
{{- $out = append $out (include "controlplane-test.namespaceName" (dict "ctx" $ "i" $i)) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Namespace for service index `idx` (service idx lives in namespace idx mod namespaceCount).

Usage: {{ include "controlplane-test.namespaceForService" (dict "ctx" $ "idx" $i) }}
*/}}
{{- define "controlplane-test.namespaceForService" -}}
{{- $ctx := .ctx -}}
{{- $count := max ($ctx.Values.namespaceCount | int) 1 -}}
{{- include "controlplane-test.namespaceName" (dict "ctx" $ctx "i" (mod (.idx | int) $count)) -}}
{{- end -}}
