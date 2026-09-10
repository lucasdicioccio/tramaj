#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI_DIR="$REPO_ROOT/tramaj-cli"
cd "$REPO_ROOT"

# Build the CLI bundle
npx spago bundle -p tramaj-cli --platform node --outfile dist/tramaj-cli.js

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/button.tmpl" <<'EOF'
.button(action("on-click", "deploy", {}), "go")
EOF

cat > "$TMPDIR/root.tmpl" <<'EOF'
@b=import("button", {})
.div(.b(action("on-click", "save", {})), $b.rendered)
EOF

cat > "$TMPDIR/typed.tmpl" <<'EOF'
type Json = string
!type-constraint("has-default", %Json)
true
EOF

cat > "$TMPDIR/with-type.tmpl" <<'EOF'
@t=import("typed", {})
type Envelope = { payload : $t.types.Json }
true
EOF

cat > "$TMPDIR/eval.tmpl" <<'EOF'
@n=cardinality($ctx.items)
.p("there are `$n` item(s)")
EOF

printf '{"items":["a","b","c"]}' > "$TMPDIR/ctx.json"

CLI=(node "$CLI_DIR/dist/tramaj-cli.js")

run() {
  echo "Running: $*"
  "$@"
}

# Legacy evaluate command (bare and explicit)
run "${CLI[@]}" "$TMPDIR/eval.tmpl" "$TMPDIR/ctx.json" | grep -q '"there are 3 item(s)"'
run "${CLI[@]}" evaluate "$TMPDIR/eval.tmpl" "$TMPDIR/ctx.json" | grep -q '"there are 3 item(s)"'

# analyze imports
run "${CLI[@]}" analyze imports "$TMPDIR/root.tmpl" --lib "button=$TMPDIR/button.tmpl" | grep -q '"button"'

# analyze actions
run "${CLI[@]}" analyze actions "$TMPDIR/root.tmpl" --lib "button=$TMPDIR/button.tmpl" | grep -q '"save"'
run "${CLI[@]}" analyze actions "$TMPDIR/root.tmpl" --lib "button=$TMPDIR/button.tmpl" | grep -q '"deploy"'

# analyze constraints
run "${CLI[@]}" analyze constraints "$TMPDIR/with-type.tmpl" --lib "typed=$TMPDIR/typed.tmpl" | grep -q '"has-default"'

# analyze types
run "${CLI[@]}" analyze types "$TMPDIR/with-type.tmpl" --lib "typed=$TMPDIR/typed.tmpl" | grep -q '"Envelope"'
run "${CLI[@]}" analyze types "$TMPDIR/with-type.tmpl" --lib "typed=$TMPDIR/typed.tmpl" | grep -q 'typed'

# analyze all
run "${CLI[@]}" analyze all "$TMPDIR/root.tmpl" --lib "button=$TMPDIR/button.tmpl" | grep -q '"imports"'
run "${CLI[@]}" analyze all "$TMPDIR/root.tmpl" --lib "button=$TMPDIR/button.tmpl" | grep -q '"actions"'

echo "All CLI analyze tests passed."
