{{/* Tên Secret theo quy ước: <service>-db-<role> */}}
{{- define "migrate.secretName" -}}
{{ printf "%s-db-%s" .root.Release.Namespace .role }}
{{- end }}

{{/* Một biến env lấy từ Secret theo quy ước (key: username | password) */}}
{{- define "migrate.secretEnv" -}}
- name: {{ .env }}
  valueFrom:
    secretKeyRef:
      name: {{ include "migrate.secretName" (dict "root" .root "role" .role) }}
      key: {{ .key }}
{{- end }}

{{/* Container Flyway dùng chung cho platform và service */}}
{{- define "migrate.container" -}}
name: {{ .name }}
image: {{ required "migration image is required" .root.Values.migration.image }}
args:
  - -placeholders.app_user=$(APP_USER)
  - migrate
env:
  - name: FLYWAY_URL
    value: jdbc:postgresql://{{ .root.Values.db.host }}:{{ .root.Values.db.port }}/{{ .root.Values.db.name }}
  {{- include "migrate.secretEnv" (dict "root" .root "role" "migrator" "env" "FLYWAY_USER" "key" "username") | nindent 2 }}
  {{- include "migrate.secretEnv" (dict "root" .root "role" "migrator" "env" "FLYWAY_PASSWORD" "key" "password") | nindent 2 }}
  {{- include "migrate.secretEnv" (dict "root" .root "role" "app" "env" "APP_USER" "key" "username") | nindent 2 }}
  - name: FLYWAY_LOCATIONS
    value: {{ .locations }}
  - name: FLYWAY_SCHEMAS
    value: {{ .schema }}
  - name: FLYWAY_CONNECT_RETRIES
    value: "30"
{{- end }}
