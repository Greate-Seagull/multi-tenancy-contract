#!/usr/bin/env bash
set -euo pipefail

DB_NS="${DB_NS:?}"
DB_FILE="${DB_FILE:-./postgres.yaml}"

kubectl apply -n "$DB_NS" -f "$DB_FILE"
kubectl -n "$DB_NS" rollout status statefulset/postgres --timeout=180s