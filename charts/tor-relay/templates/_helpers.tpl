{{- define "tor-relay.labels" -}}
app.kubernetes.io/name: tor-relay
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
