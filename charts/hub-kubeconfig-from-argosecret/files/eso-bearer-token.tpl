{{- $cfg := .argoConfig | fromJson -}}
{{ $cfg.bearerToken }}
