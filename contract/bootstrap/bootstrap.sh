#!/bin/sh
# Idempotent
set -eu

export PGHOST="$DB_HOST" PGPORT="$DB_PORT" PGUSER="$ADMIN_USER" PGPASSWORD="$ADMIN_PASSWORD"

until pg_isready -q; do echo "waiting for postgres..."; sleep 2; done

psql -v ON_ERROR_STOP=1 -d postgres \
  -v db="$DB_NAME" \
  -v mig="$MIGRATOR_USER" -v migpw="$MIGRATOR_PASSWORD" \
  -v app="$APP_USER"      -v apppw="$APP_PASSWORD" \
  -f "$(dirname "$0")/bootstrap.sql"

echo "bootstrap done: db=$DB_NAME migrator=$MIGRATOR_USER app=$APP_USER"