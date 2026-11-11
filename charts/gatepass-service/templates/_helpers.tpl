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

{{- /*
The POD TEMPLATE shared by the Deployment and, when rollout.enabled, the Argo Rollouts Rollout (same
pods, different controller). Choices that matter (and are the same for every service):
- image by digest; `checksum/config` changes when env or secret definitions change, so a config
  change rolls the pods (the contracts say config is read at start-up only);
- non-root, read-only root filesystem (the process writes only to /tmp, an emptyDir), no
  capabilities, seccomp default;
- three probes: startup (slow start), readiness (take me out of the load balancer), liveness
  (restart me). Paths: see gps.healthPrefix;
- spread over zones and nodes: `topologySpread.zone` is DoNotSchedule for services that must survive the
  loss of an availability zone, ScheduleAnyway (best effort) for the rest; nodes are always best effort;
- graceful stop: on SIGTERM the Go services flip /readyz to 503 and keep serving for SHUTDOWN_DELAY
  while the load balancer deregisters them; `preStopSleepSeconds` adds a pause BEFORE the signal (a native
  Kubernetes sleep action: the images have no shell), and terminationGracePeriodSeconds must cover
  preStop + SHUTDOWN_DELAY + the drain;
- `affinity` is passed through (workers prefer the Spot pool and fall back to on-demand).
*/ -}}
{{- define "gps.podTemplate" -}}
metadata:
  labels: {{- include "gps.labels" . | nindent 4 }}
  annotations:
    checksum/config: {{ dict "env" .Values.env "ext" .Values.externalSecret "files" .Values.secretFiles | toJson | sha256sum }}
spec:
  serviceAccountName: {{ include "gps.serviceAccountName" . }}
  automountServiceAccountToken: {{ .Values.serviceAccount.automountToken }}
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile: {type: RuntimeDefault}
  {{- with .Values.nodeSelector }}
  nodeSelector: {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations: {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity: {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if .Values.topologySpread.enabled }}
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: {{ .Values.topologySpread.zone }}
      labelSelector:
        matchLabels: {{- include "gps.selectorLabels" . | nindent 10 }}
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels: {{- include "gps.selectorLabels" . | nindent 10 }}
  {{- end }}
  containers:
    - name: app
      image: {{ include "gps.image" . | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - {name: http, containerPort: {{ .Values.port }}}
        {{- if .Values.internalService.enabled }}
        - {name: internal, containerPort: {{ .Values.internalService.port }}}
        {{- end }}
      env: {{- include "gps.env" . | nindent 8 }}
      {{- if .Values.externalSecret.enabled }}
      envFrom:
        - secretRef: {name: {{ include "gps.fullname" . }}-secrets}
      {{- end }}
      resources: {{- toYaml .Values.resources | nindent 8 }}
      securityContext: {{- include "gps.containerSecurity" . | nindent 8 }}
      {{- if gt (int .Values.preStopSleepSeconds) 0 }}
      lifecycle:
        preStop:
          sleep: {seconds: {{ .Values.preStopSleepSeconds }}}
      {{- end }}
      startupProbe:
        httpGet: {path: {{ printf "%s/livez" (include "gps.healthPrefix" .) }}, port: http}
        {{- toYaml .Values.probes.startup | nindent 8 }}
      readinessProbe:
        httpGet: {path: {{ printf "%s/readyz" (include "gps.healthPrefix" .) }}, port: http}
        {{- toYaml .Values.probes.readiness | nindent 8 }}
      livenessProbe:
        httpGet: {path: {{ printf "%s/livez" (include "gps.healthPrefix" .) }}, port: http}
        {{- toYaml .Values.probes.liveness | nindent 8 }}
      volumeMounts:
        - {name: tmp, mountPath: /tmp}
        {{- if .Values.secretFiles.enabled }}
        - {name: secret-files, mountPath: {{ .Values.secretFiles.mountPath }}, readOnly: true}
        {{- end }}
  volumes:
    - name: tmp
      emptyDir: {}
    {{- if .Values.secretFiles.enabled }}
    # defaultMode 0440 + fsGroup 65532 (pod securityContext): readable by the service user only.
    - name: secret-files
      secret: {secretName: {{ include "gps.fullname" . }}-files, defaultMode: 0440}
    {{- end }}
{{- end }}
