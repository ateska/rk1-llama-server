#!/usr/bin/env bash
# switch-model.sh — swap the running model on the fly
#
# Usage:
#   ./switch-model.sh qwen2.5-3b-instruct-f16.gguf          # just the file
#   ./switch-model.sh qwen2.5-3b-instruct-f16.gguf my-alias  # file + alias
#
# The model file must already exist in /models/.
set -euo pipefail

MODEL_FILE="${1:?Usage: switch-model.sh <model-filename.gguf> [alias]}"
ALIAS="${2:-}"

if [ ! -f "/models/$MODEL_FILE" ]; then
  echo "Error: /models/$MODEL_FILE not found"
  echo "Available models:"
  ls -1 /models/
  exit 1
fi

echo "Switching to model: $MODEL_FILE"
docker compose down

export MODEL_FILE="$MODEL_FILE"
if [ -n "$ALIAS" ]; then
  export LLAMA_ARG_ALIAS="$ALIAS"
fi

docker compose up -d

echo "Waiting for server..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:8080/v1/models > /dev/null 2>&1; then
    echo "Server ready at http://rk04:8080"
    echo "   Model: ${ALIAS:-$MODEL_FILE}"
    exit 0
  fi
  sleep 1
done
echo "Server started but not yet responding. Check: docker compose logs -f"
