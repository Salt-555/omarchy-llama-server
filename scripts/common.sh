#!/usr/bin/env bash
# Shared helpers for the installer steps. Source, don't execute.
[[ -n "${_OL_COMMON_SH:-}" ]] && return 0
_OL_COMMON_SH=1

DRY_RUN="${DRY_RUN:-0}"

if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
  C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_HDR=$'\033[1m'
else
  C_RST=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_HDR=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_HDR" "$*" "$C_RST"; }
ok()   { printf '  %sok%s   %s\n' "$C_OK" "$C_RST" "$*"; }
info() { printf '  %s--%s   %s\n' "$C_DIM" "$C_RST" "$*"; }
warn() { printf '  %sWARN%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
die()  { printf '  %sFAIL%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit 1; }

# run <cmd...> - honors --dry-run
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_RST" "$*"
    return 0
  fi
  "$@"
}

# need <cmd> [package] - die with the pacman line if missing
need() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 || die "missing '$cmd' - install with: sudo pacman -S --needed $pkg"
}

have() { command -v "$1" >/dev/null 2>&1; }
