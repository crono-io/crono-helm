{{/*
Naming, labelling, image and validation helpers for crono-web. Every template
name carries the `crono-web.` prefix so the chart can sit next to
crono-server in an umbrella chart without colliding defines.
*/}}

{{/* Chart name, truncated to the 63-character DNS label limit. */}}
{{- define "crono-web.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Resource name shared by every object (they differ by kind). A release named
"crono-web" yields "crono-web"; as the `web` alias of an umbrella release
"crono" it yields "crono-web" as well.
*/}}
{{- define "crono-web.fullname" -}}
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
Selector labels. Values are quoted so release names such as `n`, `on` or
`true` stay strings.
*/}}
{{- define "crono-web.selectorLabels" -}}
app.kubernetes.io/name: {{ include "crono-web.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/component: "web"
{{- end }}

{{/*
Pod template labels: no chart version, so a chart-only upgrade does not
restart pods.
*/}}
{{- define "crono-web.podLabels" -}}
{{ include "crono-web.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: "crono"
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Labels for every rendered object. */}}
{{- define "crono-web.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" | quote }}
{{ include "crono-web.podLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end }}

{{/* ServiceAccount used by the Deployment. */}}
{{- define "crono-web.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "crono-web.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. A digest pins `repository@digest` and takes precedence over
the tag; otherwise `repository:tag` with the tag defaulting to appVersion.
`requireImageDigest` turns a missing digest into a rendering failure.
*/}}
{{- define "crono-web.image" -}}
{{- $image := .Values.image }}
{{- if $image.digest }}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $image.digest) }}
{{- fail "crono-web: image.digest must be sha256:<64 lowercase hex>" }}
{{- end }}
{{- printf "%s@%s" $image.repository $image.digest }}
{{- else if .Values.requireImageDigest }}
{{- fail "crono-web: image.digest is required when requireImageDigest is true" }}
{{- else }}
{{- printf "%s:%s" $image.repository (default .Chart.AppVersion $image.tag) }}
{{- end }}
{{- end }}

{{/* Validation shared by the Deployment. */}}
{{- define "crono-web.validate" -}}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas)) }}
{{- fail "crono-web: autoscaling.minReplicas must not be greater than autoscaling.maxReplicas" }}
{{- end }}
{{- end }}

{{/* Topology spread constraints with a default labelSelector for the pods. */}}
{{- define "crono-web.topologySpread" -}}
{{- $selector := dict "matchLabels" (include "crono-web.selectorLabels" . | fromYaml) }}
{{- range .Values.topologySpreadConstraints }}
- {{ merge (dict) . (dict "labelSelector" $selector) | toYaml | nindent 2 }}
{{- end }}
{{- end }}
