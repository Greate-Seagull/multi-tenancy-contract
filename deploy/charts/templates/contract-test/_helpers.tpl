{{/* Danh mục, lọc theo contractTests.run, giữ thứ tự danh mục, báo lỗi nếu tên lạ */}}
{{- define "contract.groups" -}}
{{- $raw := .Files.Get "contract-groups.yaml" -}}
{{- if not $raw -}}
  {{- fail "contract-groups.yaml không tìm thấy hoặc rỗng (kiểm tra tên file, vị trí ở gốc chart và .helmignore)" -}}
{{- end -}}
{{- $doc := $raw | fromYaml -}}
{{- if hasKey $doc "Error" -}}
  {{- fail (printf "contract-groups.yaml không phải YAML hợp lệ: %s" (get $doc "Error")) -}}
{{- end -}}
{{- $groups := $doc.groups -}}
{{- $run := .Values.contractTests.run -}}
{{- $known := list -}}
{{- range $groups }}{{ $known = append $known .name }}{{ end -}}
{{- range $run }}
  {{- if not (has . $known) }}
    {{- fail (printf "contractTests.run: group %q không tồn tại. Hợp lệ: %s" . (join ", " $known)) }}
  {{- end }}
{{- end -}}
{{- $out := list -}}
{{- range $groups }}{{ if has .name $run }}{{ $out = append $out . }}{{ end }}{{ end -}}
{{- toYaml $out -}}
{{- end }}

{{/* command của group + từng file kèm -f. Dùng: (dict "group" . "root" $) */}}
{{- define "contract.command" -}}
{{- $g := .group -}}
{{- $cmd := $g.command -}}
{{- $files := default (list) $g.files -}}
{{- if and .root.Values.contractTests.allowlist $g.allowlist $files -}}
  {{- $files = concat (initial $files) (list "/extra/allowlist.sql") (list (last $files)) -}}
{{- end -}}
{{- range $files }}{{ $cmd = concat $cmd (list "-f" .) }}{{ end -}}
{{- toYaml $cmd -}}
{{- end }}