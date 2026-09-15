#!/usr/bin/env bash
# Run every test. Each one works in its own sandbox HOME; nothing here touches
# a real install, a real service, or the real shell.
#   tests/run-all.sh          HF=0 to skip the Hugging Face download leg
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="$(mktemp -d)"
FAILED=""

for t in static monitor-state serve-args fetch-models uninstall; do
  echo
  echo "########## $t ##########"
  if SANDBOX="$SB/$t" bash "$HERE/$t.test.sh"; then
    echo "--> $t OK"
  else
    echo "--> $t FAILED"
    FAILED="$FAILED $t"
  fi
done

echo
if [[ -n "$FAILED" ]]; then
  echo "FAILED:$FAILED"
  exit 1
fi
echo "all test groups passed"
