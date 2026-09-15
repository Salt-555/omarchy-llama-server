#!/usr/bin/env bash
# Undo what install.sh did. Models and the llama.cpp build are kept unless
# --purge (that deletes ~90 GiB of GGUFs, so it asks first).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

MODELS_DIR="${LLAMA_MODELS_DIR:-$HOME/models/qwen3.8-flash-next-rocmfp4}"
BUILD_DIR="${LLAMACPP_ROCMFPX_DIR:-$HOME/CodingProjects/llamacpp-rocmfpx}"
PURGE="${PURGE:-0}"

step "service"
systemctl --user disable --now llama-server.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/llama-server.service"
systemctl --user daemon-reload 2>/dev/null || true
ok "llama-server.service removed"

step "runtime config"
rm -rf "$HOME/.config/llama-server"
ok "~/.config/llama-server removed"

step "bar widget"
if [[ -d /usr/share/omarchy ]]; then
  omarchy plugin disable salt.llama-server 2>/dev/null || true
  rm -rf "$HOME/.config/omarchy/plugins/salt.llama-server"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  ok "salt.llama-server removed from the shell"
fi

if [[ "$PURGE" == "1" ]]; then
  step "purge"
  warn "about to delete $MODELS_DIR ($(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1)) and $BUILD_DIR"
  read -r -p "  type 'yes' to continue: " a
  [[ "$a" == "yes" ]] || die "aborted"
  rm -rf "$MODELS_DIR" "$BUILD_DIR"
  ok "models and build deleted"
else
  info "kept: $MODELS_DIR"
  info "kept: $BUILD_DIR"
  info "re-run with --purge to delete those too"
fi
