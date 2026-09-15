#!/usr/bin/env bash
# uninstall.sh against a sandbox HOME, with systemctl/omarchy stubbed out so
# nothing real is stopped or reshuffled.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SANDBOX="${SANDBOX:-$(mktemp -d)}"
mkdir -p "$SANDBOX"
STUB="$SANDBOX/stub"
export HOME="$SANDBOX/home"
MODELS="$SANDBOX/models"; BUILD="$SANDBOX/build"
mkdir -p "$STUB" "$MODELS" "$BUILD"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$SANDBOX"' EXIT

for c in systemctl omarchy omarchy-shell; do
  printf '#!/usr/bin/env bash\necho "STUB %s $*" >> "%s/calls.log"\nexit 0\n' "$c" "$SANDBOX" > "$STUB/$c"
  chmod +x "$STUB/$c"
done
export PATH="$STUB:$PATH"

PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

echo "== lay down an install first"
HOME="$HOME" LLAMA_MODELS_DIR="$MODELS" LLAMACPP_ROCMFPX_DIR="$BUILD" ENABLE=0 \
  "$REPO/install.sh" --config-only --no-start --no-verify >"$SANDBOX/install.log" 2>&1 \
  || { bad "install.sh --config-only failed: $(tail -3 "$SANDBOX/install.log")"; exit 1; }
ok "installed into the sandbox"

: > "$MODELS/keep-me.gguf"; : > "$BUILD/keep-me"
echo x > "$HOME/.config/llama-server/custom-presets-marker"

echo "== uninstall (no purge)"
LLAMA_MODELS_DIR="$MODELS" LLAMACPP_ROCMFPX_DIR="$BUILD" bash "$REPO/scripts/uninstall.sh" \
  >"$SANDBOX/un.log" 2>&1; RC=$?
check_gone() { [[ -e "$1" ]] && bad "$2 still exists: $1" || ok "$2 removed"; }
[[ $RC -eq 0 ]] && ok "exit 0" || bad "exit $RC: $(tail -3 "$SANDBOX/un.log")"
check_gone "$HOME/.config/llama-server" "runtime config"
check_gone "$HOME/.config/systemd/user/llama-server.service" "systemd unit"
check_gone "$HOME/.config/omarchy/plugins/salt.llama-server" "bar widget"
[[ -f "$MODELS/keep-me.gguf" ]] && ok "models kept" || bad "models were deleted without --purge"
[[ -f "$BUILD/keep-me" ]] && ok "build kept" || bad "build was deleted without --purge"
grep -q "systemctl --user disable --now llama-server.service" "$SANDBOX/calls.log" \
  && ok "service disabled before removal" || bad "service was not disabled"
grep -q "plugin disable salt.llama-server" "$SANDBOX/calls.log" \
  && ok "plugin disabled before removal" || bad "plugin was not disabled"

echo "== purge deletes models and build when confirmed"
printf 'yes\n' | LLAMA_MODELS_DIR="$MODELS" LLAMACPP_ROCMFPX_DIR="$BUILD" PURGE=1 \
  bash "$REPO/scripts/uninstall.sh" >"$SANDBOX/un2.log" 2>&1
[[ -e "$MODELS" ]] && bad "models survived --purge" || ok "models purged"
[[ -e "$BUILD" ]] && bad "build survived --purge" || ok "build purged"

echo
echo "uninstall: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
