{{/*
Resolve the service name: use .Values.serviceName if set, otherwise Release.Name.
*/}}
{{- define "nimbus-service.name" -}}
{{- .Values.serviceName | default .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels attached to every resource.
*/}}
{{- define "nimbus-service.labels" -}}
app: {{ include "nimbus-service.name" . }}
app.kubernetes.io/name: {{ include "nimbus-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels used by Deployment and Service.
*/}}
{{- define "nimbus-service.selectorLabels" -}}
app: {{ include "nimbus-service.name" . }}
{{- end }}
