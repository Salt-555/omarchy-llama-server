#!/usr/bin/env bash
# One-shot installer: Qwen3.8-Flash-Next ROCmFP4 + the Omarchy llama-server
# bar widget, on a Strix Halo box running Omarchy (Arch).
#
#   ./install.sh                 build, fetch models, install, enable, start, verify
#   ./install.sh --models-only   just download + verify the GGUFs
#   ./install.sh --config-only   just install config/plugin (no build, no download)
#   ./install.sh --dry-run       print every action, change nothing
#
# See README.md for the manual route and for troubleshooting.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$REPO_DIR/scripts"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

MODELS_DIR="$HOME/models/qwen3.8-flash-next-rocmfp4"
BUILD_DIR="$HOME/CodingProjects/llamacpp-rocmfpx"
SKIP_BUILD=0
SKIP_MODELS=0
SKIP_PLUGIN=0
MODELS_ONLY=0
START=1
VERIFY=1
INSTALL_DEPS=0
ENABLE="${ENABLE:-1}"
FORCE=0
FROM_DIR=""
DRY_RUN="${DRY_RUN:-0}"

usage() {
  cat <<'EOF'
install.sh - Qwen3.8-Flash-Next ROCmFP4 + Omarchy llama-server widget

options:
  --models-dir DIR    where the GGUF files live    (default ~/models/qwen3.8-flash-next-rocmfp4)
  --build-dir DIR     where llama.cpp is built      (default ~/CodingProjects/llamacpp-rocmfpx)
  --from-dir DIR      copy the GGUFs from a local dir (USB/network mount) instead of HF
  --models-only       download + verify models, then stop
  --config-only       skip build and download; install config + plugin only
  --skip-build        do not clone/build the llama.cpp fork
  --skip-models       do not download the GGUFs
  --no-plugin         do not install the Omarchy bar widget
  --no-enable         install the widget but leave it out of the bar
  --no-start          do not enable/start the systemd unit
  --no-verify         skip the final health check
  --install-deps      sudo pacman -S --needed the build dependencies
  --force             overwrite existing model.json / presets.json / config.env
  --dry-run           print what would happen, change nothing
  -h, --help          this text
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --models-dir)   MODELS_DIR="$2"; shift 2 ;;
    --build-dir)    BUILD_DIR="$2"; shift 2 ;;
    --from-dir)     FROM_DIR="$2"; shift 2 ;;
    --models-only)  MODELS_ONLY=1; SKIP_BUILD=1; shift ;;
    --config-only)  SKIP_BUILD=1; SKIP_MODELS=1; shift ;;
    --skip-build)   SKIP_BUILD=1; shift ;;
    --skip-models)  SKIP_MODELS=1; shift ;;
    --no-plugin)    SKIP_PLUGIN=1; shift ;;
    --no-enable)    ENABLE=0; shift ;;
    --no-start)     START=0; shift ;;
    --no-verify)    VERIFY=0; shift ;;
    --install-deps) INSTALL_DEPS=1; shift ;;
    --force)        FORCE=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown option: $1 (try --help)" ;;
  esac
done

export LLAMA_MODELS_DIR="$MODELS_DIR"
export LLAMACPP_ROCMFPX_DIR="$BUILD_DIR"
export DRY_RUN INSTALL_DEPS ENABLE FORCE FROM_DIR
# Let preflight skip disk checks for whatever this run is not going to write.
export DISK_CHECK_MODELS=$(( 1 - SKIP_MODELS ))
export DISK_CHECK_BUILD=$(( 1 - SKIP_BUILD ))

say "Qwen3.8-Flash-Next ROCmFP4 + Omarchy llama-server widget"
say "  models: $MODELS_DIR"
say "  build:  $BUILD_DIR"
[[ "$DRY_RUN" == "1" ]] && say "  mode:   DRY RUN (nothing will change)"

"$SCRIPT_DIR/preflight.sh"

if [[ "$SKIP_BUILD" != "1" ]]; then
  "$SCRIPT_DIR/build-llamacpp.sh"
fi

if [[ "$SKIP_MODELS" != "1" ]]; then
  "$SCRIPT_DIR/fetch-models.sh"
fi

if (( MODELS_ONLY )); then
  say ""
  ok "done (models only)"
  exit 0
fi

"$SCRIPT_DIR/install-runtime.sh"

if [[ "$SKIP_PLUGIN" != "1" ]]; then
  "$SCRIPT_DIR/install-plugin.sh"
fi

if [[ "$START" == "1" ]]; then
  step "start the server"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would run: systemctl --user enable --now llama-server.service"
  else
    if ss -ltn 2>/dev/null | grep -q ':6969'; then
      warn "port 6969 is already in use; restarting the unit anyway"
    fi
    systemctl --user enable --now llama-server.service
    ok "llama-server.service enabled and started"
    info "first load of the 87 GiB file takes ~5 minutes (mmap from disk);"
    info "watch it with: journalctl --user -u llama-server.service -f"
  fi
fi

if [[ "$VERIFY" == "1" && "$DRY_RUN" != "1" ]]; then
  step "waiting for the server to answer (up to 10 min on a cold load)"
  deadline=$(( $(date +%s) + 600 ))
  until curl -sf --max-time 3 http://127.0.0.1:6969/health 2>/dev/null | grep -q '"ok"'; do
    if (( $(date +%s) > deadline )); then
      warn "server did not come up in 10 minutes"
      warn "check: journalctl --user -u llama-server.service -n 50"
      exit 1
    fi
    printf '  .'
    sleep 10
  done
  printf '\n'
  "$SCRIPT_DIR/verify.sh"
fi

say ""
ok "install complete"
say "  API:      http://127.0.0.1:6969/v1  (also listening on the LAN, port 6969)"
say "  widget:   click the bar icon to switch models, start, stop, restart"
say "  presets:  ~/.config/llama-server/presets.json"
say "  undo:     ./scripts/uninstall.sh"
