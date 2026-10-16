{{/*
Khối authentication dùng chung cho mọi CR của VCO.
VCO xin token cho ServiceAccount "vault-config" ngay trong namespace của CR này,
rồi đăng nhập Vault bằng role "policy-admin" (tạo ở BOOTSTRAP.md bước 6).
*/}}
{{- define "pgv.auth" -}}
authentication:
  path: kubernetes
  role: policy-admin
  serviceAccount:
    name: vault-config
{{- end }}

{{/* Namespace chạy Postgres (nơi cert-manager và các service xin cert) */}}
{{- define "pgv.pgNamespace" -}}
{{- required "postgres.namespace là bắt buộc" .Values.postgres.namespace -}}
{{- end }}
