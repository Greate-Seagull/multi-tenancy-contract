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
if ! helmfile -f "$HELMFILE" --selector "name=${NS}-release" test --timeout 480; then
  echo "contract tests: FAIL"
  exit 1
fi
echo "contract tests: PASS"