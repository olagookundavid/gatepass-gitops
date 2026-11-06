{{- /*
Names and labels, in one place so every object agrees.
  fullname      = the release name (Argo CD names the release after the Application, which the
                  ApplicationSet names after the apps/<dir>). One service = one release.
  selectorLabels  the labels a Service or Deployment uses to find its pods. They must NEVER
                  change after the first deploy (a Deployment's selector is immutable).
  labels          the Kubernetes recommended labels, safe to add to.
*/ -}}
{{- define "gps.fullname" -}}{{ .Release.Name }}{{- end }}

{{- define "gps.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gps.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "gps.labels" -}}
{{ include "gps.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: gatepass
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- define "gps.serviceAccountName" -}}
{{- if .Values.serviceAccount.name }}{{ .Values.serviceAccount.name }}{{ else }}{{ include "gps.fullname" . }}{{ end }}
{{- end }}

{{- define "gps.image" -}}{{ .Values.image.registry }}/{{ .Values.image.repository }}@{{ .Values.image.digest }}{{- end }}

{{- /* Environment shared by the Deployment and the migration Job. */ -}}
{{- define "gps.env" -}}
- {name: HTTP_ADDR, value: {{ printf ":%d" (int .Values.port) | quote }}}
- {name: BASE_PATH, value: {{ .Values.basePath | quote }}}
{{- if .Values.telemetry.enabled }}
- {name: OTEL_EXPORTER_OTLP_ENDPOINT, value: {{ .Values.telemetry.endpoint | quote }}}
- {name: OTEL_EXPORTER_OTLP_PROTOCOL, value: "http/protobuf"}
- {name: OTEL_SERVICE_NAME, value: {{ include "gps.fullname" . | quote }}}
- {name: OTEL_RESOURCE_ATTRIBUTES, value: {{ printf "deployment.environment=%s,service.version=%s" .Values.telemetry.environment .Values.image.tag | quote }}}
- {name: OTEL_TRACES_SAMPLER, value: {{ .Values.telemetry.sampler | quote }}}
{{- if .Values.telemetry.samplerArg }}
- {name: OTEL_TRACES_SAMPLER_ARG, value: {{ .Values.telemetry.samplerArg | quote }}}
{{- end }}
{{- end }}
{{- range $k, $v := .Values.env }}
- {name: {{ $k }}, value: {{ $v | quote }}}
{{- end }}
{{- end }}

{{- /* The security settings every container gets: non-root, read-only filesystem, no capabilities. */ -}}
{{- define "gps.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end }}
