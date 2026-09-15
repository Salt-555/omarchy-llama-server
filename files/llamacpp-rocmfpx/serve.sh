#!/usr/bin/env bash
# llama-server for Qwen3.8-Flash-Next ROCmFP4 (qwen4exp) on Strix Halo (Vulkan).
# Lives in the llama.cpp fork checkout; the dispatcher at
# ~/.config/llama-server/serve.sh execs it.
#
# Flags mirror the Agention card setup:
#   -ngl 99 -ctk q8_0 -ctv q8_0 -fa on        quantized KV, fully VRAM-resident
#   MTP adaptive drafting (n 2..4)             the model's own MTP head
#   --mmproj ...                               f16 vision tower, lossless
# Default mmap load: staging the 88G file through the 31 GB host pool with
# --load-mode none swapped hard on the box.
#
# The MTP and mmproj flags are applied only for a Flash-Next target, so this
# build can also serve other GGUFs (plain -ngl 99 path) without edits.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/llama-server"
CONFIG_ENV="$CONFIG_DIR/config.env"
MODEL_CONF="$CONFIG_DIR/model.json"

# shellcheck source=/dev/null
[[ -f "$CONFIG_ENV" ]] && . "$CONFIG_ENV"

MODELS_DIR="${LLAMA_MODELS_DIR:-$HOME/models/qwen3.8-flash-next-rocmfp4}"
TARGET="$MODELS_DIR/Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf"
MTP="$MODELS_DIR/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST.gguf"
MMPROJ="$MODELS_DIR/mmproj-Qwen3.8-Flash-Next-f16.gguf"
BIN="$DIR/build/bin/llama-server"

# Active-model override from the widget (modelctl.sh writes model.json).
SPEC=""
if [[ -f "$MODEL_CONF" ]]; then
  cfg_model=$(jq -r '.model // empty' "$MODEL_CONF" 2>/dev/null || true)
  [[ -n "$cfg_model" && -f "$cfg_model" ]] && TARGET="$cfg_model"
  SPEC=$(jq -r '.spec // empty' "$MODEL_CONF" 2>/dev/null || true)
fi

[[ -e "$BIN" ]] || { echo "missing: $BIN (build it with scripts/build-llamacpp.sh)" >&2; exit 1; }
[[ -e "$TARGET" ]] || { echo "missing model: $TARGET" >&2; exit 1; }

ARGS=(
  -m "$TARGET"
  --alias "$(basename "$TARGET" .gguf)"
  -ngl 99 -ctk q8_0 -ctv q8_0 -fa on
  --host 0.0.0.0 --port 6969
  -c 200000 --jinja -np 1
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0
  --metrics
)

# Flash-Next extras: MTP speculative decoding + vision tower.
if [[ "${TARGET,,}" == *flash-next* ]]; then
  if [[ "$SPEC" == "mtp" && -f "$MTP" ]]; then
    ARGS+=(
      -md "$MTP"
      --spec-type draft-mtp --spec-draft-adaptive
      --spec-draft-n-min 2 --spec-draft-n-max 4
      --n-gpu-layers-draft 99
    )
  elif [[ "$SPEC" == "mtp" ]]; then
    echo "serve.sh: spec=mtp but MTP head not found at $MTP; serving without drafting" >&2
  fi
  [[ -f "$MMPROJ" ]] && ARGS+=(--mmproj "$MMPROJ")
fi

exec "$BIN" "${ARGS[@]}"
