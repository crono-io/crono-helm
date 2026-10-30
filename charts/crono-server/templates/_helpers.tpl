{{/*
Naming, labelling, image and validation helpers for crono-server. Every
template name carries the `crono-server.` prefix so the chart can sit next to
crono-web in an umbrella chart without colliding defines.
*/}}

{{/* Chart name, truncated to the 63-character DNS label limit. */}}
{{- define "crono-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Resource name shared by every object (they differ by kind). A release named
"crono-server" yields "crono-server"; as the `server` alias of an umbrella
release "crono" it yields "crono-server" as well.
*/}}
{{- define "crono-server.fullname" -}}
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
{{- define "crono-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "crono-server.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/component: "server"
{{- end }}

{{/*
Pod template labels: no chart version, so a chart-only upgrade does not
restart pods.
*/}}
{{- define "crono-server.podLabels" -}}
{{ include "crono-server.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: "crono"
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Labels for every rendered object. */}}
{{- define "crono-server.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" | quote }}
{{ include "crono-server.podLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end }}

{{/* ServiceAccount used by the Deployment. */}}
{{- define "crono-server.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "crono-server.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. A digest pins `repository@digest` and takes precedence over
the tag; otherwise `repository:tag` with the tag defaulting to appVersion.
`requireImageDigest` turns a missing digest into a rendering failure.
*/}}
{{- define "crono-server.image" -}}
{{- $image := .Values.image }}
{{- if $image.digest }}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $image.digest) }}
{{- fail "crono-server: image.digest must be sha256:<64 lowercase hex>" }}
{{- end }}
{{- printf "%s@%s" $image.repository $image.digest }}
{{- else if .Values.requireImageDigest }}
{{- fail "crono-server: image.digest is required when requireImageDigest is true" }}
{{- else }}
{{- printf "%s:%s" $image.repository (default .Chart.AppVersion $image.tag) }}
{{- end }}
{{- end }}

{{/* Secret holding the server credentials (existing or chart-created). */}}
{{- define "crono-server.secretName" -}}
{{- default (include "crono-server.fullname" .) .Values.existingSecret }}
{{- end }}

{{/*
Data of the chart-created Secret as YAML (plain values). Fails when a value
the configuration needs is missing. Only used when existingSecret is empty.
*/}}
{{- define "crono-server.secretData" -}}
{{- $s := .Values.secret | default dict }}
{{- $token := required "crono-server: secret.authToken is required when existingSecret is empty" $s.authToken | toString }}
{{- if or (lt (len $token) 32) (gt (len $token) 8192) }}
{{- fail "crono-server: secret.authToken must be 32-8192 bytes" }}
{{- end }}
{{- $data := dict "CRONO_AUTH_DEVELOPMENT_TOKEN" $token }}
{{- $_ := set $data "PGPASSWORD" (required "crono-server: secret.databasePassword is required when existingSecret is empty" $s.databasePassword | toString) }}
{{- $mode := .Values.nats.auth.mode }}
{{- if eq $mode "nkey" }}
{{- $_ := set $data "nats.nkey" (required "crono-server: secret.natsNkeySeed is required when nats.auth.mode is nkey and existingSecret is empty" $s.natsNkeySeed | toString) }}
{{- else if eq $mode "creds" }}
{{- $_ := set $data "nats.creds" (required "crono-server: secret.natsCreds is required when nats.auth.mode is creds and existingSecret is empty" $s.natsCreds | toString) }}
{{- else if eq $mode "userPassword" }}
{{- $_ := set $data "CRONO_NATS_PASSWORD" (required "crono-server: secret.natsPassword is required when nats.auth.mode is userPassword and existingSecret is empty" $s.natsPassword | toString) }}
{{- end }}
{{- toYaml $data }}
{{- end }}

{{/*
Validation shared by the Deployment. The schema enforces the same rules; the
explicit failures keep the message clear when the schema is bypassed with
null values.
*/}}
{{- define "crono-server.validate" -}}
{{- $_ := required "crono-server: database.host is required" .Values.database.host }}
{{- $_ := required "crono-server: nats.url is required" .Values.nats.url }}
{{- if eq .Values.nats.auth.mode "userPassword" }}
{{- $_ := required "crono-server: nats.auth.user is required when nats.auth.mode is userPassword" .Values.nats.auth.user }}
{{- end }}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas)) }}
{{- fail "crono-server: autoscaling.minReplicas must not be greater than autoscaling.maxReplicas" }}
{{- end }}
{{- end }}

{{/* Topology spread constraints with a default labelSelector for the pods. */}}
{{- define "crono-server.topologySpread" -}}
{{- $selector := dict "matchLabels" (include "crono-server.selectorLabels" . | fromYaml) }}
{{- range .Values.topologySpreadConstraints }}
- {{ merge (dict) . (dict "labelSelector" $selector) | toYaml | nindent 2 }}
{{- end }}
{{- end }}

{{/*
PostgreSQL URL without the password (sqlx reads PGPASSWORD). sslrootcert is
added only when a CA Secret is mounted. IPv6 literal hosts are bracketed; the
user and database name are percent-encoded (spaces as %20, not `+`).
*/}}
{{- define "crono-server.databaseUrl" -}}
{{- $db := .Values.database }}
{{- $host := $db.host }}
{{- if and (contains ":" $host) (not (hasPrefix "[" $host)) }}
{{- $host = printf "[%s]" $host }}
{{- end }}
{{- $user := urlquery $db.user | replace "+" "%20" }}
{{- $name := urlquery $db.name | replace "+" "%20" }}
{{- $url := printf "postgres://%s@%s:%d/%s?sslmode=%s" $user $host (int $db.port) $name $db.sslMode }}
{{- if $db.caSecret.name }}
{{- $url = printf "%s&sslrootcert=/etc/crono/postgres/ca.crt" $url }}
{{- end }}
{{- $url }}
{{- end }}

{{/* True when the pod mounts the projected /etc/crono/nats volume. */}}
{{- define "crono-server.natsVolumeEnabled" -}}
{{- $nats := .Values.nats }}
{{- if or $nats.caSecret.name (eq $nats.auth.mode "nkey") (eq $nats.auth.mode "creds") }}true{{- end }}
{{- end }}
