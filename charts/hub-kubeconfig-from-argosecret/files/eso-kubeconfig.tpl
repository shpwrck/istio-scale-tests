{{- $cfg := .argoConfig | fromJson -}}
{{- $cn := .argoName | trim -}}
{{- $tls := dict -}}
{{- if hasKey $cfg "tlsClientConfig" -}}
{{-   $tls = index $cfg "tlsClientConfig" -}}
{{- end -}}
apiVersion: v1
kind: Config
clusters:
- cluster:
{{- if hasKey $tls "caData" }}
    certificate-authority-data: {{ index $tls "caData" }}
{{- end }}
{{- if hasKey $tls "insecure" }}
{{-   if index $tls "insecure" }}
    insecure-skip-tls-verify: true
{{-   else }}
    insecure-skip-tls-verify: false
{{-   end }}
{{- else }}
    insecure-skip-tls-verify: false
{{- end }}
    server: {{ trim .argoServer }}
  name: {{ $cn }}
contexts:
- context:
    cluster: {{ $cn }}
    user: {{ $cn }}
  name: {{ $cn }}
current-context: {{ $cn }}
users:
- name: {{ $cn }}
  user:
    token: {{ $cfg.bearerToken }}
