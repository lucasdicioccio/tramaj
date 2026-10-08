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

# Numbers: an integer and a float are two types, in and out.
cat > "$TMPDIR/numbers.tmpl" <<'EOF'
{"int": $ctx.int, "float": $ctx.float, "big": $ctx.big, "same": eq($ctx.int, $ctx.float), "lit": [3, 3.0, 1e21], "text": "`$ctx.int` `$ctx.float`"}
EOF

printf '{"int": 3, "float": 3.0, "big": 9007199254740991}' > "$TMPDIR/numbers.json"
printf '{"int": 9007199254740993, "float": 3.0, "big": 1}' > "$TMPDIR/out-of-range.json"

cat > "$TMPDIR/arith.tmpl" <<'EOF'
@t=import("totals", {xs: $ctx.xs})
{"total": $t.vals.total, "mean": quotient(real($t.vals.total), real(cardinality($ctx.xs))), "half": floor-quotient($t.vals.total, 2)}
EOF

cat > "$TMPDIR/totals.tmpl" <<'EOF'
@total=sum(0, $ctx.xs)
$total
EOF

cat > "$TMPDIR/term.tmpl" <<'EOF'
@n=?("n")
{"next": sum($n, 1)}
EOF

printf '{"xs": [1, 2, 4]}' > "$TMPDIR/arith.json"

CLI=(node "$CLI_DIR/dist/tramaj-cli.js")

run() {
  echo "Running: $*"
  "$@"
}

# Legacy evaluate command (bare and explicit)
run "${CLI[@]}" "$TMPDIR/eval.tmpl" "$TMPDIR/ctx.json" | grep -q '"there are 3 item(s)"'
run "${CLI[@]}" evaluate "$TMPDIR/eval.tmpl" "$TMPDIR/ctx.json" | grep -q '"there are 3 item(s)"'

# The integer/float distinction survives the context reader and the output
# writer: 3 stays 3, 3.0 stays 3.0, and they are not equal.
OUT=$("${CLI[@]}" "$TMPDIR/numbers.tmpl" "$TMPDIR/numbers.json")
echo "numbers: $OUT"
[ "$OUT" = '{"big":9007199254740991,"float":3.0,"int":3,"lit":[3,3.0,1e+21],"same":false,"text":"3 3.0"}' ]

# An integer outside the range is refused, not rounded.
if "${CLI[@]}" "$TMPDIR/numbers.tmpl" "$TMPDIR/out-of-range.json" 2> "$TMPDIR/err.txt"; then
  echo "expected an out-of-range integer to be refused"; exit 1
fi
grep -q 'TypeMismatch' "$TMPDIR/err.txt"

# The arithmetic profile is off unless --arithmetic is given: the names are
# unbound, and the error says which flag binds them.
if "${CLI[@]}" "$TMPDIR/arith.tmpl" "$TMPDIR/arith.json" --lib "totals=$TMPDIR/totals.tmpl" 2> "$TMPDIR/err.txt"; then
  echo "expected arithmetic to be unbound without --arithmetic"; exit 1
fi
grep -q 'UnboundName' "$TMPDIR/err.txt"
grep -q -- '--arithmetic' "$TMPDIR/err.txt"

OUT=$("${CLI[@]}" evaluate --arithmetic "$TMPDIR/arith.tmpl" "$TMPDIR/arith.json" --lib "totals=$TMPDIR/totals.tmpl")
echo "arithmetic: $OUT"
[ "$OUT" = '{"half":3,"mean":2.3333333333333335,"total":7}' ]

# Over a symbol an arithmetic builtin builds a term, written in the envelope.
run "${CLI[@]}" evaluate --arithmetic --mode symbolic "$TMPDIR/term.tmpl" "$TMPDIR/arith.json" | grep -q '"$term":"sum"'

# analyze arithmetic: the names referenced free, deep over libraries
OUT=$("${CLI[@]}" analyze arithmetic "$TMPDIR/arith.tmpl" --lib "totals=$TMPDIR/totals.tmpl")
echo "analyze arithmetic: $OUT"
[ "$OUT" = '["floor-quotient","quotient","real","sum"]' ]
run "${CLI[@]}" analyze all "$TMPDIR/arith.tmpl" --lib "totals=$TMPDIR/totals.tmpl" | grep -q '"arithmetic":\["floor-quotient"'

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

echo "All CLI tests passed."
