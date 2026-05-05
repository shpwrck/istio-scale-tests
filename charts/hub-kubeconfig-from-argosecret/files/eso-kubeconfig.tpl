{{- $cfg := .argoConfig | fromJson }}
{{- $cn := .argoName | trim }}
apiVersion: v1
kind: Config
clusters:
- cluster:
{{- if and $cfg.tlsClientConfig $cfg.tlsClientConfig.caData }}
    certificate-authority-data: {{ $cfg.tlsClientConfig.caData }}
{{- end }}
{{- if and $cfg.tlsClientConfig $cfg.tlsClientConfig.insecure }}
    insecure-skip-tls-verify: true
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
