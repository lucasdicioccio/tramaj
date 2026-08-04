#!/usr/bin/env bash
# Builds the playground bundle and serves dist/ on http://localhost:8099.
#
#   ./serve.sh            build once, then serve
#   ./serve.sh --watch    rebuild on .purs changes (poll), then serve
#   PORT=9000 ./serve.sh  serve somewhere else
#
# Rebuilding needs a reload in the browser — there is no live-reload here.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8099}"
WATCH=0
[ "${1:-}" = "--watch" ] && WATCH=1

# `spago bundle` reads module/platform/type/outfile from this package's
# `bundle:` block in spago.yaml, so they aren't repeated here. -p is
# needed because the workspace root has several packages.
bundle() {
  echo "==> bundling ($(date +%H:%M:%S))..."
  if spago bundle -p templating-playground; then
    echo "==> ok"
  else
    echo "==> BUILD FAILED, keeping previous dist/app.js" >&2
  fi
}

bundle

if [ "$WATCH" = 1 ]; then
  # No native spago --watch, and inotify isn't a given, so poll mtimes
  # against the bundle we just wrote. Watches the sibling library sources
  # too, since editing those is the usual reason to have the playground
  # open in the first place.
  (
    while true; do
      sleep 1
      if [ -n "$(find src ../templating/src ../templating-halogen/src \
                   -name '*.purs' -newer dist/app.js 2>/dev/null)" ]; then
        bundle
      fi
    done
  ) &
  WATCHER=$!
  trap 'kill "$WATCHER" 2>/dev/null || true' EXIT
fi

echo "==> serving http://localhost:${PORT}/ (Ctrl-C to stop)"
exec python3 -m http.server "$PORT" -d dist
