{{- $cfg := .argoConfig | fromJson -}}
{{- $tls := dict -}}
{{- if hasKey $cfg "tlsClientConfig" -}}
{{-   $tls = index $cfg "tlsClientConfig" -}}
{{- end -}}
{{- if hasKey $tls "keyData" -}}
{{ index $tls "keyData" | b64dec }}
{{- end -}}
