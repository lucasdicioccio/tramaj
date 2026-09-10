#!/usr/bin/env bash
# Builds the playground bundle and copies it into website/src/ so it can be
# embedded as a static page (see website/src/playground.cmark). Re-run this
# whenever the playground or the core language changes, before publishing
# the site.
#
# The three files this writes are mechanical copies, not sources of truth —
# they're gitignored (see .gitignore) and regenerated from playground/dist/
# and a fresh spago bundle each time.
set -euo pipefail
cd "$(dirname "$0")/../.."  # repo root

[ -d node_modules ] || npm install
export PATH="$PWD/node_modules/.bin:$PATH"

echo "==> bundling playground..."
# --outfile is resolved relative to the package directory (playground/), not
# the repo root, so pass a path relative to there.
spago bundle -p tramaj-playground --outfile ../website/src/tramaj-playground-app.js

cp playground/dist/index.html website/src/tramaj-playground.html
cp playground/dist/style.css website/src/tramaj-playground.css

# Kitchen-Sink places .css/.js source files under /css/ and /js/ in the
# built site (by extension), regardless of their original location.
sed -i \
  -e 's#href="style.css"#href="/css/tramaj-playground.css"#' \
  -e 's#src="app.js"#src="/js/tramaj-playground-app.js"#' \
  website/src/tramaj-playground.html

echo "==> wrote website/src/tramaj-playground.{html,css} and tramaj-playground-app.js"
