#!/usr/bin/env bash
# monitor.sh state machine, driven against a controllable fake llama-server.
# Each assertion reads ONE poll's output (every poll advances the state).
#   tests/monitor-state.test.sh        (SANDBOX=/some/dir to keep the mess)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SANDBOX="${SANDBOX:-$(mktemp -d)}"
mkdir -p "$SANDBOX"
PORT="${PORT:-6977}"

FAKE="$SANDBOX/fakestate"
MON="$SANDBOX/mon/monitor.sh"
export HOME="$SANDBOX/home"
CFG="$HOME/.config/llama-server"
mkdir -p "$FAKE" "$(dirname "$MON")" "$CFG"
printf 'ok' > "$FAKE/up"
printf '0 0\n' > "$FAKE/counters"

# monitor.sh is copied with only the BASE url swapped: the test needs
# deterministic counters and must not poll a real server on 6969.
sed "s|BASE=\"http://127.0.0.1:6969\"|BASE=\"http://127.0.0.1:$PORT\"|" \
  "$REPO/files/plugin/monitor.sh" > "$MON"
grep -q ":$PORT" "$MON" || { echo "FAIL: could not patch BASE in monitor.sh"; exit 1; }

python3 "$HERE/fake-llama-server.py" "$FAKE" "$PORT" &
SRV=$!
trap 'kill $SRV 2>/dev/null; [[ -n "${KEEP:-}" ]] || rm -rf "$SANDBOX"' EXIT
for _ in $(seq 30); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 || { echo "FAIL: fake server did not start"; exit 1; }

PASS=0; FAIL=0
check() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "PASS  $1 = $3"; PASS=$((PASS+1));
  else echo "FAIL  $1: expected [$2] got [$3]"; FAIL=$((FAIL+1)); fi
}
snap() { bash "$MON"; }
f() { awk -F= -v k="$1" '$1==k{print $2}' <<<"$SNAP"; }
counters() { printf '%s\n' "$1" > "$FAKE/counters"; }

echo "== server down: no state, nothing to report"
rm -f "$FAKE/up" "$CFG/.genstate" "$CFG/.genanchor" "$CFG/.last_tps"
SNAP=$(snap)
check "status" "down" "$(f status)"
check "activity" "idle" "$(f activity)"
check "tps_last empty" "" "$(f tps_last)"
if [[ -f "$CFG/.genstate" ]]; then echo "FAIL  state kept while down"; FAIL=$((FAIL+1));
else echo "PASS  state files dropped while down"; PASS=$((PASS+1)); fi

echo "== first poll of a session seeds baselines, reports idle"
counters "0 0"; touch "$FAKE/up"
SNAP=$(snap)
check "status" "ok" "$(f status)"
check "activity" "idle" "$(f activity)"
check "tps_last empty" "" "$(f tps_last)"
check "genstate seeded" "0 0 0" "$(cat "$CFG/.genstate")"

echo "== tokens +40 / seconds +2 -> generating, no tps yet"
counters "40 2"
SNAP=$(snap)
check "activity" "generating" "$(f activity)"
check "tps_last empty mid-run" "" "$(f tps_last)"

echo "== counters hold (run ended) -> 40/2 committed"
SNAP=$(snap)
check "activity" "idle" "$(f activity)"
check "tps_last" "20.0" "$(f tps_last)"

echo "== second run measured from the new anchor: +300 / +10"
counters "340 12"
SNAP=$(snap)
check "activity" "generating" "$(f activity)"
SNAP=$(snap)
check "tps_last" "30.0" "$(f tps_last)"

echo "== restart: counters reset, no cross-session arithmetic"
rm -f "$FAKE/up"
SNAP=$(snap)
check "status after stop" "down" "$(f status)"
counters "0 0"; touch "$FAKE/up"
SNAP=$(snap)
check "fresh session idle" "idle" "$(f activity)"
check "no stale tps" "" "$(f tps_last)"
check "anchor reseeded" "0 0" "$(cat "$CFG/.genanchor")"

echo "== model + name come from model.json, VRAM from sysfs"
printf '{"model":"/m/Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf","spec":"mtp","name":"Flash-Next ROCmFP4 (MTP)"}\n' > "$CFG/model.json"
SNAP=$(snap)
check "model" "/m/Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf" "$(f model)"
check "name" "Flash-Next ROCmFP4 (MTP)" "$(f name)"
total=$(f vram_total)
if [[ "$total" =~ ^[0-9]+$ ]]; then echo "PASS  vram_total numeric ($total)"; PASS=$((PASS+1));
else echo "FAIL  vram_total not numeric: [$total]"; FAIL=$((FAIL+1)); fi

echo
echo "monitor-state: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
