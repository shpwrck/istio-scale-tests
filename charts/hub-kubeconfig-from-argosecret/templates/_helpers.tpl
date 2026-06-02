{{/*
Create a default fully qualified app name.
*/}}
{{- define "hub-kubeconfig-from-argosecret.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "hub-kubeconfig-from-argosecret.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "hub-kubeconfig-from-argosecret.sourceSecretName" -}}
{{- if .Values.sourceSecretName }}
{{- .Values.sourceSecretName }}
{{- else if .Values.clusterName }}
{{- printf "%s-%s-cluster-secret" .Values.clusterName (.Values.managedServiceAccountName | default "argocd-gitops") }}
{{- else }}
{{- fail "clusterName or sourceSecretName is required" }}
{{- end }}
{{- end }}

{{- define "hub-kubeconfig-from-argosecret.targetSecretName" -}}
{{- if .Values.targetSecretName }}
{{- .Values.targetSecretName }}
{{- else if .Values.clusterName }}
{{- printf "kubeconfig-%s" .Values.clusterName }}
{{- else }}
{{- fail "clusterName or targetSecretName is required" }}
{{- end }}
{{- end }}

{{- define "hub-kubeconfig-from-argosecret.spokeSecretStoreName" -}}
{{- if .Values.spokeSecretStore.name }}
{{- .Values.spokeSecretStore.name | trunc 63 | trimSuffix "-" }}
{{- else if .Values.clusterName }}
{{- printf "%s-spoke-k8s" .Values.clusterName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- fail "clusterName or spokeSecretStore.name is required" }}
{{- end }}
{{- end }}

{{- define "hub-kubeconfig-from-argosecret.secretStoreName" -}}
{{- default (printf "%s-k8s" (include "hub-kubeconfig-from-argosecret.fullname" .) | trunc 63 | trimSuffix "-") .Values.secretStoreName }}
{{- end }}

{{- define "hub-kubeconfig-from-argosecret.storeServiceAccount" -}}
{{- default (printf "%s-eso-store" (include "hub-kubeconfig-from-argosecret.fullname" .) | trunc 63 | trimSuffix "-") .Values.serviceAccountName }}
{{- end }}
