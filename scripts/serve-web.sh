#!/usr/bin/env bash
# Build (optional) + serve the Flutter web app for headless browser testing.
# Usage:
#   scripts/serve-web.sh          # serve existing mobile/build/web on :8091
#   scripts/serve-web.sh --build  # rebuild first, then serve
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--build" ]]; then
  ( cd "$ROOT/mobile" && /c/flutter/bin/flutter build web )
fi
cd "$ROOT/mobile/build/web"
echo "Serving Flutter web at http://localhost:8091  (Ctrl+C to stop)"
exec python -m http.server 8091 --bind 127.0.0.1
