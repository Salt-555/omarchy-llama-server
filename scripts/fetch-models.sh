#!/usr/bin/env bash
# Fetch (or verify) the three GGUF files the server needs, ~90 GiB total.
#
# Sources, in order of preference:
#   1. --from-dir DIR   copy + verify from a local path (USB drive, network mount)
#   2. hf / huggingface-cli   resumable, hash-checked download
#   3. curl             resumable download, no extra packages
#
# Every file is checked against the sha256 published in the Hugging Face LFS
# metadata (see scripts/models.tsv). Verified files are recorded in
# $MODELS_DIR/.verified so re-runs skip the (slow) re-hash.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

MODELS_DIR="${LLAMA_MODELS_DIR:-$HOME/models/qwen3.8-flash-next-rocmfp4}"
FROM_DIR="${FROM_DIR:-}"
FORCE="${FORCE:-0}"
MANIFEST="$SCRIPT_DIR/models.tsv"
MARKER="$MODELS_DIR/.verified"

HUB="https://huggingface.co"

usage() { sed -n '2,10p' "$0" | sed 's/^# \?//'; }

step "Model files -> $MODELS_DIR"
[[ -f "$MANIFEST" ]] || die "manifest missing: $MANIFEST"
run mkdir -p "$MODELS_DIR"
[[ "$DRY_RUN" == "1" ]] || touch "$MARKER"

say "  3 files, 90.2 GiB total:"
awk -F'\t' '$1 !~ /^#/ {printf "    %-46s %6.2f GiB\n", $5, $4/1073741824}' "$MANIFEST"

total_bytes=$(awk -F'\t' '{s+=$4} END{print s}' "$MANIFEST")
free_kib=$(df -k --output=avail "$MODELS_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$free_kib" ]] && (( free_kib * 1024 < total_bytes )); then
  warn "only $(( free_kib / 1048576 )) GiB free in $MODELS_DIR, need ~$(( total_bytes / 1073741824 )) GiB"
fi

is_marked() { [[ "$DRY_RUN" == "1" ]] && return 1; grep -qxF "$1  $2" "$MARKER" 2>/dev/null; }
mark()      { [[ "$DRY_RUN" == "1" ]] && return 0; printf '%s  %s\n' "$1" "$2" >> "$MARKER"; }

check_file() {  # dest sha size -> 0 ok
  local dest="$1" sha="$2" size="$3" actual
  [[ -f "$dest" ]] || return 1
  actual=$(stat -c %s "$dest")
  (( actual == size )) || { warn "size mismatch: $dest is $actual bytes, expected $size"; return 1; }
  info "hashing $(basename "$dest") (90 GB takes a few minutes)"
  actual=$(sha256sum "$dest" | awk '{print $1}')
  [[ "$actual" == "$sha" ]] || { warn "sha256 mismatch: $dest"; return 1; }
  return 0
}

hf_cli=""
if have hf; then hf_cli="hf"; elif have huggingface-cli; then hf_cli="huggingface-cli"; fi
if [[ -n "$hf_cli" && -z "$FROM_DIR" ]]; then
  info "downloader: $hf_cli (resumable)"
elif [[ -z "$FROM_DIR" ]]; then
  info "downloader: curl (resumable); install python-huggingface-hub for the hf CLI"
fi

failed=0
while IFS=$'\t' read -r repo rfile sha size flat; do
  [[ -z "${repo:-}" || "$repo" == \#* ]] && continue
  dest="$MODELS_DIR/$flat"

  if [[ "$FORCE" != "1" ]] && is_marked "$sha" "$flat"; then
    ok "$flat (already verified)"
    continue
  fi
  if [[ "$FORCE" != "1" && -f "$dest" ]] && check_file "$dest" "$sha" "$size"; then
    mark "$sha" "$flat"
    ok "$flat (verified)"
    continue
  fi

  say ""
  say "  --> $flat  ($(awk -v s="$size" 'BEGIN{printf "%.2f", s/1073741824}') GiB)"

  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would fetch $repo :: $rfile"
    continue
  fi

  if [[ -n "$FROM_DIR" ]]; then
    src=""
    for cand in "$FROM_DIR/$flat" "$FROM_DIR/$rfile" "$FROM_DIR/$(basename "$rfile")"; do
      [[ -f "$cand" ]] && { src="$cand"; break; }
    done
    [[ -n "$src" ]] || { warn "not found under $FROM_DIR: $flat"; failed=1; continue; }
    info "copying from $src"
    cp -f --reflink=auto "$src" "$dest" || { warn "copy failed"; failed=1; continue; }
  elif [[ -n "$hf_cli" ]]; then
    "$hf_cli" download "$repo" "$rfile" --local-dir "$MODELS_DIR" || { failed=1; continue; }
    # hf keeps the repo-relative path (mmproj/x.gguf); flatten to one dir.
    if [[ "$flat" != "$rfile" && -f "$MODELS_DIR/$rfile" ]]; then
      mv -f "$MODELS_DIR/$rfile" "$dest"
      rmdir "$MODELS_DIR/$(dirname "$rfile")" 2>/dev/null || true
    fi
  else
    url="$HUB/$repo/resolve/main/$rfile"
    info "curl -L --continue-at - $url"
    if ! curl -fL --retry 5 --retry-delay 5 --continue-at - --progress-bar \
         --output "$dest.part" "$url"; then
      warn "download failed; re-run to resume from $dest.part"
      failed=1
      continue
    fi
    mv -f "$dest.part" "$dest"
  fi

  if check_file "$dest" "$sha" "$size"; then
    mark "$sha" "$flat"
    ok "$flat"
  else
    warn "verification failed for $flat - delete it and re-run"
    failed=1
  fi
done < "$MANIFEST"

say ""
if (( failed )); then
  die "some files did not verify"
fi
if [[ "$DRY_RUN" == "1" ]]; then
  info "dry run - nothing downloaded"
else
  ok "all model files present and verified in $MODELS_DIR"
fi
