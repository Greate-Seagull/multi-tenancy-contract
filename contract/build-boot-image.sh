set -euo pipefail

cd "$(git rev-parse --show-toplevel)/contract/bootstrap/"

VERSION="v1.0.0"   # hoặc export từ CI
TAG=ghcr.io/greate-seagull/db-bootstrap:$VERSION

docker build \
  -t $TAG \
  .

docker push $TAG