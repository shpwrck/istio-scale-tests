{{/*
Labels for ApplicationSet and RBAC (distinct per preset via identity.component / applicationSet.name).
*/}}
{{- define "gitops-hub-ocm-placement-appset.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name | quote }}
app.kubernetes.io/instance: {{ .Values.applicationSet.name | default .Release.Name | quote }}
app.kubernetes.io/component: {{ .Values.identity.component | default "ocm-placement-appset" | quote }}
{{- end }}
