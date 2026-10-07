set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

VERSION="v1.0.0"   # hoặc export từ CI
TAG=ghcr.io/greate-seagull/db-migration:$VERSION

docker build \
  -f contract/migration-base/Dockerfile \
  -t $TAG \
  .

docker push $TAG