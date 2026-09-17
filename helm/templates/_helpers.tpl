{{/*
Expand the name of the chart.
*/}}
{{- define "bidflow-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "bidflow-app.fullname" -}}
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
Fully qualified name for one of the polyglot services, e.g.
"bidflow-app-go-bidder" / "bidflow-app-ruby-bidder". Pass a dict:
  (dict "root" $ "key" $svcKey)
where $svcKey is the values.yaml key ("goBidder"/"rubyBidder") — this
converts camelCase to kebab-case so it matches the Docker image / repo
naming convention.
*/}}
{{- define "bidflow-app.serviceFullname" -}}
{{- $kebab := .key | kebabcase -}}
{{- printf "%s-%s" (include "bidflow-app.fullname" .root) $kebab -}}
{{- end }}

{{/*
Common labels
*/}}
{{- define "bidflow-app.labels" -}}
helm.sh/chart: {{ include "bidflow-app.chart" . }}
{{ include "bidflow-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "bidflow-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bidflow-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Per-service selector labels — pass (dict "root" $ "key" $svcKey).
*/}}
{{- define "bidflow-app.serviceSelectorLabels" -}}
{{ include "bidflow-app.selectorLabels" .root }}
app.kubernetes.io/component: {{ .key | kebabcase }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "bidflow-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full image reference for a service: <registry>/<repository>:<tag>
Pass the service's own values sub-tree as ".", e.g. .Values.services.goBidder
merged with the registry — call as (dict "registry" .Values.imageRegistry "svc" $svc)
*/}}
{{- define "bidflow-app.image" -}}
{{- printf "%s/%s:%s" .registry .svc.image.repository .svc.image.tag -}}
{{- end }}

{{/*
OTLP endpoint every service exports traces to — the Jaeger all-in-one
Service this same release deploys, so it's always correct regardless of
release name/namespace.
*/}}
{{- define "bidflow-app.otlpEndpoint" -}}
{{- printf "http://%s-jaeger:4318" (include "bidflow-app.fullname" .) -}}
{{- end }}
