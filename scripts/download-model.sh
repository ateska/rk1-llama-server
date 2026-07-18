#!/usr/bin/env bash
set -euo pipefail

MODEL_URL="https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-BF16.gguf"
MODEL_FILE="gemma-4-E2B-it-BF16.gguf"
MODEL_DIR="/models"

if [ -f "$MODEL_DIR/$MODEL_FILE" ]; then
  echo "Model already exists: $MODEL_DIR/$MODEL_FILE ($(du -h "$MODEL_DIR/$MODEL_FILE" | cut -f1))"
  exit 0
fi

echo "Downloading $MODEL_FILE (~9.3 GB) to $MODEL_DIR/ ..."
mkdir -p "$MODEL_DIR"
curl -fL --retry 5 --retry-all-errors -C - -o "$MODEL_DIR/$MODEL_FILE.part" "$MODEL_URL"
mv "$MODEL_DIR/$MODEL_FILE.part" "$MODEL_DIR/$MODEL_FILE"
chown ubuntu:ubuntu "$MODEL_DIR/$MODEL_FILE"
echo "Done: $MODEL_DIR/$MODEL_FILE"
