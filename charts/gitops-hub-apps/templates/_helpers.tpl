{{/*
gitops-hub-apps — hub GitOps “app of apps” Helm chart.
Add optional Application or other manifests as YAML under templates/ (same namespace rules as plain manifests).
*/}}
{{- define "gitops-hub-apps.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}
