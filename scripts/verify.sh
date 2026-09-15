#!/usr/bin/env bash
# Check the running server end to end: unit, HTTP health, loaded model, VRAM.
#   verify.sh          status check
#   verify.sh --chat   also send one real completion through the API
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

BASE="http://127.0.0.1:6969"
CHAT=0
[[ "${1:-}" == "--chat" ]] && CHAT=1
fail=0

step "systemd unit"
if systemctl --user is-active --quiet llama-server.service; then
  ok "llama-server.service active"
else
  warn "llama-server.service is not active"
  systemctl --user --no-pager status llama-server.service 2>&1 | head -12 | sed 's/^/    /' || true
  fail=1
fi

step "HTTP endpoint $BASE"
if curl -sf --max-time 5 "$BASE/health" | grep -q '"ok"'; then
  ok "/health -> ok"
else
  warn "/health did not return ok"
  fail=1
fi

if curl -sf --max-time 5 "$BASE/v1/models" >/dev/null 2>&1; then
  model=$(curl -sf --max-time 5 "$BASE/v1/models" | jq -r '.data[0].id // empty')
  ok "serving: ${model:-unknown}"
else
  warn "/v1/models unreachable"
  fail=1
fi

if [[ -f "$HOME/.config/llama-server/model.json" ]]; then
  info "model.json: $(jq -r '.name // .model' "$HOME/.config/llama-server/model.json" 2>/dev/null)"
fi

if metrics=$(curl -sf --max-time 5 "$BASE/metrics" 2>/dev/null); then
  predicted=$(awk '/^llamacpp:tokens_predicted_total/{print $2}' <<<"$metrics" | head -1)
  info "tokens predicted this session: ${predicted:-0}"
fi

for f in /sys/class/drm/card*/device/mem_info_vram_{used,total}; do
  [[ -r "$f" ]] || continue
  v=$(cat "$f")
  case "$f" in
    *vram_used)  used=$(( v / 1073741824 )) ;;
    *vram_total) total=$(( v / 1073741824 )) ;;
  esac
done
[[ -n "${total:-}" ]] && ok "GPU VRAM: ${used:-0} / ${total} GiB used"

if (( CHAT )); then
  step "live completion"
  reply=$(curl -sf --max-time 300 "$BASE/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"Reply with the single word: ready"}],"max_tokens":64,"temperature":0.2,"chat_template_kwargs":{"enable_thinking":false}}' \
    | jq -r '.choices[0].message.content // .choices[0].message.reasoning_content // empty' 2>/dev/null || true)
  if [[ -n "$reply" ]]; then
    ok "model replied: $(tr -d '\n' <<<"$reply" | cut -c1-120)"
    tps=$(curl -sf --max-time 5 "$BASE/metrics" \
      | awk '/^llamacpp:tokens_predicted_total/{t=$2} /^llamacpp:tokens_predicted_seconds_total/{s=$2} END{if(s>0) printf "%.1f", t/s}')
    [[ -n "${tps:-}" ]] && info "lifetime average decode: ${tps} t/s (a fresh run reads higher)"
  else
    warn "no reply from the API"
    fail=1
  fi
fi

say ""
if (( fail )); then
  warn "verification found problems - see the WARN lines and README Troubleshooting"
  exit 1
fi
ok "server verified"
