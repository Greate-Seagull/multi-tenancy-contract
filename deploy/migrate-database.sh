#!/usr/bin/env bash
set -euo pipefail
CURRENT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHART_DIR=${CHART_DIR:-"$CURRENT_DIR/charts"}

ENVIRONMENT=${ENVIRONMENT:-test}
: "${NS:?}" "${IMAGE:?}"
VALUES_FILE=${VALUES_FILE:-$CURRENT_DIR/$ENVIRONMENT/templates/values.yaml}

RELEASE=${RELEASE:-$NS-migrate}
TIMEOUT=${TIMEOUT:-10m}
[[ "$ENVIRONMENT" == "prod" ]] && TIMEOUT=30m

args=(
  -n "$NS"
#  --create-namespace
  -f "$VALUES_FILE"
  --set "migration.image=$IMAGE"
  --wait
  --timeout "$TIMEOUT"
  --atomic
  --history-max 10
  --cleanup-on-fail
)

if [[ -n "${BOOT_IMAGE:-}" ]]; then
  args+=(--set "bootstrap.image=$BOOT_IMAGE")
fi

echo "Deploying $RELEASE to $NS ($ENVIRONMENT)"
echo "  bootstrapping image:  $BOOT_IMAGE"
echo "  migrating image:  $IMAGE"
echo "  values: $VALUES_FILE"

helm upgrade --install "$RELEASE" \
  $CHART_DIR \
  "${args[@]}"