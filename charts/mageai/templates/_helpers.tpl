{{/*
Expand the name of the chart.
*/}}
{{- define "mageai.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "mageai.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mageai.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mageai.labels" -}}
helm.sh/chart: {{ include "mageai.chart" . }}
{{ include "mageai.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mageai.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mageai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}


{{/*
Scheduler Selector labels
*/}}
{{- define "mageai.schedulerSelectorLabels" -}}
app.kubernetes.io/name: {{ .Values.scheduler.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}


{{/*
Create the name of the service account to use
*/}}
{{- define "mageai.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mageai.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Generate chart secret name
*/}}
{{- define "mageai.secretName" -}}
{{ default (printf "%s-secret-env" (include "mageai.fullname" .)) .Values.existingSecret }}
{{- end -}}

{{/*
Resolve the OpenSearch host.
When opensearch.enabled=true and logSearch.opensearch.host is not explicitly set,
derive the in-cluster service name from the bundled sub-chart.
Otherwise use logSearch.opensearch.host as-is.
*/}}
{{- define "mageai.opensearchHost" -}}
{{- if and .Values.opensearch .Values.opensearch.enabled (eq "" .Values.logSearch.opensearch.host) -}}
{{- default "opensearch-cluster-master" .Values.opensearch.masterService -}}
{{- else if .Values.logSearch.opensearch.host -}}
{{- .Values.logSearch.opensearch.host -}}
{{- else -}}
{{- fail "logSearch.opensearch.host is required when logSearch.enabled=true and opensearch.enabled=false" -}}
{{- end -}}
{{- end -}}

{{/*
Generated resource names for log search.
*/}}
{{- define "mageai.logSearch.claimName" -}}
{{- printf "%s-log-search" (include "mageai.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mageai.logSearch.fluentBitConfigMapName" -}}
{{- printf "%s-fluent-bit" (include "mageai.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mageai.logSearch.fluentBitConfigMap" -}}
{{- default (include "mageai.logSearch.fluentBitConfigMapName" .) .Values.logSearch.fluentBit.existingConfigMap -}}
{{- end -}}

{{- define "mageai.logSearch.fluentBitParsersConfigMap" -}}
{{- default (include "mageai.logSearch.fluentBitConfigMapName" .) .Values.logSearch.fluentBit.existingParsersConfigMap -}}
{{- end -}}

{{- define "mageai.logSearch.indexSetupConfigMapName" -}}
{{- printf "%s-log-search-index" (include "mageai.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mageai.logSearch.persistenceClaimName" -}}
{{- default (include "mageai.logSearch.claimName" .) .Values.logSearch.persistence.existingClaim -}}
{{- end -}}

{{- define "mageai.logSearch.validatePersistence" -}}
{{- if and .Values.logSearch .Values.logSearch.enabled .Values.logSearch.persistence.enabled (not .Values.logSearch.persistence.existingClaim) (not (has "ReadWriteMany" .Values.logSearch.persistence.accessModes)) -}}
{{- if or .Values.standaloneScheduler (gt (int .Values.replicaCount) 1) -}}
{{- fail "logSearch.persistence.enabled with a generated PVC requires logSearch.persistence.accessModes to include ReadWriteMany when standaloneScheduler=true or replicaCount > 1; use an existing RWX claim or set logSearch.persistence.accessModes={ReadWriteMany}" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mageai.logSearch.fluentBitChecksum" -}}
{{- printf "%s\n%s\n%s\n%s" (tpl .Values.logSearch.fluentBit.config .) (tpl .Values.logSearch.fluentBit.parsers .) .Values.logSearch.fluentBit.existingConfigMap .Values.logSearch.fluentBit.existingParsersConfigMap | sha256sum -}}
{{- end -}}

{{/*
Return "true" when extraVolumeMounts already contains the log-search project
mount path. This prevents duplicate mountPath entries when users already mount
their project volume, while still preserving the rest of extraVolumeMounts.
*/}}
{{- define "mageai.logSearch.extraVolumeMountsContainMountPath" -}}
{{- $mountPath := default "/home/src" .Values.logSearch.persistence.mountPath -}}
{{- $found := false -}}
{{- range .Values.extraVolumeMounts }}
{{- if eq .mountPath $mountPath }}
{{- $found = true -}}
{{- end -}}
{{- end -}}
{{- if $found }}true{{ end -}}
{{- end -}}

{{- define "mageai.logSearch.persistenceEnabled" -}}
{{- if and .Values.logSearch .Values.logSearch.enabled (or .Values.logSearch.persistence.existingClaim .Values.logSearch.persistence.enabled) }}true{{ end -}}
{{- end -}}

{{- define "mageai.logSearch.shouldMountPersistenceInMage" -}}
{{- if and (include "mageai.logSearch.persistenceEnabled" .) .Values.logSearch.persistence.mountInMageContainer }}true{{ end -}}
{{- end -}}

{{- define "mageai.logSearch.fluentBitEnabled" -}}
{{- if and .Values.logSearch .Values.logSearch.enabled .Values.logSearch.fluentBit.enabled (or (include "mageai.logSearch.persistenceEnabled" .) .Values.volumes (include "mageai.logSearch.extraVolumeMountsContainMountPath" .)) }}true{{ end -}}
{{- end -}}

{{- define "mageai.logSearch.workspaceEnabled" -}}
{{- if and .Values.logSearch .Values.logSearch.enabled .Values.logSearch.workspace .Values.logSearch.workspace.enabled }}true{{ end -}}
{{- end -}}

{{- define "mageai.logSearch.workspaceEnv" -}}
{{- if include "mageai.logSearch.workspaceEnabled" . }}
- name: WORKSPACE_USE_OPENSEARCH_FOR_LOGS
  value: "true"
- name: LOG_SEARCH_FLUENT_BIT_CONFIG_MAP
  value: {{ include "mageai.logSearch.fluentBitConfigMap" . | quote }}
- name: LOG_SEARCH_FLUENT_BIT_PARSERS_CONFIG_MAP
  value: {{ include "mageai.logSearch.fluentBitParsersConfigMap" . | quote }}
{{- with .Values.logSearch.fluentBit.resources.requests.cpu }}
- name: LOG_SEARCH_FLUENT_BIT_RESOURCE_REQUESTS_CPU
  value: {{ . | quote }}
{{- end }}
{{- with .Values.logSearch.fluentBit.resources.requests.memory }}
- name: LOG_SEARCH_FLUENT_BIT_RESOURCE_REQUESTS_MEMORY
  value: {{ . | quote }}
{{- end }}
{{- with .Values.logSearch.fluentBit.resources.limits.cpu }}
- name: LOG_SEARCH_FLUENT_BIT_RESOURCE_LIMITS_CPU
  value: {{ . | quote }}
{{- end }}
{{- with .Values.logSearch.fluentBit.resources.limits.memory }}
- name: LOG_SEARCH_FLUENT_BIT_RESOURCE_LIMITS_MEMORY
  value: {{ . | quote }}
{{- end }}
{{- if and .Values.logSearch.opensearch.auth .Values.logSearch.opensearch.auth.enabled .Values.logSearch.opensearch.auth.existingSecret }}
- name: LOG_SEARCH_OPENSEARCH_AUTH_SECRET
  value: {{ .Values.logSearch.opensearch.auth.existingSecret | quote }}
{{- end }}
{{- if and .Values.logSearch.opensearch.tls .Values.logSearch.opensearch.tls.enabled .Values.logSearch.opensearch.tls.existingSecret }}
- name: LOG_SEARCH_OPENSEARCH_TLS_SECRET
  value: {{ .Values.logSearch.opensearch.tls.existingSecret | quote }}
{{- end }}
{{- if and .Values.logSearch.opensearch.tls .Values.logSearch.opensearch.tls.enabled }}
- name: OPENSEARCH_VERIFY_CERTS
  value: {{ if .Values.logSearch.opensearch.tls.verify }}"true"{{ else }}"false"{{ end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Render the project volume mount for the Mage container. When log search owns a
PVC, that PVC takes precedence over the default /home/src mount so generated
or existing log-search claims are not created and then left unused.
*/}}
{{- define "mageai.projectVolumeMounts" -}}
{{- $logSearchMountPath := default "/home/src" .Values.logSearch.persistence.mountPath -}}
{{- $logSearchOwnsMount := include "mageai.logSearch.shouldMountPersistenceInMage" . -}}
{{- if .Values.volumes }}
{{- if not $logSearchOwnsMount }}
- name: mage-fs
  mountPath: /home/src
{{- end }}
{{- else if .Values.extraVolumeMounts }}
{{- range .Values.extraVolumeMounts }}
{{- if not (and $logSearchOwnsMount (eq .mountPath $logSearchMountPath)) }}
{{ toYaml (list .) }}
{{- end }}
{{- end }}
{{- end }}
{{- if $logSearchOwnsMount }}
- name: log-search-pvc
  mountPath: {{ $logSearchMountPath }}
  {{- if .Values.logSearch.persistence.subPath }}
  subPath: {{ .Values.logSearch.persistence.subPath }}
  {{- end }}
{{- end }}
{{- end -}}

{{- define "mageai.projectVolumes" -}}
{{- $logSearchMountPath := default "/home/src" .Values.logSearch.persistence.mountPath -}}
{{- $logSearchOwnsMount := include "mageai.logSearch.shouldMountPersistenceInMage" . -}}
{{- $skipVolumeName := "" -}}
{{- if $logSearchOwnsMount }}
{{- range .Values.extraVolumeMounts }}
{{- if eq .mountPath $logSearchMountPath }}
{{- $skipVolumeName = .name -}}
{{- end }}
{{- end }}
{{- end }}
{{- if .Values.volumes }}
{{- toYaml .Values.volumes }}
{{- else if .Values.extraVolumes }}
{{- range .Values.extraVolumes }}
{{- if not (and $logSearchOwnsMount (eq .name $skipVolumeName)) }}
{{ toYaml (list .) }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "mageai.logSearch.fluentBitContainer" -}}
{{- if include "mageai.logSearch.fluentBitEnabled" . }}
- name: fluent-bit
  image: "{{ .Values.logSearch.fluentBit.image.repository }}:{{ .Values.logSearch.fluentBit.image.tag }}"
  imagePullPolicy: {{ .Values.logSearch.fluentBit.image.pullPolicy }}
  securityContext:
    runAsUser: 0
  command:
    - /fluent-bit/bin/fluent-bit
    - -c
    - /fluent-bit/etc/fluent-bit.conf
  env:
    - name: OPENSEARCH_HOST
      value: {{ include "mageai.opensearchHost" . | quote }}
    - name: OPENSEARCH_PORT
      value: {{ .Values.logSearch.opensearch.port | quote }}
    - name: OPENSEARCH_LOG_INDEX
      value: {{ .Values.logSearch.opensearch.index | default "mage_logs" | quote }}
    - name: OPENSEARCH_TLS
      value: {{ if and .Values.logSearch.opensearch.tls .Values.logSearch.opensearch.tls.enabled }}"On"{{ else }}"Off"{{ end }}
    - name: OPENSEARCH_VERIFY_CERTS
      value: {{ if and .Values.logSearch.opensearch.tls .Values.logSearch.opensearch.tls.enabled .Values.logSearch.opensearch.tls.verify }}"On"{{ else }}"Off"{{ end }}
    {{- if and .Values.logSearch.opensearch.auth .Values.logSearch.opensearch.auth.enabled .Values.logSearch.opensearch.auth.existingSecret }}
    - name: OPENSEARCH_USERNAME
      valueFrom:
        secretKeyRef:
          name: {{ .Values.logSearch.opensearch.auth.existingSecret }}
          key: OPENSEARCH_USERNAME
    - name: OPENSEARCH_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ .Values.logSearch.opensearch.auth.existingSecret }}
          key: OPENSEARCH_PASSWORD
    {{- end }}
  volumeMounts:
    {{- if include "mageai.logSearch.persistenceEnabled" . }}
    - name: log-search-pvc
      mountPath: {{ .Values.logSearch.persistence.mountPath | default "/home/src" }}
      readOnly: true
      {{- if .Values.logSearch.persistence.subPath }}
      subPath: {{ .Values.logSearch.persistence.subPath }}
      {{- end }}
    {{- else if .Values.volumes }}
    - name: mage-fs
      mountPath: {{ .Values.logSearch.persistence.mountPath | default "/home/src" }}
      readOnly: true
    {{- else }}
    {{- $mountPath := .Values.logSearch.persistence.mountPath | default "/home/src" }}
    {{- range .Values.extraVolumeMounts }}
    {{- if eq .mountPath $mountPath }}
    - name: {{ .name }}
      mountPath: {{ .mountPath }}
      {{- if .subPath }}
      subPath: {{ .subPath }}
      {{- end }}
      readOnly: true
    {{- end }}
    {{- end }}
    {{- end }}
    - name: log-search-fluent-bit-config
      mountPath: /fluent-bit/etc/fluent-bit.conf
      subPath: fluent-bit.conf
    - name: log-search-fluent-bit-parsers
      mountPath: /fluent-bit/etc/parsers.conf
      subPath: parsers.conf
    - name: log-search-fluent-bit-state
      mountPath: /var/lib/fluent-bit
    {{- if and .Values.logSearch.opensearch.tls .Values.logSearch.opensearch.tls.enabled .Values.logSearch.opensearch.tls.existingSecret }}
    - name: log-search-opensearch-ca
      mountPath: /etc/ssl/opensearch
      readOnly: true
    {{- end }}
  resources:
    {{- toYaml .Values.logSearch.fluentBit.resources | nindent 4 }}
{{- end }}
{{- end -}}

{{- define "mageai.logSearch.volumes" -}}
{{- $root := .root -}}
{{- $includeFluentBit := .includeFluentBit -}}
{{- if and $root.Values.logSearch $root.Values.logSearch.enabled }}
{{- if include "mageai.logSearch.persistenceEnabled" $root }}
- name: log-search-pvc
  persistentVolumeClaim:
    claimName: {{ include "mageai.logSearch.persistenceClaimName" $root }}
{{- end }}
{{- if and $includeFluentBit (include "mageai.logSearch.fluentBitEnabled" $root) }}
- name: log-search-fluent-bit-config
  configMap:
    name: {{ include "mageai.logSearch.fluentBitConfigMap" $root }}
- name: log-search-fluent-bit-parsers
  configMap:
    name: {{ include "mageai.logSearch.fluentBitParsersConfigMap" $root }}
- name: log-search-fluent-bit-state
  emptyDir: {}
{{- end }}
{{- if and $root.Values.logSearch.opensearch.tls $root.Values.logSearch.opensearch.tls.enabled $root.Values.logSearch.opensearch.tls.existingSecret }}
- name: log-search-opensearch-ca
  secret:
    secretName: {{ $root.Values.logSearch.opensearch.tls.existingSecret }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Base path
*/}}
{{- define "mageai.basePath" -}}
{{- if .Values.extraEnvs }}
{{- range .Values.extraEnvs }}
{{- if eq .name "MAGE_BASE_PATH" }}
{{- printf "/%s" .value }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
