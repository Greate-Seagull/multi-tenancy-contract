TAG=${TAG:-"v1.0.0"}
BOOT_IMAGE=${BOOT_IMAGE:-ghcr.io/greate-seagull/db-bootstrap}
IMAGE=${IMAGE:-ghcr.io/greate-seagull/db-migration}
TEST_IMAGE=${TEST_IMAGE:-ghcr.io/greate-seagull/deploy-test}

docker run --network=host \
  -e BOOT_IMAGE=$BOOT_IMAGE \
  -e IMAGE=$IMAGE \
  -e TAG=$TAG \
  -e KUBECONFIG=/home/deployer/.kube/config \
  -v "$HOME/.kube:/home/deployer/.kube:ro" \
  "$TEST_IMAGE:$TAG" all

echo "Exit code: $?"
# 0 = thành công, khác 0 = thất bại