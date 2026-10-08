#!/usr/bin/env bash
# Contract test nhóm C — orchestrator.
# Cần: PGHOST PGDATABASE [PGPORT] MIG_USER MIG_PASSWORD APP_USER APP_PASSWORD
set -euo pipefail
: "${PGHOST:?}" "${PGDATABASE:?}" "${MIG_USER:?}" "${MIG_PASSWORD:?}" "${APP_USER:?}" "${APP_PASSWORD:?}"
export PGPORT="${PGPORT:-5432}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -w: không bao giờ prompt password; thiếu password là fail ngay.
# -v app=...: chỉ mig cần, vì C1_fixture.sql dùng :"app".
mig() { PGUSER="$MIG_USER" PGPASSWORD="$MIG_PASSWORD" psql -X -q -w -v ON_ERROR_STOP=1 -v app="$APP_USER" "$@"; }
app() { PGUSER="$APP_USER" PGPASSWORD="$APP_PASSWORD" psql -X -q -w -v ON_ERROR_STOP=1 "$@"; }

cleanup() { mig -c 'SET client_min_messages = warning; DROP SCHEMA IF EXISTS contract_test_c CASCADE' || true; }
trap cleanup EXIT

cleanup
mig -f "$DIR/C1_fixture.sql"      # fixture + seed (migrator)
app -f "$DIR/C2_app_tests.sql"    # C0, C14–C20  (app)
mig -f "$DIR/C3_owner_tests.sql"  # C21          (migrator)

echo 'Contract C (cách ly tenant, test 14-21): PASS'