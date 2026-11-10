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

{{- /* Environment shared by the Deployment and the migration Job. The Job passes its own overrides
(migration.env) as `extra`: they REPLACE the entry of the same name in `env` (two entries with one
name make the API server refuse the Job: found 2026-11-10, catalog DB_USER). */ -}}
{{- define "gps.envWith" -}}
{{- $root := .root -}}
{{- $env := mergeOverwrite (deepCopy $root.Values.env) .extra -}}
- {name: HTTP_ADDR, value: {{ printf ":%d" (int $root.Values.port) | quote }}}
- {name: BASE_PATH, value: {{ $root.Values.basePath | quote }}}
{{- if $root.Values.telemetry.enabled }}
- {name: OTEL_EXPORTER_OTLP_ENDPOINT, value: {{ $root.Values.telemetry.endpoint | quote }}}
- {name: OTEL_EXPORTER_OTLP_PROTOCOL, value: "http/protobuf"}
- {name: OTEL_SERVICE_NAME, value: {{ include "gps.fullname" $root | quote }}}
- {name: OTEL_RESOURCE_ATTRIBUTES, value: {{ printf "deployment.environment=%s,service.version=%s" $root.Values.telemetry.environment $root.Values.image.tag | quote }}}
- {name: OTEL_TRACES_SAMPLER, value: {{ $root.Values.telemetry.sampler | quote }}}
{{- if $root.Values.telemetry.samplerArg }}
- {name: OTEL_TRACES_SAMPLER_ARG, value: {{ $root.Values.telemetry.samplerArg | quote }}}
{{- end }}
{{- end }}
{{- range $k, $v := $env }}
- {name: {{ $k }}, value: {{ $v | quote }}}
{{- end }}
{{- end }}
{{- define "gps.env" -}}{{ include "gps.envWith" (dict "root" . "extra" (dict)) }}{{- end }}

{{- /* Where the probes live: the Go services answer /livez and /readyz at the ROOT of the port (their
contracts), only the skeleton registers them under its base path (probes.underBasePath). Used by the
Deployment probes, the ALB health check and the smoke test. */ -}}
{{- define "gps.healthPrefix" -}}{{ if .Values.probes.underBasePath }}{{ .Values.basePath }}{{ end }}{{- end }}

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
