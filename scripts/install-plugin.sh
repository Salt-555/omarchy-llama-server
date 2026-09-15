#!/usr/bin/env bash
# Install the Omarchy bar widget: copy the plugin, validate it, enable it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

PLUGIN_ID="salt.llama-server"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
ENABLE="${ENABLE:-1}"

step "Omarchy plugin -> $DEST"
if [[ ! -d /usr/share/omarchy ]]; then
  warn "Omarchy not installed - skipping the bar widget (the server still works)"
  exit 0
fi

run mkdir -p "$DEST"
for f in "$REPO_DIR"/files/plugin/*; do
  run install -m 0644 "$f" "$DEST/$(basename "$f")"
done
run chmod 0755 "$DEST/monitor.sh" "$DEST/modelctl.sh"
if [[ "$DRY_RUN" == "1" ]]; then
  info "would copy $(ls "$REPO_DIR/files/plugin" | wc -l) files"
else
  ok "copied $(ls "$REPO_DIR/files/plugin" | wc -l) files"
fi

if [[ "$DRY_RUN" != "1" ]]; then
  if omarchy plugin validate "$DEST" >/dev/null 2>&1; then
    ok "manifest validates"
  else
    omarchy plugin validate "$DEST" || true
    die "plugin validation failed"
  fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would run: omarchy-shell shell rescanPlugins"
elif omarchy-shell shell rescanPlugins >/dev/null 2>&1; then
  ok "shell registry rescanned"
else
  warn "omarchy-shell not reachable (shell not running?) - restart the shell to pick the widget up"
fi

if [[ "$ENABLE" == "1" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would run: omarchy plugin enable $PLUGIN_ID --section right --index 0"
    exit 0
  fi
  # --index 0 pins the slot so re-running the installer is a no-op instead of
  # shuffling the bar; `omarchy bar move` is the way to reposition it later.
  if omarchy plugin enable "$PLUGIN_ID" --section right --index 0; then
    ok "enabled in the bar's right section, first slot"
    info "move it with: omarchy bar move $PLUGIN_ID"
  else
    warn "could not enable it automatically (needs a running shell)"
    info "once the shell is up: omarchy plugin enable $PLUGIN_ID --section right --index 0"
  fi
else
  info "installed but not enabled (run: omarchy plugin enable $PLUGIN_ID --section right --index 0)"
fi
