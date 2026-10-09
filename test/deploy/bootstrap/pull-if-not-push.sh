#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE:?}" "${BOOT_IMAGE:?}"

# Kiểm tra đối số
die() { echo "ERROR: $*" >&2; exit 1; }

# Nạp image vào cluster local
LOCAL_CLUSTER=${LOCAL_CLUSTER:-k3s}
echo "Pulling image from $LOCAL_CLUSTER..."
case "$LOCAL_CLUSTER" in
  k3s)  docker save "$IMAGE" "$BOOT_IMAGE" | sudo k3s ctr images import - ;;
  k3d)  k3d image import "$IMAGE" "$BOOT_IMAGE" ;;
  kind) kind load docker-image "$IMAGE" "$BOOT_IMAGE" ;;
  ghcr) echo "bỏ qua nạp image: cluster sẽ kéo từ GHCR" ;;
  *)    echo "LOCAL_CLUSTER không hợp lệ: $LOCAL_CLUSTER" >&2; exit 1 ;;
esac