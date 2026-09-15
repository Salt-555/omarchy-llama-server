#!/usr/bin/env bash
# fetch-models.sh: copy + verify, skip-when-verified, corruption detection,
# dry run, and the real `hf` download path (nested repo path flattening).
# The HF leg pulls two small files from the real repos, not the 87 GiB one.
#   tests/fetch-models.test.sh          (HF=0 to skip the download leg)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SANDBOX="${SANDBOX:-$(mktemp -d)}"
mkdir -p "$SANDBOX"
MR="$SANDBOX/mr"; SRC="$SANDBOX/msrc"; DEST="$SANDBOX/odel"
HF="${HF:-1}"
rm -rf "$MR" "$SRC" "$DEST"; mkdir -p "$MR/scripts" "$SRC" "$DEST"
cp "$REPO/scripts/common.sh" "$REPO/scripts/fetch-models.sh" "$MR/scripts/"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0
check() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "PASS  $1 ($3)"; PASS=$((PASS+1));
  else echo "FAIL  $1: expected [$2] got [$3]"; FAIL=$((FAIL+1)); fi
}
has() { # <label> <needle> <haystack>
  if grep -qF -- "$2" <<<"$3"; then echo "PASS  $1"; PASS=$((PASS+1));
  else echo "FAIL  $1: [$2] not in output: $(head -3 <<<"$3")"; FAIL=$((FAIL+1)); fi
}

head -c 1500000 /dev/urandom > "$SRC/big-model.gguf"
head -c 4096    /dev/urandom > "$SRC/small-mtp.gguf"
sha_big=$(sha256sum "$SRC/big-model.gguf" | awk '{print $1}')
sha_small=$(sha256sum "$SRC/small-mtp.gguf" | awk '{print $1}')
sz_big=$(stat -c %s "$SRC/big-model.gguf"); sz_small=$(stat -c %s "$SRC/small-mtp.gguf")
printf 'fake/repo\tbig-model.gguf\t%s\t%s\tbig-model.gguf\nfake/repo\tsub/small-mtp.gguf\t%s\t%s\tsmall-mtp.gguf\n' \
  "$sha_big" "$sz_big" "$sha_small" "$sz_small" > "$MR/scripts/models.tsv"
copy_run() { LLAMA_MODELS_DIR="$DEST" FROM_DIR="$SRC" bash "$MR/scripts/fetch-models.sh" 2>&1; }

echo "== copy from a local dir + verify"
OUT=$(copy_run); check "exit" "0" "$?"
has "verified summary" "all model files present and verified" "$OUT"
check "dest sha" "$sha_big" "$(sha256sum "$DEST/big-model.gguf" | awk '{print $1}')"
check "marker lines" "2" "$(wc -l < "$DEST/.verified")"

echo "== second run skips the (slow) re-hash"
OUT=$(copy_run)
check "exit" "0" "$?"
check "both skipped" "2" "$(grep -c 'already verified' <<<"$OUT")"

echo "== corrupt a verified file: size check catches it, copy repairs it"
printf 'x' >> "$DEST/big-model.gguf"
grep -v 'big-model.gguf' "$DEST/.verified" > "$DEST/.verified.tmp" && mv "$DEST/.verified.tmp" "$DEST/.verified"
OUT=$(copy_run); check "exit" "0" "$?"
has "size mismatch reported" "size mismatch" "$OUT"
check "repaired" "$sha_big" "$(sha256sum "$DEST/big-model.gguf" | awk '{print $1}')"

echo "== corrupt dest AND source: sha mismatch fails loudly"
head -c 2000000 /dev/urandom > "$SRC/big-model.gguf"
truncate -s "$sz_big" "$SRC/big-model.gguf"   # right size, wrong bytes
rm -f "$DEST/big-model.gguf" "$DEST/.verified"
OUT=$(copy_run); check "exit nonzero" "1" "$?"
has "sha reported" "sha256 mismatch" "$OUT"
has "names the file" "big-model.gguf" "$OUT"

echo "== dry run changes nothing"
rm -rf "$DEST"; mkdir -p "$DEST"
OUT=$(LLAMA_MODELS_DIR="$DEST" FROM_DIR="$SRC" DRY_RUN=1 bash "$MR/scripts/fetch-models.sh" 2>&1)
has "dry-run marker" "[dry-run]" "$OUT"
check "no files copied" "0" "$(find "$DEST" -name '*.gguf' | wc -l | tr -d ' ')"

if [[ "$HF" == "1" ]] && { command -v hf >/dev/null || command -v huggingface-cli >/dev/null; }; then
  echo "== real hf download: nested path (assets/x.png) lands flat and verifies"
  printf '%s\tassets/throughput-vs-depth.png\t757755421061f21730f8251240e429e1ed2e1f683e277f81083c81146484c582\t185136\tthroughput.png\n' \
    "agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF" > "$MR/scripts/models.tsv"
  DEST="$SANDBOX/odel-hf"; rm -rf "$DEST"
  OUT=$(LLAMA_MODELS_DIR="$DEST" bash "$MR/scripts/fetch-models.sh" 2>&1); check "exit" "0" "$?"
  check "flattened into the models dir" "$DEST" "$(dirname "$(find "$DEST" -name 'throughput.png' | head -1)")"
  check "sha verified" "757755421061f21730f8251240e429e1ed2e1f683e277f81083c81146484c582" \
        "$(sha256sum "$DEST/throughput.png" 2>/dev/null | awk '{print $1}')"
  if [[ -d "$DEST/assets" ]]; then echo "FAIL  nested assets/ dir left behind"; FAIL=$((FAIL+1));
  else echo "PASS  nested dir removed"; PASS=$((PASS+1)); fi
  OUT=$(LLAMA_MODELS_DIR="$DEST" bash "$MR/scripts/fetch-models.sh" 2>&1)
  has "second hf run skips" "already verified" "$OUT"
  rm -rf "$DEST"
else
  echo "SKIP  hf download leg (HF=0 or no hf CLI)"
fi

echo
echo "fetch-models: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
