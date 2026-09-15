#!/usr/bin/env bash
# Install the runtime: dispatcher, widget config, and the systemd user unit.
# Existing model.json / presets.json are preserved unless --force.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

MODELS_DIR="${LLAMA_MODELS_DIR:-$HOME/models/qwen3.8-flash-next-rocmfp4}"
BUILD_DIR="${LLAMACPP_ROCMFPX_DIR:-$HOME/CodingProjects/llamacpp-rocmfpx}"
FORCE="${FORCE:-0}"

CFG="$HOME/.config/llama-server"
MODEL_MAIN="Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf"

step "Runtime config -> $CFG"
run mkdir -p "$CFG"

if [[ -f "$CFG/config.env" && "$FORCE" != "1" ]]; then
  info "config.env exists - keeping it (delete it to re-point the paths)"
else
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would write $CFG/config.env"
  else
    cat > "$CFG/config.env" <<EOF
# Written by omarchy-llama-server/install.sh. Consumed by
# ~/.config/llama-server/serve.sh and the build's serve.sh.
LLAMA_MODELS_DIR="$MODELS_DIR"
LLAMACPP_ROCMFPX_DIR="$BUILD_DIR"
EOF
  fi
  ok "config.env -> models=$MODELS_DIR build=$BUILD_DIR"
fi

run install -m 0755 "$REPO_DIR/files/llama-server/serve.sh" "$CFG/serve.sh"
ok "dispatcher  $CFG/serve.sh"

run mkdir -p "$BUILD_DIR"
run install -m 0755 "$REPO_DIR/files/llamacpp-rocmfpx/serve.sh" "$BUILD_DIR/serve.sh"
ok "server args $BUILD_DIR/serve.sh"

if [[ -f "$CFG/model.json" && "$FORCE" != "1" ]]; then
  info "model.json exists - keeping it (the widget's current selection)"
else
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would write $CFG/model.json"
  else
    jq -n --arg m "$MODELS_DIR/$MODEL_MAIN" \
      '{model: $m, spec: "mtp", name: "Flash-Next ROCmFP4 (MTP)"}' > "$CFG/model.json"
  fi
  ok "active model -> Flash-Next ROCmFP4 (MTP)"
fi

if [[ -f "$CFG/presets.json" && "$FORCE" != "1" ]]; then
  info "presets.json exists - keeping it"
else
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would write $CFG/presets.json"
  else
    jq -n --arg m "$MODELS_DIR/$MODEL_MAIN" \
      '[{name: "Flash-Next ROCmFP4 (MTP)", model: $m, spec: "mtp"}]' > "$CFG/presets.json"
  fi
  ok "presets.json -> 1 preset"
fi

step "systemd user unit"
UNIT_DIR="$HOME/.config/systemd/user"
run mkdir -p "$UNIT_DIR"
run install -m 0644 "$REPO_DIR/files/systemd/llama-server.service" "$UNIT_DIR/llama-server.service"
if [[ "$DRY_RUN" != "1" ]]; then
  systemctl --user daemon-reload
fi
ok "llama-server.service installed"
info "start it with: systemctl --user enable --now llama-server.service"
