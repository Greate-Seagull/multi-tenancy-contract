set -euo pipefail

cd "$(git rev-parse --show-toplevel)/contract/migration-base"

VERSION="v1.0.0"   # hoặc export từ CI
TAG=ghcr.io/greate-seagull/db-migration:$VERSION

docker build \
  -t $TAG \
  .

docker push $TAG