set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

VERSION="v1.0.0"   # hoặc export từ CI
TAG=ghcr.io/greate-seagull/db-bootstrap:$VERSION

docker build \
  -f contract/bootstrap/Dockerfile \
  -t $TAG \
  .

docker push $TAG