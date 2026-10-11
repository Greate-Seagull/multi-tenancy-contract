#!/usr/bin/env bash
# Dựng Postgres test, deploy bootstrap + migrate, chạy contract test bằng Helmfile.
# Cần sẵn: helm, helmfile, kubectl trỏ tới cluster test (kind trong CI).
# Biến vào (bắt buộc): BOOT_IMAGE SERVICE_IMAGE CONTRACT_TEST_IMAGE
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

export BOOT_IMAGE=${BOOT_IMAGE:?}
export IMAGE=${SERVICE_IMAGE:?}
export CONTRACT_TEST_IMAGE=${CONTRACT_TEST_IMAGE:?}

NS=test
HELMFILE=test/deploy/helmfile.yaml.gotmpl

# 1. Postgres + Secret, rồi bootstrap + migrate (thứ tự do `needs`); chờ xong mới trả về
helmfile -f "$HELMFILE" sync

# 2. Contract test: chỉ chạy hook `test` của release migrate.
# Không dùng --logs: Helm chỉ lấy log của Pod trùng tên hook, mà hook của ta là Job nên sẽ báo "pods not found".
if ! helmfile -f "$HELMFILE" --selector "name=${NS}-release" test --timeout 480; then
  echo "contract tests: FAIL" >&2
  job="${NS}-release-contract-tests"
  kubectl -n "$NS" get job,pods -l "job-name=$job" -o wide >&2 || true
  for c in group-a group-b group-c group-d; do
    echo "--- $c" >&2
    kubectl -n "$NS" logs -l "job-name=$job" -c "$c" --tail=-1 >&2 || true
  done
  kubectl -n "$NS" describe pod -l "job-name=$job" 2>&1 | tail -40 >&2 || true

  echo "--- PGOPTIONS thực tế trong Job" >&2
  kubectl -n "$NS" get job "$job" -o yaml 2>&1 | grep -A1 'name: PGOPTIONS' | head -4 >&2 || true

  echo "--- Hàm, schema và quyền của tenant_app trong DB" >&2
  kubectl -n "${NS}-db" exec postgres-0 -- psql -U postgres -d test \
    -c '\df *.current_tenant_id' \
    -c '\dn+' \
    -c "select has_schema_privilege('tenant_app','platform','USAGE') as app_usage_platform" \
    -c "select has_function_privilege('tenant_app','platform.current_tenant_id()','EXECUTE') as app_exec_fn" >&2 || true
  exit 1
fi
echo "contract tests: PASS"