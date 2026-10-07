#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=.env

CURRENT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$CURRENT_DIR/.." && pwd)

MIGRATE_DIR="$REPO_DIR/deploy"

TEST_DIR="$REPO_DIR/test/deploy"
BOOTSTRAP_DIR="$TEST_DIR/bootstrap"
ARGS_DIR="$TEST_DIR/args"

if [[ -f "$ENV_FILE" ]]; then set -a; source "$ENV_FILE"; set +a; fi
export NS=${NS:?NS là bắt buộc (namespace của service)}
export DB_NS=${DB_NS:?DB_NS là bắt buộc (namespace của database)}
export TAG=${TAG:?TAG là bắt buộc cho version của image (ví dụ v1.0.0)}
export MIGRATION_PATH=${MIGRATION_PATH:?MIGRATION_PATH là bắt buộc}
: "${IMAGE:?}" "${BOOT_IMAGE:?}"

# In log khi lỗi.
on_exit() {
  local rc=$?
  if (( rc != 0 )); then "log-on-failure.sh"; fi
  exit "$rc"
}
trap on_exit EXIT

echo "Creating secrets..."
"$BOOTSTRAP_DIR/create-secret.sh"

echo "Creating database..."
export DB_FILE="$BOOTSTRAP_DIR/postgres.yaml"
"$BOOTSTRAP_DIR/create-database.sh"

echo "Pulling images..."
"$CURRENT_DIR/pull-if-not-push.sh"

echo "Migrating..."
export VALUES_FILE=${VALUES_FILE:-"$ARGS_DIR/values.yaml"}
"$MIGRATE_DIR/migrate-database.sh" test

echo "Finished!"