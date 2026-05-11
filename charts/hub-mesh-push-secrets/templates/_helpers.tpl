{{- define "hub-mesh-push-secrets.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "hub-mesh-push-secrets.fullname" -}}
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

{{- define "hub-mesh-push-secrets.cacertsSourceSecretName" -}}
{{- if .Values.cacerts.sourceSecretName }}
{{- .Values.cacerts.sourceSecretName }}
{{- else if .Values.clusterName }}
{{- printf "mesh-intermediate-%s-material" .Values.clusterName }}
{{- else }}
{{- fail "clusterName or cacerts.sourceSecretName is required" }}
{{- end }}
{{- end }}

{{- define "hub-mesh-push-secrets.cacertsTargetSecretName" -}}
{{- if .Values.cacerts.targetSecretName }}
{{- .Values.cacerts.targetSecretName }}
{{- else if .Values.clusterName }}
{{- printf "cacerts-%s" .Values.clusterName }}
{{- else }}
{{- fail "clusterName or cacerts.targetSecretName is required" }}
{{- end }}
{{- end }}

{{- define "hub-mesh-push-secrets.kubeconfigSourceSecretName" -}}
{{- if .Values.kubeconfig.sourceSecretName }}
{{- .Values.kubeconfig.sourceSecretName }}
{{- else if .Values.clusterName }}
{{- printf "kubeconfig-%s" .Values.clusterName }}
{{- else }}
{{- fail "clusterName or kubeconfig.sourceSecretName is required" }}
{{- end }}
{{- end }}

{{- define "hub-mesh-push-secrets.secretStoreName" -}}
{{- default (printf "%s-k8s" (include "hub-mesh-push-secrets.fullname" .) | trunc 63 | trimSuffix "-") .Values.secretStoreName }}
{{- end }}

{{- define "hub-mesh-push-secrets.storeServiceAccount" -}}
{{- default (printf "%s-eso-store" (include "hub-mesh-push-secrets.fullname" .) | trunc 63 | trimSuffix "-") .Values.serviceAccountName }}
{{- end }}

{{- define "hub-mesh-push-secrets.spokeSecretStoreName" -}}
{{- if .Values.spokeSecretStore.name }}
{{- .Values.spokeSecretStore.name | trunc 63 | trimSuffix "-" }}
{{- else if .Values.clusterName }}
{{- printf "%s-spoke-istio-system" .Values.clusterName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- fail "clusterName or spokeSecretStore.name is required" }}
{{- end }}
{{- end }}
