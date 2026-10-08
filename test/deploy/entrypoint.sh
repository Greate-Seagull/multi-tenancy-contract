#!/usr/bin/env bash
set -euo pipefail

export ROOT_DIR=/opt
export DEPLOY_DIR=$ROOT_DIR/deploy
export CHART_DIR=$DEPLOY_DIR/charts
export SCRIPT_DIR=$DEPLOY_DIR/scripts

export NS=test
export DB_NS=${NS}-db
export DB_FILE=${DB_FILE:-$SCRIPT_DIR/postgres.yaml}

export DB_ADMIN_PASSWORD=${DB_ADMIN_PASSWORD:-root}
export MIGRATOR_PASSWORD=${MIGRATOR_PASSWORD:-root}
export APP_PASSWORD=${APP_PASSWORD:-root}

export ENVIRONMENT=${ENVIRONMENT:-test}
export VALUES_FILE=$SCRIPT_DIR/values.yaml

export BOOT_IMAGE=${BOOT_IMAGE:?}
export IMAGE=${IMAGE:?}

export LOCAL_CLUSTER=${LOCAL_CLUSTER:-ghcr}

run_secrets()  { $SCRIPT_DIR/create-secret.sh; }
run_database() { $SCRIPT_DIR/create-database.sh; }
run_pull() { $SCRIPT_DIR/pull-if-not-push.sh; }
run_migrate()  { $SCRIPT_DIR/migrate-database.sh; }

run_secrets
run_database
run_pull
run_migrate