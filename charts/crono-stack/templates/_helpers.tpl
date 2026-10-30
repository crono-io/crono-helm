{{/*
Full name a dependency gives its resources, mirroring the standard Helm
fullname helper used by crono-server, crono-web and the NATS chart. `name` is
the alias (server, web) or chart name (nats).
Usage: include "crono-stack.componentFullname" (dict "root" $ "values" .Values.server "name" "server")
*/}}
{{- define "crono-stack.componentFullname" -}}
{{- $values := .values -}}
{{- $name := default .name $values.nameOverride -}}
{{- if $values.fullnameOverride -}}
{{- $values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains $name .root.Release.Name -}}
{{- .root.Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .root.Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
