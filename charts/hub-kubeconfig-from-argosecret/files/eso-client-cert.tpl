{{- $cfg := .argoConfig | fromJson -}}
{{- $tls := dict -}}
{{- if hasKey $cfg "tlsClientConfig" -}}
{{-   $tls = index $cfg "tlsClientConfig" -}}
{{- end -}}
{{- if hasKey $tls "certData" -}}
{{ index $tls "certData" | b64dec }}
{{- end -}}
