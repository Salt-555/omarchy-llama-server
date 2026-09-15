#!/usr/bin/env bash
# Static checks on the shipped artifacts: syntax, manifest, QML lint,
# no absolute home paths, consistency between the installer and the plugin.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SANDBOX="${SANDBOX:-$(mktemp -d)}"
mkdir -p "$SANDBOX"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

echo "== bash syntax"
for f in "$REPO"/install.sh "$REPO"/scripts/*.sh "$REPO"/files/plugin/*.sh \
         "$REPO"/files/*/serve.sh "$REPO"/tests/*.sh; do
  if bash -n "$f" 2>"$SANDBOX/err"; then ok "syntax $(realpath --relative-to="$REPO" "$f")"
  else bad "syntax $(realpath --relative-to="$REPO" "$f"): $(cat "$SANDBOX/err")"; fi
done

echo "== shipped scripts are executable"
for f in "$REPO"/install.sh "$REPO"/scripts/*.sh "$REPO"/files/plugin/monitor.sh \
         "$REPO"/files/plugin/modelctl.sh "$REPO"/files/*/serve.sh; do
  if [[ -x "$f" ]]; then ok "exec $(realpath --relative-to="$REPO" "$f")"
  else bad "exec bit missing: $(realpath --relative-to="$REPO" "$f")"; fi
done

echo "== manifest"
M="$REPO/files/plugin/manifest.json"
if jq -e '.schemaVersion == 1' "$M" >/dev/null 2>&1; then ok "schemaVersion is the number 1"
else bad "schemaVersion must be the JSON number 1"; fi
id=$(jq -r '.id' "$M")
[[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && ! [[ "$id" == omarchy.* ]] \
  && ok "id '$id' is valid and outside the reserved namespace" \
  || bad "bad plugin id: $id"
for f in $(jq -r '.entryPoints[]' "$M"); do
  [[ -f "$REPO/files/plugin/$f" ]] && ok "entry point $f exists" || bad "entry point $f missing"
done

echo "== installer and plugin agree on the id and the installed path"
PLUGIN_ID=$(awk -F'"' '/^PLUGIN_ID=/{print $2}' "$REPO/scripts/install-plugin.sh")
[[ "$PLUGIN_ID" == "$id" ]] && ok "install-plugin.sh PLUGIN_ID == manifest id ($id)" \
  || bad "install-plugin.sh PLUGIN_ID ($PLUGIN_ID) != manifest id ($id)"
QML_DIR=$(grep -o 'HOME") + "[^"]*' "$REPO/files/plugin/BarWidget.qml" | sed 's/HOME") + "//')
[[ "$QML_DIR" == "/.config/omarchy/plugins/$id" ]] \
  && ok "BarWidget.qml pluginDir matches the install path" \
  || bad "BarWidget.qml pluginDir is '$QML_DIR', installer uses '/.config/omarchy/plugins/$PLUGIN_ID'"

echo "== no absolute home paths baked into the package"
if hits=$(grep -rn "/home/[a-z]" "$REPO" --include='*.sh' --include='*.qml' --include='*.json' --include='*.service' 2>/dev/null); then
  bad "absolute home paths found:"; sed 's/^/        /' <<<"$hits"
else ok "no /home/<user> paths in shipped files"; fi

echo "== manifest model list matches the fetch manifest"
for f in $(awk -F'\t' '$1 !~ /^#/{print $5}' "$REPO/scripts/models.tsv"); do
  grep -q "$f" "$REPO/files/llamacpp-rocmfpx/serve.sh" && ok "serve.sh knows $f" \
    || bad "serve.sh does not reference $f"
done
awk -F'\t' '$1 !~ /^#/ && length($3) != 64' "$REPO/scripts/models.tsv" | grep -q . \
  && bad "models.tsv has a sha256 that is not 64 chars" \
  || ok "models.tsv shas are 64 hex chars"

echo "== omarchy plugin validate"
if [[ -x /usr/bin/omarchy-plugin-validate || -x /usr/share/omarchy/bin/omarchy-plugin-validate ]]; then
  if omarchy plugin validate "$REPO/files/plugin" >"$SANDBOX/v" 2>&1; then ok "omarchy plugin validate"
  else bad "omarchy plugin validate: $(cat "$SANDBOX/v")"; fi
else
  echo "SKIP  omarchy plugin validate not installed"
fi

echo "== qmllint against the shell imports"
if command -v qmllint >/dev/null && [[ -d /usr/share/omarchy/shell ]]; then
  for f in "$REPO"/files/plugin/*.qml; do
    if qmllint -I /usr/share/omarchy/shell "$f" >"$SANDBOX/q" 2>&1; then
      ok "qmllint $(basename "$f")"
    else
      bad "qmllint $(basename "$f"): $(head -5 "$SANDBOX/q")"
    fi
  done
else
  echo "SKIP  qmllint or /usr/share/omarchy/shell unavailable"
fi

echo
echo "static: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
