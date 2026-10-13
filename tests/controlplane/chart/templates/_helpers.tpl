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

{{/*
Validate trafficConfig: mode is none|vsdr, every >= 1, and with vsdr
1 <= subsets <= replicasPerService (each subset must select at least one pod).
Values are read without `default`, which would turn an explicit 0 into the default.
*/}}
{{- define "controlplane-test.validateTrafficConfig" -}}
{{- $tc := .Values.trafficConfig | default dict -}}
{{- $mode := $tc.mode | default "none" -}}
{{- if not (has $mode (list "none" "vsdr")) -}}
{{- fail (printf "trafficConfig.mode must be one of [none, vsdr]; got %q" $mode) -}}
{{- end -}}
{{- if lt (int $tc.every) 1 -}}
{{- fail (printf "trafficConfig.every must be >= 1; got %v" $tc.every) -}}
{{- end -}}
{{- if eq $mode "vsdr" -}}
{{- $s := int $tc.subsets -}}
{{- if lt $s 1 -}}
{{- fail (printf "trafficConfig.subsets must be >= 1; got %v" $tc.subsets) -}}
{{- end -}}
{{- if gt $s (int .Values.replicasPerService) -}}
{{- fail (printf "trafficConfig.subsets (%d) must be <= replicasPerService (%d) so every subset selects at least one pod" $s (int .Values.replicasPerService)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
"true" when service `idx` gets a VirtualService + DestinationRule (mode vsdr and
idx mod every == 0), else empty.

Usage: {{ include "controlplane-test.vsdrFor" (dict "ctx" $ "idx" $i) }}
*/}}
{{- define "controlplane-test.vsdrFor" -}}
{{- $tc := .ctx.Values.trafficConfig | default dict -}}
{{- if and (eq ($tc.mode | default "none") "vsdr") (eq (mod (.idx | int) (int $tc.every)) 0) -}}true{{- end -}}
{{- end -}}
