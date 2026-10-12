{{/*
"true" unless apps.<name>.enabled is explicitly false. Call with (dict "root" $ "name" "<app>").
*/}}
{{- define "gitops-hub-apps.enabled" -}}
{{- $app := index (.root.Values.apps | default dict) .name | default dict -}}
{{- if not (and (hasKey $app "enabled") (eq (toString $app.enabled) "false")) -}}
true
{{- end -}}
{{- end }}

{{- define "gitops-hub-apps.repoURL" -}}
{{- required "repo.url is required (the Git URL Argo CD syncs this repo from)" .Values.repo.url | quote -}}
{{- end }}

{{- define "gitops-hub-apps.revision" -}}
{{- required "repo.revision is required" .Values.repo.revision | quote -}}
{{- end }}

{{/*
helm.valuesObject from apps.<name>.values (omitted when unset). For the
ApplicationSet apps these values go to charts/gitops-hub-ocm-placement-appset;
put member-chart overrides under template.source.helm.valuesObject.
*/}}
{{- define "gitops-hub-apps.valuesObject" -}}
{{- $app := index (.root.Values.apps | default dict) .name | default dict -}}
{{- with $app.values -}}
valuesObject:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
