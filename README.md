# Qwen3.8-Flash-Next ROCmFP4 + Omarchy llama-server widget

A 180 B model, fully VRAM-resident, with a bar widget to drive it.

- **Model:** `Qwen3.8-Flash-Next-ROCmFP4-FAST` (87.06 GiB, 4.23 bpw, qwen4exp +
  ROCmFPx tensor types), plus its own MTP spec-decode head and f16 vision tower.
- **Server:** `llama-server` from [LaurentZuijdwijk's
  fork](https://github.com/LaurentZuijdwijk/llama.cpp), branch
  `vulkan/qwen4exp-rocmfpx`, pinned to `5e085d123`. Vulkan backend.
  **Mainline llama.cpp cannot load this file**, and neither can LM Studio: only
  this fork can dequantize the ROCmFP4 tensors.
- **Widget:** `salt.llama-server`, an Omarchy bar widget that shows server state,
  last-run tok/s and VRAM, and switches models / starts / stops the service.

Target machine: **Ryzen AI MAX+ 395 / Radeon 8060S (Strix Halo), 128 GB unified
memory with the 96 GB VRAM carve-out, Omarchy Quattro on Arch.** On anything else
it will build, but the model will not fit in VRAM.

## Requirements

| | |
|---|---|
| GPU carve-out | 96 GB dedicated to the GPU. Verify: `cat /sys/class/drm/card*/device/mem_info_vram_total` → `103079215104` |
| Disk | ~100 GB free for the GGUFs, ~15 GB for the build |
| Packages | `base-devel cmake git curl jq vulkan-headers vulkan-icd-loader vulkan-radeon shaderc python` |
| Patience | 90 GB download, ~5 min first model load, ~10 min build on 32 cores |

## Quickstart

```bash
git clone <this repo> ~/CodingProjects/omarchy-llama-server
cd ~/CodingProjects/omarchy-llama-server
./install.sh --install-deps        # drop --install-deps if the packages are already there
```

That builds the fork, downloads and sha256-verifies the three GGUFs, installs the
dispatcher + systemd unit + bar widget, starts the server, waits for health, and
verifies a live completion.

Individual steps, if you want them separate:

```bash
./scripts/preflight.sh                    # hardware / packages / disk space
./scripts/build-llamacpp.sh               # clone + build the fork (Vulkan)
./scripts/fetch-models.sh --from-dir /mnt/usb   # or plain: ./scripts/fetch-models.sh
./scripts/install-runtime.sh              # ~/.config/llama-server + systemd unit
./scripts/install-plugin.sh               # bar widget
./scripts/verify.sh --chat                # end-to-end check
```

`./install.sh --dry-run` prints every action without changing anything.

## Where things land

| Path | What |
|---|---|
| `~/models/qwen3.8-flash-next-rocmfp4/` | the three GGUF files (`--models-dir` to move) |
| `~/CodingProjects/llamacpp-rocmfpx/` | the fork checkout, `build/bin/llama-server`, `serve.sh` (`--build-dir` to move) |
| `~/.config/llama-server/config.env` | the two paths above, consumed by both serve scripts |
| `~/.config/llama-server/serve.sh` | dispatcher the systemd unit runs |
| `~/.config/llama-server/model.json` | active model + spec (`mtp`), written by the widget |
| `~/.config/llama-server/presets.json` | the widget's model list |
| `~/.config/systemd/user/llama-server.service` | the service (uses `%h`, no hardcoded paths) |
| `~/.config/omarchy/plugins/salt.llama-server/` | the bar widget |

The service is a **user** unit. It starts with your session; add
`sudo loginctl enable-linger $USER` if you want it up before login.

## Using it

The API is OpenAI-compatible on port 6969, and it binds `0.0.0.0` so other
machines on your LAN can use it too. Change `--host` in
`~/CodingProjects/llamacpp-rocmfpx/serve.sh` if you want it local-only.

```bash
curl -s http://127.0.0.1:6969/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"What is in this picture?"}],
       "max_tokens":512}' 
```

- **Thinking model.** Tokens land in `reasoning_content`; add `/no_think` to the
  prompt (or raise `max_tokens`) if replies look empty.
- **Sampling** (from the model card): thinking `temp 1.0 / top_p 0.95 / top_k 20`;
  instruct `0.7 / 0.80 / 20`.
- **Vision** works on the same endpoint: attach an image as an OpenAI
  `image_url` content part.
- **MTP drafting** is on (adaptive, 2–4), so generation is 22–40 tok/s depending
  on how well the draft head guesses.
- **Context** is 200000 (262144 native). q8_0 KV keeps that at ~3.2 GiB.

Bar widget: click for the panel. Start / Restart / Stop, and a searchable model
dropdown. Right-click forces a refresh. The bar label shows last completed run's
tok/s, or `llm ✕` when the server is down.

## Verifying

```bash
systemctl --user status llama-server.service
curl -s http://127.0.0.1:6969/health
cat /sys/class/drm/card*/device/mem_info_vram_used    # ~95 GiB once loaded
./scripts/verify.sh --chat
```

Cold load takes about 5 minutes (mmap from disk into the 96 GiB carve), during
which `/health` is not answering yet. That is normal.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `install.sh` refuses at preflight with a VRAM warning | BIOS carve-out is too small. Set dedicated/UMA graphics memory to 96 GB on this Strix Halo box, then recheck `mem_info_vram_total`. |
| Widget shows `llm ✕` right after install | Model still loading (5 min) or the service died: `journalctl --user -u llama-server.service -n 50`. |
| `missing model: ...` in the journal | GGUFs are not where `config.env` points. Re-run `./scripts/fetch-models.sh`, or edit `~/.config/llama-server/config.env`. |
| `cannot dequantize ROCmFP4 tensor` or a load failure | You are running a mainline `llama-server`. The fork's binary is required: `./scripts/build-llamacpp.sh --force`. |
| Build stops on Vulkan shaders | `sudo pacman -S --needed shaderc vulkan-headers vulkan-icd-loader vulkan-radeon`. |
| Download died at 60 GB | Just re-run it. Both the `hf` CLI and the curl fallback resume; the file is sha256-checked before it counts. |
| Port 6969 busy | Something else (an old llama-server, LM Studio) owns it: `ss -ltnp \| grep 6969`. |
| Out of memory / swap thrash while the model loads | Don't run another GPU-heavy job (ComfyUI, another LLM) at the same time. The 87 GiB file plus its KV cache wants the whole carve. |
| Widget missing from the bar | `omarchy plugin enable salt.llama-server` then `omarchy-shell shell rescanPlugins`. Panel edits need `omarchy restart shell`. |

## Uninstall

```bash
./scripts/uninstall.sh            # removes service, config, widget; keeps models + build
./scripts/uninstall.sh --purge    # also deletes the ~90 GiB of GGUFs and the build
```

## Tests

```bash
tests/run-all.sh          # HF=0 to skip the one test that touches the network
```

Five groups, all sandboxed (temp HOME, stubbed `systemctl`/`omarchy`, a fake
llama-server that echoes its argv and a fake metrics endpoint). Nothing in them
touches a real install, the real service, or the running shell.

| group | what it proves |
|---|---|
| `static` | bash syntax, exec bits, manifest schema, plugin id/paths agree across files, no absolute home paths, `omarchy plugin validate`, `qmllint` against the shell imports |
| `monitor-state` | the widget's tok/s state machine: down, first poll, generating, run boundary, restart with no cross-session arithmetic |
| `serve-args` | the exact argv for Flash-Next with/without MTP, a non-Flash-Next fallback, a missing MTP head, and the dispatcher's hand-off |
| `fetch-models` | copy + sha256 verify, skip-when-verified, size/sha corruption caught, dry run, real `hf` download with nested-path flattening |
| `uninstall` | service disabled first, config/unit/widget gone, models and build kept unless `--purge` |


## Notes

- The widget id stays `salt.llama-server` (it is Salt's plugin). Harmless: the id
  only has to be unique and outside the reserved `omarchy.*` namespace.
- Only one build is installed. The dispatcher hands every target to this fork, so
  other GGUFs will also serve; the MTP and vision flags are applied only for a
  Flash-Next target, and only `spec: mtp` presets get drafting.
- Licenses: llama.cpp is MIT; the model weights are
  [qwen-community-1.0](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF).
  This repo never redistributes weights, it downloads them from Hugging Face.
