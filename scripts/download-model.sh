#!/usr/bin/env bash
set -euo pipefail
MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-f16.gguf"
MODEL_FILE="Qwen2.5-3B-Instruct-f16.gguf"
cd "$(dirname "$0")/.."
mkdir -p models
if [ -f "models/$MODEL_FILE" ]; then
  echo "Model already exists: models/$MODEL_FILE ($(du -h models/$MODEL_FILE | cut -f1))"
  exit 0
fi
echo "Downloading $MODEL_FILE (~6.2 GB)..."
curl -fL --retry 5 --retry-all-errors -C - -o "models/$MODEL_FILE.part" "$MODEL_URL"
mv "models/$MODEL_FILE.part" "models/$MODEL_FILE"
echo "Done: models/$MODEL_FILE"
