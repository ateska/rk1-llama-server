#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo 'Building rocket-runtime:local (this will take ~1 h first time, ~30 s incremental)'
docker build -t rocket-runtime:local -f Dockerfile .
rm -f bench.sh
echo 'Done: rocket-runtime:local'
