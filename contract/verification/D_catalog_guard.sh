#!/usr/bin/env bash
# Contract test nhóm D: quét catalog của DB thật (chỉ đọc, không tạo/xóa gì trong DB).
# Cần: PGHOST PGDATABASE [PGPORT] MIG_USER MIG_PASSWORD APP_USER
# Chạy bằng migrator sau khi helm upgrade xong (trước hoặc sau nhóm C đều được).
set -euo pipefail
: "${PGHOST:?}" "${PGDATABASE:?}" "${MIG_USER:?}" "${MIG_PASSWORD:?}" "${APP_USER:?}"
export PGPORT="${PGPORT:-5432}"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hai file -f chạy chung một session nên bảng tạm `allow` dùng được trong file guard.
PGUSER="$MIG_USER" PGPASSWORD="$MIG_PASSWORD" \
  psql -X -q -v ON_ERROR_STOP=1 -v app="$APP_USER" \
       -f "$dir/D_allowlist.sql" -f "$dir/D_catalog_guard.sql"