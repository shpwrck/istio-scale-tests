{{- define "mesh-wiring-verify.labels" -}}
app: mesh-wiring-verify
app.kubernetes.io/name: mesh-wiring-verify
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: mesh-wiring-gate
{{- end }}

{{- define "mesh-wiring-verify.selectorLabels" -}}
app: mesh-wiring-verify
{{- end }}

{{/*
The mesh members' names (expectedClusters: a list, or one comma-separated string), comma-joined
for EXPECTED_CLUSTERS, once they pass the render's checks: cluster names (DNS names: lowercase
letters, digits, '-' and '.'), each once, clusterName set, expectedMembers 0 or their number.
Empty without names: the gate then counts (expectedMembers).
*/}}
{{- define "mesh-wiring-verify.expectedClusters" -}}
{{- $raw := .Values.expectedClusters | default list -}}
{{- $names := list -}}
{{- if kindIs "string" $raw -}}
{{- range splitList "," $raw -}}
{{- if trim . }}{{ $names = append $names (trim .) }}{{ end -}}
{{- end -}}
{{- else -}}
{{- range $raw }}{{ $names = append $names (trim (toString .)) }}{{ end -}}
{{- end -}}
{{- $dns := "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" -}}
{{- if $names -}}
{{- range $names -}}
{{- if not (regexMatch $dns .) -}}
{{- fail (printf "expectedClusters: %q is not a cluster name (lowercase letters, digits, '-' and '.'): list each mesh member's Istio cluster ID" .) -}}
{{- end -}}
{{- end -}}
{{- $seen := dict -}}
{{- $dups := list -}}
{{- range $names -}}
{{- if hasKey $seen . }}{{ $dups = append $dups . }}{{ end -}}
{{- $_ := set $seen . true -}}
{{- end -}}
{{- if $dups -}}
{{- fail (printf "expectedClusters names %s more than once (%s)" (join "," (uniq $dups)) (join "," $names)) -}}
{{- end -}}
{{- $self := .Values.clusterName | default "" | toString -}}
{{- if not (regexMatch $dns $self) -}}
{{- fail (printf "clusterName %q is not a cluster name: with expectedClusters set it to this member's own name among them (the ApplicationSet sets it per member)" $self) -}}
{{- end -}}
{{- $n := int (.Values.expectedMembers | default 0) -}}
{{- if and (gt $n 0) (ne $n (len $names)) -}}
{{- fail (printf "expectedMembers is %d but expectedClusters names %d member(s) (%s): set both from the same members, or expectedMembers to 0" $n (len $names) (join "," $names)) -}}
{{- end -}}
{{- join "," $names -}}
{{- end -}}
{{- end }}
