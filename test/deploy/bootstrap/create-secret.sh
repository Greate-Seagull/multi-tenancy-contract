#!/usr/bin/env bash
set -euo pipefail

: "${NS:?}" "${DB_NS:?}" "${DB_ADMIN_PASSWORD:?}" "${MIGRATOR_PASSWORD:?}" "${APP_PASSWORD:?}"

# Vòng lặp tạo namespace từ 2 giá trị nếu chưa tạo
for ns in "$DB_NS" "$NS"; do
  kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# Tạo secret
# Hàm tạo secret
secret() {   # secret <namespace> <tên> <key=value>...
  local ns=$1 name=$2; shift 2
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kubectl -n "$ns" create secret generic "$name" "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

secret "$DB_NS"    postgres-admin       "POSTGRES_PASSWORD=$DB_ADMIN_PASSWORD"
secret "$NS" "$NS-db-admin"      username=postgres        "password=$DB_ADMIN_PASSWORD"
secret "$NS" "$NS-db-migrator"   username=tenant_migrator "password=$MIGRATOR_PASSWORD"
secret "$NS" "$NS-db-app"        username=tenant_app      "password=$APP_PASSWORD"