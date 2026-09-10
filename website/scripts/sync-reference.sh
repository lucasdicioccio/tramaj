#!/usr/bin/env bash
# Regenerates website/src/reference-*.cmark from specs/*.md, so the site's
# reference pages don't need hand-copying every time a spec changes.
#
# Mirrors only the language-facing specs (reference.md, node-json.md,
# v3-symbols.md, v4-types.md). laws.md and decisions.md are dev-history
# docs, linked out to GitHub from website/src/reference.cmark instead of
# mirrored here.
#
# The four *.cmark files this writes are mechanical output, not sources of
# truth — they're gitignored (see .gitignore) and regenerated fresh each
# run, including their "last synced" date.
set -euo pipefail
cd "$(dirname "$0")/../.."  # repo root

SPECS_DIR="specs"
OUT_DIR="website/src"
GITHUB_BASE="https://github.com/lucasdicioccio/tramaj/blob/main/specs"
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

sync_one() {
  local spec_file="$1" out_name="$2" topic="$3"
  local src="$SPECS_DIR/$spec_file"
  local out="$OUT_DIR/$out_name.cmark"
  local title
  title="$(sed -n '1s/^# //p' "$src")"

  {
    echo '=base:build-info.json'
    echo '{"layout":"article"'
    echo ',"publicationStatus":"Public"'
    echo '}'
    echo
    echo '=base:preamble.json'
    printf '{"author": "Lucas DiCioccio"\n,"date": "%s"\n,"title": "%s"\n}\n' "$DATE" "$title"
    echo
    echo '=base:topic.json'
    printf '{"topics":["%s"]\n,"keywords":["reference", "spec"]\n}\n' "$topic"
    echo
    echo '=base:social.json'
    echo '{"twitter": "lucasdicioccio"'
    echo ',"linkedin": "lucasdicioccio"'
    echo ',"github": "lucasdicioccio"'
    echo ',"mastodon": "https://fosstodon.org/@lucasdicioccio"'
    echo '}'
    echo
    echo '=base:summary.cmark'
    echo "Generated from [\`specs/$spec_file\`]($GITHUB_BASE/$spec_file) — the repository is the canonical source."
    echo
    echo '=base:main-content.cmark'
    echo
    echo "*Generated from [\`specs/$spec_file\`]($GITHUB_BASE/$spec_file) — the repository is the canonical source, and may be ahead of this page.*"
    echo
    sed \
      -e 's#](reference\.md)#](/reference-language.html)#g' \
      -e 's#](node-json\.md)#](/reference-node-json.html)#g' \
      -e 's#](v3-symbols\.md)#](/reference-v3-symbols.html)#g' \
      -e 's#](v4-types\.md)#](/reference-v4-types.html)#g' \
      "$src" \
      | python3 "$(dirname "$0")/md_tables_to_html.py"
    echo
    echo '=base:main-css.tramaj-json'
    echo '{ "format": "css"'
    echo ', "contents":'
    echo '  [ "@import \"`$ctx.pathPrefix`/css/dev.css\";"'
    echo '  , "@import \"`$ctx.pathPrefix`/css/colors.css\";"'
    echo '  , "@import \"`$ctx.pathPrefix`/css/article.css\";"'
    echo '  , "@import \"`$ctx.pathPrefix`/css/navigation.css\";"'
    echo '  ]'
    echo '}'
  } > "$out"

  echo "==> wrote $out"
}

sync_one reference.md   reference-language  reference
sync_one node-json.md   reference-node-json reference
sync_one v3-symbols.md  reference-v3-symbols reference
sync_one v4-types.md    reference-v4-types  reference
