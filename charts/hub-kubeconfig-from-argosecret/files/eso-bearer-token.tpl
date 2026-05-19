{{- $cfg := .argoConfig | fromJson -}}
{{- if hasKey $cfg "bearerToken" -}}
{{- $cfg.bearerToken -}}
{{- end -}}
