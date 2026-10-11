#!/usr/bin/env bash
# Deploy bootstrap + migrate bằng Helm.
# Biến vào: NS IMAGE (bắt buộc)
# Tùy chọn: ENVIRONMENT (test|prod, mặc định test), BOOT_IMAGE, CONTRACT_TEST_IMAGE,
#           VALUES_FILE, RELEASE, CHART_DIR, TIMEOUT
set -euo pipefail

CURRENT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHART_DIR=${CHART_DIR:-"$CURRENT_DIR/charts"}

ENVIRONMENT=${ENVIRONMENT:-test}
: "${NS:?}" "${IMAGE:?}"
VALUES_FILE=${VALUES_FILE:-$CURRENT_DIR/$ENVIRONMENT/templates/values.yaml}
RELEASE=${RELEASE:-$NS-migrate}

TIMEOUT=${TIMEOUT:-3m}
[[ "$ENVIRONMENT" == "prod" ]] && TIMEOUT=30m

args=(
  -n "$NS"
  -f "$VALUES_FILE"
  --set "migration.image=$IMAGE"
  --wait
  --timeout "$TIMEOUT"
  --atomic
  --history-max 10
  --cleanup-on-fail
)

[[ -n "${BOOT_IMAGE:-}" ]] && args+=(--set "bootstrap.image=$BOOT_IMAGE")

# Contract test: tùy chọn, chỉ môi trường test. Job chỉ chạy khi gọi `helm test` (test.sh).
if [[ -n "${CONTRACT_TEST_IMAGE:-}" ]]; then
  args+=(--set "contractTests.enabled=true" --set "contractTests.image=$CONTRACT_TEST_IMAGE")
fi

echo "Deploying $RELEASE to $NS ($ENVIRONMENT)"
echo "  bootstrap image:     ${BOOT_IMAGE:-<không đổi>}"
echo "  migration image:     $IMAGE"
echo "  contract test image: ${CONTRACT_TEST_IMAGE:-<không>}"
echo "  values: $VALUES_FILE"

helm upgrade --install "$RELEASE" "$CHART_DIR" "${args[@]}"