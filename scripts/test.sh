#!/usr/bin/env bash
# Run the shim's unit tests inside the container image, so they run against the
# same Python and dependencies as production. No local Python setup needed.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=tesla-api-shim:test
echo "==> building test image"
docker build -q -t "$IMAGE" ./shim >/dev/null

echo "==> running tests"
docker run --rm \
  -e SHIM_NO_START=1 \
  -e DATA_DIR=/tmp/shim-test-data \
  -v "$PWD/shim:/app:ro" \
  -w /app \
  "$IMAGE" python -m unittest discover -s /app -p 'test_*.py' -v
