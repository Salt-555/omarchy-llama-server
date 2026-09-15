#!/usr/bin/env bash
# Arg construction for the build's serve.sh and the dispatcher, using a fake
# llama-server that echoes its argv (so no 87 GiB load).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SANDBOX="${SANDBOX:-$(mktemp -d)}"
mkdir -p "$SANDBOX"
BD="$SANDBOX/build"
MD="$SANDBOX/models"
export HOME="$SANDBOX/home"
CFG="$HOME/.config/llama-server"
mkdir -p "$BD/build/bin" "$MD" "$CFG"
export LLAMA_MODELS_DIR="$MD" LLAMACPP_ROCMFPX_DIR="$BD"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$SANDBOX"' EXIT

: > "$MD/Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf"
: > "$MD/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST.gguf"
: > "$MD/mmproj-Qwen3.8-Flash-Next-f16.gguf"
: > "$MD/Tiny-Q4_K_M.gguf"
cat > "$BD/build/bin/llama-server" <<'EOF'
#!/usr/bin/env bash
echo "ARGV: $*"
EOF
chmod +x "$BD/build/bin/llama-server"
cp "$REPO/files/llamacpp-rocmfpx/serve.sh" "$BD/serve.sh" && chmod +x "$BD/serve.sh"
cp "$REPO/files/llama-server/serve.sh" "$CFG/serve.sh" && chmod +x "$CFG/serve.sh"
printf 'LLAMA_MODELS_DIR="%s"\nLLAMACPP_ROCMFPX_DIR="%s"\n' "$MD" "$BD" > "$CFG/config.env"

PASS=0; FAIL=0
has() { # <label> <needle> <haystack>
  if grep -qF -- "$2" <<<"$3"; then echo "PASS  $1"; PASS=$((PASS+1));
  else echo "FAIL  $1: [$2] not in: $3"; FAIL=$((FAIL+1)); fi
}
hasnot() {
  if grep -qF -- "$2" <<<"$3"; then echo "FAIL  $1: [$2] present in: $3"; FAIL=$((FAIL+1));
  else echo "PASS  $1"; PASS=$((PASS+1)); fi
}
model() { printf '{"model":"%s/%s","spec":"%s"}\n' "$MD" "$1" "$2" > "$CFG/model.json"; }

echo "== Flash-Next + spec mtp: drafting, vision, q8_0 KV, 200k ctx"
model Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf mtp
OUT=$(bash "$BD/serve.sh")
has "model path"        "-m $MD/Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf" "$OUT"
has "alias from name"   "--alias Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16" "$OUT"
has "MTP head"          "-md $MD/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST.gguf" "$OUT"
has "draft-mtp"         "--spec-type draft-mtp" "$OUT"
has "adaptive drafting" "--spec-draft-adaptive" "$OUT"
has "draft depth 2..4"  "--spec-draft-n-min 2 --spec-draft-n-max 4" "$OUT"
has "draft offload"     "--n-gpu-layers-draft 99" "$OUT"
has "mmproj"            "--mmproj $MD/mmproj-Qwen3.8-Flash-Next-f16.gguf" "$OUT"
has "q8_0 KV"           "-ctk q8_0 -ctv q8_0 -fa on" "$OUT"
has "full offload"      "-ngl 99" "$OUT"
has "port 6969"         "--port 6969" "$OUT"
has "context 200000"    "-c 200000" "$OUT"
has "metrics"           "--metrics" "$OUT"

echo "== Flash-Next without spec mtp: no drafting, vision still on"
model Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf ""
OUT=$(bash "$BD/serve.sh")
hasnot "no MTP head" "-md " "$OUT"
has    "mmproj kept" "--mmproj" "$OUT"

echo "== a non-Flash-Next target loses the extras"
model Tiny-Q4_K_M.gguf ""
OUT=$(bash "$BD/serve.sh")
hasnot "no MTP"      "-md " "$OUT"
hasnot "no mmproj"   "--mmproj" "$OUT"
has    "alias"       "--alias Tiny-Q4_K_M" "$OUT"
has    "still loads" "-ngl 99" "$OUT"

echo "== spec=mtp but the MTP head is gone: serve without drafting, warn"
rm -f "$MD/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST.gguf"
model Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf mtp
OUT=$(bash "$BD/serve.sh" 2>"$SANDBOX/err.txt")
has    "warns on stderr" "without drafting" "$(cat "$SANDBOX/err.txt")"
hasnot "no -md"          "-md " "$OUT"
: > "$MD/Qwen3.8-Flash-Next-MTP-ROCmFP4-FAST.gguf"

echo "== no model.json: defaults to the ROCmFP4 file"
rm -f "$CFG/model.json"
OUT=$(bash "$BD/serve.sh")
has "default model" "-m $MD/Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf" "$OUT"

echo "== dispatcher hands the active model to the build"
model Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf mtp
OUT=$(bash "$CFG/serve.sh")
has "dispatcher -> build"     "-m $MD/Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf" "$OUT"
has "dispatcher keeps mtp"    "--spec-type draft-mtp" "$OUT"

echo "== dispatcher with a missing model fails loudly"
printf '{"model":"/nope/gone.gguf"}\n' > "$CFG/model.json"
rm -f "$MD/Qwen3.8-Flash-Next-ROCmFP4-FAST-v2-ple16.gguf"
OUT=$(bash "$CFG/serve.sh" 2>&1); RC=$?
has "says what is missing" "model not found" "$OUT"
if [[ $RC -ne 0 ]]; then echo "PASS  exit code $RC"; PASS=$((PASS+1));
else echo "FAIL  exited 0"; FAIL=$((FAIL+1)); fi

echo
echo "serve-args: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
