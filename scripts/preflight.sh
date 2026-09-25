#!/usr/bin/env bash
# Preflight: is this the right machine, right OS, right packages, right room?
# Warns on anything that will still build but not run well; fails on blockers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

MODELS_DIR="${LLAMA_MODELS_DIR:-$HOME/models/qwen3.8-flash-next-rocmfp4}"
BUILD_DIR="${LLAMACPP_ROCMFPX_DIR:-$HOME/CodingProjects/llamacpp-rocmfpx}"
INSTALL_DEPS="${INSTALL_DEPS:-0}"
FAILED=0

step "OS"
if [[ -f /etc/arch-release ]]; then
  ok "Arch Linux"
else
  warn "not Arch Linux - this package assumes Omarchy (Arch); steps may need adapting"
fi
if [[ -d /usr/share/omarchy ]]; then
  ok "Omarchy present ($(cat /usr/share/omarchy/version 2>/dev/null || echo 'version unknown'))"
else
  warn "no /usr/share/omarchy - the bar widget needs Omarchy Quattro"
fi

step "Hardware"
# GPU carve-out: the 87 GiB model only stays VRAM-resident on a big carve.
vram_total=0
for f in /sys/class/drm/card*/device/mem_info_vram_total; do
  [[ -r "$f" ]] || continue
  v="$(cat "$f" 2>/dev/null || echo 0)"
  (( v > vram_total )) && vram_total="$v"
done
if (( vram_total == 0 )); then
  warn "could not read mem_info_vram_total (amdgpu not loaded?)"
else
  gib=$(( vram_total / 1073741824 ))
  if (( gib >= 90 )); then
    ok "GPU VRAM carve-out: ${gib} GiB"
  else
    warn "GPU VRAM carve-out is only ${gib} GiB; the model needs ~90 GiB."
    warn "Set the UMA / dedicated graphics memory to 96 GB in BIOS on this Strix Halo box."
    # A small carve-out plus 'enable --now' means llama-server demands ~88 GiB of
    # VRAM at every login and the Restart=on-failure loop can take the desktop
    # down with it. Refuse instead of bricking the machine.
    if [[ "${ALLOW_SMALL_VRAM:-0}" == "1" ]]; then
      warn "ALLOW_SMALL_VRAM=1 set - continuing anyway; do NOT enable llama-server.service on this machine"
    else
      FAILED=1
    fi
  fi
fi
ram_gib=$(awk '/^MemTotal:/{printf "%d", $2/1048576}' /proc/meminfo)
ok "host RAM visible to the OS: ${ram_gib} GiB (the rest is carved to the GPU)"

step "Packages"
if [[ "$INSTALL_DEPS" == "1" ]]; then
  say "  installing build dependencies (sudo)..."
  run sudo pacman -S --needed --noconfirm \
    base-devel cmake git curl jq \
    vulkan-headers vulkan-icd-loader vulkan-radeon shaderc python
fi

missing=()
have cmake    || missing+=("cmake")
have g++      || missing+=("base-devel")
have git      || missing+=("git")
have curl     || missing+=("curl")
have jq       || missing+=("jq")
have glslc    || missing+=("shaderc")
have python3  || missing+=("python")
if (( ${#missing[@]} )); then
  for m in "${missing[@]}"; do warn "missing: $m"; done
  die "install them with: sudo pacman -S --needed base-devel cmake git curl jq vulkan-headers vulkan-icd-loader vulkan-radeon shaderc python"
else
  ok "build tools + Vulkan present"
fi
if have vulkaninfo && vulkaninfo --summary 2>/dev/null | grep -qi 'radv\|AMD'; then
  ok "Vulkan device visible to RADV"
else
  warn "vulkaninfo did not report an AMD device - check vulkan-radeon / mesa"
fi

step "Disk"
need_dir_space() {  # path needed_gib label
  local dir="$1" need="$2" label="$3" have_gib
  mkdir -p "$dir" 2>/dev/null || true
  have_gib=$(df -BG --output=avail "$dir" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [[ -z "$have_gib" ]]; then warn "$label: could not stat $dir"; return; fi
  if (( have_gib >= need )); then
    ok "$label: ${have_gib} GiB free in $dir"
  else
    warn "$label: only ${have_gib} GiB free in $dir, want ${need} GiB"
    FAILED=1
  fi
}
if [[ "${DISK_CHECK_MODELS:-1}" == "1" ]]; then
  need_dir_space "$MODELS_DIR" 95 "models (90 GiB of GGUFs)"
else
  info "models disk check skipped (not downloading this run)"
fi
if [[ "${DISK_CHECK_BUILD:-1}" == "1" ]]; then
  need_dir_space "$BUILD_DIR"  15 "llama.cpp build"
else
  info "build disk check skipped (not building this run)"
fi

step "Existing server"
if [[ -f "$HOME/.config/llama-server/model.json" ]]; then
  info "an existing ~/.config/llama-server was found; install.sh keeps your presets unless --force"
fi
if ss -ltnp 2>/dev/null | grep -q ':6969'; then
  info "something is already listening on 6969 (the installer will not start a second one)"
fi

if (( FAILED )); then
  die "preflight found blockers - fix the WARN lines above"
fi
say ""
ok "preflight passed"
