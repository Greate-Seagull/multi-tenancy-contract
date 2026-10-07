#!/usr/bin/env bash
# Chẩn đoán khi deploy lỗi. Không dùng `set -e` để một lệnh lỗi không chặn lệnh sau.
set -uo pipefail

: "${NS:?}"

for job in bootstrap migrate; do
  echo "::group::logs $NS-$job"
  kubectl -n "$NS" logs "job/$NS-$job" --all-containers --prefix --tail=100 || true
  echo "::endgroup::"
done