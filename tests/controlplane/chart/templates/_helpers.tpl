{{- define "controlplane-test.labels" -}}
app.kubernetes.io/name: controlplane-test
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "controlplane-test.selectorLabels" -}}
app.kubernetes.io/name: controlplane-test
{{- end }}

{{/*
  Effective namespace prefix. `namespacePrefix` takes precedence; otherwise
  fall back to the legacy `namespace` value. Defaults to "controlplane-test"
  if both are empty.
*/}}
{{- define "controlplane-test.namespacePrefix" -}}
{{- if .Values.namespacePrefix -}}
{{ .Values.namespacePrefix }}
{{- else if .Values.namespace -}}
{{ .Values.namespace }}
{{- else -}}
controlplane-test
{{- end -}}
{{- end -}}

{{/*
  Namespace name for a given zero-based index `i`.
  Backwards-compat: when namespaceCount == 1, the single namespace is named
  exactly `${namespacePrefix}` (no `-0` suffix), preserving the pre-sweep
  single-namespace layout. When namespaceCount > 1, the name is
  `${namespacePrefix}-${i}`.

  Usage: {{ include "controlplane-test.namespaceName" (dict "ctx" $ "i" $i) }}
*/}}
{{- define "controlplane-test.namespaceName" -}}
{{- $ctx := .ctx -}}
{{- $i := .i -}}
{{- $count := $ctx.Values.namespaceCount | int -}}
{{- $prefix := include "controlplane-test.namespacePrefix" $ctx -}}
{{- if le $count 1 -}}
{{ $prefix }}
{{- else -}}
{{ $prefix }}-{{ $i }}
{{- end -}}
{{- end -}}

{{/*
  Namespace name for a service index `idx`. Service `idx` lives in namespace
  `idx mod namespaceCount`.

  Usage: {{ include "controlplane-test.namespaceForService" (dict "ctx" $ "idx" $i) }}
*/}}
{{- define "controlplane-test.namespaceForService" -}}
{{- $ctx := .ctx -}}
{{- $idx := .idx | int -}}
{{- $count := max ($ctx.Values.namespaceCount | int) 1 -}}
{{- $nsIdx := mod $idx $count -}}
{{ include "controlplane-test.namespaceName" (dict "ctx" $ctx "i" $nsIdx) }}
{{- end -}}
