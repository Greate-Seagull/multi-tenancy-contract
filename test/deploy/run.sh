#!/usr/bin/env bash
set -euo pipefail

BOOT_IMAGE=${BOOT_IMAGE:-ghcr.io/greate-seagull/tenant-bootstrap:v1.0.1}
TEST_IMAGE=${TEST_IMAGE:-ghcr.io/greate-seagull/tenant-test:v1.0.1}
SERVICE_IMAGE=${SERVICE_IMAGE:-ghcr.io/greate-seagull/tenant-migration:v1.0.1}

docker run --network=host \
  -e BOOT_IMAGE=$BOOT_IMAGE \
  -e IMAGE=$SERVICE_IMAGE \
  --user "$(id -u):$(id -g)" \
  -v "$HOME/.kube/config:/home/deployer/.kube/config:ro" \
  "$TEST_IMAGE"