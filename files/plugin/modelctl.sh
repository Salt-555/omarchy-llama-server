#!/usr/bin/env bash
# Manage the llama.cpp server (port 6969) active model + presets.
# Backs the omarchy salt.llama-server widget. Reads/writes
#   ~/.config/llama-server/presets.json   (list of {name, model, spec?})
#   ~/.config/llama-server/model.json     (active {model, spec?, name?}; name
#                                          records the chosen preset's name)
#
#   modelctl.sh presets              -> name<TAB>path<TAB>spec (spec empty if none)
#   modelctl.sh current              -> print active model path
#   modelctl.sh resolve-spec <sel>   -> dflash|mtp|(empty) for a name or path
#   modelctl.sh set <name|path>      -> write active model + spec (+name) to model.json
#   modelctl.sh add <path> [name]    -> append a preset (dedupes by model path)
#
# This file is the ONLY place the spec rule lives; serve.sh consumes whatever
# spec value lands in model.json (it accepts legacy DFlash2/MTP spellings too).
set -u

CFG_DIR="$HOME/.config/llama-server"
PRESETS="$CFG_DIR/presets.json"
MODEL="$CFG_DIR/model.json"

ensure_config() {
  mkdir -p "$CFG_DIR"
  [[ -f "$PRESETS" ]] || echo '[]' > "$PRESETS"
  [[ -f "$MODEL" ]]   || echo '{}'  > "$MODEL"
}

spec_for() {
  # spec_for <model-path> -> dflash|mtp|(empty). Last-resort filename guess,
  # used only when the preset names no spec of its own.
  local p="${1,,}"
  case "$p" in
    *dflash2*)     echo "dflash" ;;
    *qwen3.8-27b*) echo "dflash" ;;
    *rocmfp4*)     echo "mtp" ;;
    *)             echo "" ;;
  esac
}

resolve_spec() {
  # resolve_spec <name|path> -> the preset's own spec wins; else filename guess.
  local sel="$1" spec=""
  spec=$(jq -r --arg n "$sel" \
    '.[] | select(.name == $n or .model == $n) | (.spec // "")' "$PRESETS" 2>/dev/null \
    | head -1 | tr '[:upper:]' '[:lower:]')
  case "$spec" in
    dflash|*dflash2*) echo dflash; return ;;
    mtp)                      echo mtp;    return ;;
  esac
  spec_for "$sel"
}

case "${1:-}" in
  presets)
    ensure_config
    jq -r '.[] | [.name, .model, (.spec // "")] | @tsv' "$PRESETS" 2>/dev/null
    ;;
  current)
    ensure_config
    m=$(jq -r '.model // empty' "$MODEL" 2>/dev/null || true)
    if [[ -z "$m" || ! -f "$m" ]]; then
      # fall back to the first preset with an existing file
      m=$(jq -r '.[] | select(.model != null) | .model' "$PRESETS" 2>/dev/null | while read -r p; do [[ -f "$p" ]] && { echo "$p"; break; }; done)
    fi
    echo "$m"
    ;;
  set)
    ensure_config
    sel="${2:-}"
    [[ -n "$sel" ]] || { echo "usage: modelctl.sh set <name|path>" >&2; exit 1; }
    resolved=""
    if [[ -f "$sel" ]]; then
      resolved="$sel"
    else
      resolved=$(jq -r --arg n "$sel" '.[] | select(.name == $n) | .model' "$PRESETS" 2>/dev/null | head -1)
    fi
    if [[ -z "$resolved" || ! -f "$resolved" ]]; then
      echo "model not found: $sel" >&2; exit 1
    fi
    # The selection (preset name when given) carries the intent; the path alone
    # cannot tell a dflash preset from an mtp one of the same model.
    spec=$(resolve_spec "$sel")
    # Record the preset name too so the UI can round-trip the selection even
    # when two presets share one path with different specs.
    name=$(jq -r --arg n "$sel" '.[] | select(.name == $n) | .name' "$PRESETS" 2>/dev/null | head -1)
    jq -n --arg m "$resolved" --arg s "$spec" --arg n "$name" \
      '{model: $m, spec: $s} + (if $n != "" then {name: $n} else {} end)' > "$MODEL"
    echo "$resolved"
    ;;
  resolve-spec)
    ensure_config
    resolve_spec "${2:-}"
    ;;
  add)
    ensure_config
    path="${2:-}"
    name="${3:-}"
    [[ -f "$path" ]] || { echo "model file not found: $path" >&2; exit 1; }
    [[ -n "$name" ]] || name="$(basename "$path" .gguf)"
    spec=$(spec_for "$path")
    # dedupe by model path
    if jq -e --arg p "$path" 'any(.[]; .model == $p)' "$PRESETS" >/dev/null 2>&1; then
      jq --arg n "$name" --arg p "$path" --arg s "$spec" \
        'map(if .model == $p then .name = $n | .spec = $s else . end)' "$PRESETS" > "$PRESETS.tmp" && mv "$PRESETS.tmp" "$PRESETS"
    else
      jq --arg n "$name" --arg p "$path" --arg s "$spec" \
        '. + [{name: $n, model: $p, spec: $s}]' "$PRESETS" > "$PRESETS.tmp" && mv "$PRESETS.tmp" "$PRESETS"
    fi
    echo "added: $name -> $path (spec: ${spec:-none})"
    ;;
  *)
    echo "usage: modelctl.sh {presets|current|set <name|path>|add <path> [name]}" >&2
    exit 1
    ;;
esac
