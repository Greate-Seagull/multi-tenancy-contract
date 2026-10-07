set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

VERSION="v1.0.0"   # hoặc export từ CI
TAG=ghcr.io/greate-seagull/deploy-test:$VERSION

docker build \
  -f test/deploy/Dockerfile \
  -t $TAG \
  .