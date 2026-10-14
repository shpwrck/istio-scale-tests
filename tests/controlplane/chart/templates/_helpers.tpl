{{- define "controlplane-test.labels" -}}
app.kubernetes.io/name: controlplane-test
app.kubernetes.io/instance: {{ .Release.Name }}
{{- with .Values.series }}
controlplane-test.series: {{ . | quote }}
{{- end }}
{{- end }}

{{/*
Validate sidecarScoping is one of the supported values.
*/}}
{{- define "controlplane-test.validateSidecarScoping" -}}
{{- $v := .Values.sidecarScoping | default "none" -}}
{{- if not (has $v (list "none" "namespace" "explicit" "wide")) -}}
{{- fail (printf "sidecarScoping must be one of [none, namespace, explicit, wide]; got %q" $v) -}}
{{- end -}}
{{- end -}}

{{/*
"true" in growth mode (servicesPerNamespace > 0, the block layout), else empty.
*/}}
{{- define "controlplane-test.growth" -}}
{{- if gt (int .Values.servicesPerNamespace) 0 -}}true{{- end -}}
{{- end -}}

{{/*
Validate the growth-mode values. The legacy layout (servicesPerNamespace 0) accepts
none of them, so a stray value cannot silently change a legacy render.
*/}}
{{- define "controlplane-test.validateGrowth" -}}
{{- $k := int .Values.servicesPerNamespace -}}
{{- $w := .Values.workload | default dict -}}
{{- $wmode := $w.mode | default "pods" -}}
{{- $o := .Values.outside | default dict -}}
{{- $omode := $o.mode | default "none" -}}
{{- $p := .Values.probe | default dict -}}
{{- if lt $k 0 -}}
{{- fail (printf "servicesPerNamespace must be >= 0; got %v" .Values.servicesPerNamespace) -}}
{{- end -}}
{{- if not (has $wmode (list "pods" "config-only")) -}}
{{- fail (printf "workload.mode must be one of [pods, config-only]; got %q" $wmode) -}}
{{- end -}}
{{- if not (has $omode (list "none" "unlabeled" "labeled")) -}}
{{- fail (printf "outside.mode must be one of [none, unlabeled, labeled]; got %q" $omode) -}}
{{- end -}}
{{- if lt (int $o.count) 0 -}}
{{- fail (printf "outside.count must be >= 0; got %v" $o.count) -}}
{{- end -}}
{{- if and .Values.series (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" .Values.series)) -}}
{{- fail (printf "series must be lowercase letters, digits and '-'; got %q" .Values.series) -}}
{{- end -}}
{{- if eq $k 0 -}}
{{- if or (ne $wmode "pods") (gt (int $o.count) 0) $p.name (gt (int .Values.namespaceStart) 0) -}}
{{- fail "workload.mode config-only, outside.count, probe.name and namespaceStart need the block layout (servicesPerNamespace > 0)" -}}
{{- end -}}
{{- else -}}
{{- if eq (.Values.sidecarScoping | default "none") "explicit" -}}
{{- fail "sidecarScoping explicit is not supported with servicesPerNamespace > 0 (use none, namespace or wide)" -}}
{{- end -}}
{{- if eq ((.Values.trafficConfig | default dict).mode | default "none") "vsdr" -}}
{{- fail "trafficConfig.mode vsdr is not supported with servicesPerNamespace > 0" -}}
{{- end -}}
{{- if lt (int .Values.namespaceCount) 1 -}}
{{- fail (printf "namespaceCount must be >= 1; got %v" .Values.namespaceCount) -}}
{{- end -}}
{{- if or (lt (int .Values.namespaceStart) 0) (ge (int .Values.namespaceStart) (int .Values.namespaceCount)) -}}
{{- fail (printf "namespaceStart (%v) must be >= 0 and < namespaceCount (%v)" .Values.namespaceStart .Values.namespaceCount) -}}
{{- end -}}
{{- if and (eq $wmode "config-only") (lt (int $w.measurementPods) 1) -}}
{{- fail (printf "workload.measurementPods must be >= 1 with workload.mode config-only; got %v" $w.measurementPods) -}}
{{- end -}}
{{- if and $p.name (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $p.name)) -}}
{{- fail (printf "probe.name must be a DNS label; got %q" $p.name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Name prefix of the growth-mode namespaces: <namespace>-<series>, or <namespace>
without a series.
*/}}
{{- define "controlplane-test.nsBase" -}}
{{- $base := .Values.namespace | default "controlplane-test" -}}
{{- if .Values.series -}}
{{ $base }}-{{ .Values.series }}
{{- else -}}
{{ $base }}
{{- end -}}
{{- end -}}

{{/*
Namespace name for a zero-based index `i`. Legacy layout: `<namespace>` when
namespaceCount <= 1, otherwise `<namespace>-<i>`. Growth mode: always
`<nsBase>-<i>`.

Usage: {{ include "controlplane-test.namespaceName" (dict "ctx" $ "i" $i) }}
*/}}
{{- define "controlplane-test.namespaceName" -}}
{{- $ctx := .ctx -}}
{{- $base := $ctx.Values.namespace | default "controlplane-test" -}}
{{- if include "controlplane-test.growth" $ctx -}}
{{ include "controlplane-test.nsBase" $ctx }}-{{ .i }}
{{- else if le ($ctx.Values.namespaceCount | int) 1 -}}
{{ $base }}
{{- else -}}
{{ $base }}-{{ .i }}
{{- end -}}
{{- end -}}

{{/*
Ordered list (YAML) of every workload namespace this render manages: all of them in
the legacy layout, namespaceStart..namespaceCount-1 in growth mode.
*/}}
{{- define "controlplane-test.namespaces" -}}
{{- $n := max (.Values.namespaceCount | int) 1 | int -}}
{{- $start := 0 -}}
{{- if include "controlplane-test.growth" . -}}
{{- $start = int .Values.namespaceStart -}}
{{- end -}}
{{- $out := list -}}
{{- range $i := untilStep $start $n 1 -}}
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
