#!/bin/sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/script/build-modern.sh"
APP="$ROOT/build/Release/ClipMenuNeo.app"
BIN="$APP/Contents/MacOS/ClipMenuNeo"
echo "==> Running filter E2E (--self-test-filter)"
set +e
OUT="$("$BIN" --self-test-filter 2>&1)"
CODE=$?
set -e
echo "$OUT" | tail -40
echo "$OUT" | grep -q '\[E2E\] PASSED' || {
  echo "E2E FAILED (exit=$CODE)"
  exit 1
}
echo "E2E OK"
