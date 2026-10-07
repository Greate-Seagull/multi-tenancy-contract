#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=.env

if [[ -f "$ENV_FILE" ]]; then set -a; source "$ENV_FILE"; set +a; fi
: "${NS:?NS là bắt buộc (namespace của service)}"
: "${DB_NS:?DB_NS là bắt buộc (namespace của database)}"

echo "Cluster : $(kubectl config current-context)"
echo "Sẽ xóa  : release '$NS', namespace '$NS', database '$DB_NS'"

# 1) Helm release (hook Job còn sót sẽ bị xóa cùng namespace ở bước 3)
if helm status "$NS" -n "$NS" >/dev/null 2>&1; then
  helm uninstall "$NS" -n "$NS"
else
  echo "(release '$NS' không tồn tại, bỏ qua)"
fi

# 2) Namespace của service: xóa Job, pod, Secret bên trong
kubectl delete ns "$NS" --ignore-not-found --wait

# 3) Postgres dùng chung
kubectl delete ns "$DB_NS" --ignore-not-found --wait

echo "Đã dọn xong."