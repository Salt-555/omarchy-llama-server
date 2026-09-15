#!/usr/bin/env bash
# Dispatcher for the llama-server control plane (port 6969).
# Run by the llama-server.service user unit. Reads the active model from
# ~/.config/llama-server/model.json and hands off to the llama.cpp build that
# can serve it. On this box that is one build: the LaurentZuijdwijk fork with
# the ROCmFPx quant types (Qwen3.8-Flash-Next ROCmFP4).
#
# Paths come from ~/.config/llama-server/config.env (written by install.sh):
#   LLAMA_MODELS_DIR        where the GGUF files live
#   LLAMACPP_ROCMFPX_DIR    the llama.cpp fork checkout + build
# Both have sane defaults if that file is missing.
#
# The widget calls `systemctl --user restart llama-server.service` after a
# model switch; modelctl.sh has already written the new path to model.json.
set -euo pipefail

CONFIG_DIR="$HOME/.config/llama-server"
MODEL_CONF="$CONFIG_DIR/model.json"
CONFIG_ENV="$CONFIG_DIR/config.env"

# shellcheck source=/dev/null
[[ -f "$CONFIG_ENV" ]] && . "$CONFIG_ENV"

MODELS_DIR="${LLAMA_MODELS_DIR:-$HOME/models/qwen3.8-flash-next-rocmfp4}"
BUILD_DIR="${LLAMACPP_ROCMFPX_DIR:-$HOME/CodingProjects/llamacpp-rocmfpx}"

# Resolve the active model; fall back to the ROCmFP4 file.
TARGET=""
if [[ -f "$MODEL_CONF" ]]; then
  TARGET=$(jq -r '.model // empty' "$MODEL_CONF" 2>/dev/null || true)
fi
if [[ -z "$TARGET" || ! -f "$TARGET" ]]; then
  TARGET="$MODELS_DIR/Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf"
fi

if [[ ! -f "$TARGET" ]]; then
  echo "serve.sh: model not found: $TARGET" >&2
  echo "  run ./scripts/fetch-models.sh (or point config.env at the right dir)" >&2
  exit 1
fi

if [[ ! -x "$BUILD_DIR/serve.sh" ]]; then
  echo "serve.sh: server build missing: $BUILD_DIR/serve.sh" >&2
  echo "  run ./scripts/build-llamacpp.sh" >&2
  exit 1
fi

exec "$BUILD_DIR/serve.sh"
