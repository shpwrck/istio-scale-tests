{{- $cfg := .argoConfig | fromJson -}}
{{- $tls := dict -}}
{{- if hasKey $cfg "tlsClientConfig" -}}
{{-   $tls = index $cfg "tlsClientConfig" -}}
{{- end -}}
{{- if hasKey $tls "caData" -}}
{{ index $tls "caData" | b64dec }}
{{- end -}}
