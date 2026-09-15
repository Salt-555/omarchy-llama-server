#!/usr/bin/env bash
# Clone + build the llama.cpp fork that can dequantize ROCmFP4 tensors.
# Mainline llama.cpp cannot load this file (see README); the fork is required.
# Idempotent: a build already at the pinned commit is left alone unless --force.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

REPO_URL="${LLAMACPP_REPO:-https://github.com/LaurentZuijdwijk/llama.cpp}"
BRANCH="${LLAMACPP_BRANCH:-vulkan/qwen4exp-rocmfpx}"
COMMIT="${LLAMACPP_COMMIT:-5e085d123eead2e89b5c19f824fccb05727da6a2}"
BUILD_DIR="${LLAMACPP_ROCMFPX_DIR:-$HOME/CodingProjects/llamacpp-rocmfpx}"
FORCE="${FORCE:-0}"
JOBS="${JOBS:-$(nproc)}"

bin="$BUILD_DIR/build/bin/llama-server"

step "llama.cpp fork (Vulkan, qwen4exp + ROCmFPx)"
info "repo   $REPO_URL"
info "branch $BRANCH"
info "commit ${COMMIT:0:9}"
info "dir    $BUILD_DIR"

if [[ "$FORCE" != "1" && -x "$bin" ]]; then
  if "$bin" --version 2>/dev/null | grep -q "${COMMIT:0:9}"; then
    ok "already built at ${COMMIT:0:9} - nothing to do"
    exit 0
  fi
  info "existing build is at a different commit; rebuilding"
fi

need git git
need cmake cmake
need g++ base-devel
need glslc shaderc

if [[ ! -d "$BUILD_DIR/.git" ]]; then
  if [[ -d "$BUILD_DIR" && -n "$(ls -A "$BUILD_DIR" 2>/dev/null)" ]]; then
    die "$BUILD_DIR exists, is not a git checkout, and is not empty - move it aside or pass --build-dir"
  fi
  run git clone --single-branch --branch "$BRANCH" "$REPO_URL" "$BUILD_DIR"
else
  run git -C "$BUILD_DIR" fetch --quiet origin "$BRANCH"
fi

if [[ "$DRY_RUN" != "1" ]]; then
  if ! git -C "$BUILD_DIR" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
    git -C "$BUILD_DIR" fetch --quiet origin "$COMMIT" || die "cannot fetch $COMMIT"
  fi
  git -C "$BUILD_DIR" checkout --quiet "$COMMIT" || die "cannot check out $COMMIT"
  ok "checked out $(git -C "$BUILD_DIR" rev-parse --short HEAD)"
fi

info "configuring (Release, Vulkan, no CUDA/HIP)"
run cmake -B "$BUILD_DIR/build" -S "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_VULKAN=ON -DGGML_VULKAN_SHADERS=ON \
  -DGGML_CUDA=OFF -DGGML_HIP=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++

info "compiling llama-server + llama-cli with -j$JOBS (a while on first run)"
run cmake --build "$BUILD_DIR/build" -j "$JOBS" --target llama-server llama-cli

if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would verify $bin --version"
  exit 0
fi

[[ -x "$bin" ]] || die "build finished but $bin is missing"
"$bin" --version | head -3 | sed 's/^/  /'
ok "llama-server built"
