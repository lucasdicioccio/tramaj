# JSON-to-AST templating language for Halogen rendering

> **Note on provenance.** This is the design document written while the
> language was being built, preserved here largely unedited because it is the
> authoritative record of the grammar, the builtin set, and *why* each decision
> went the way it did. It is written as a running log: the early sections
> describe the language as first scoped, and later dated sections supersede
> them. Where the two disagree, the later section wins. Start from the
> [README](../README.md) for the current package layout, and read
> "Language extensions implemented 2026-07-17" onward for everything added
> after the initial design.

Status: implemented. Originally scoped 2026-07-14.

A small templating language — its own PureScript module, no specific
consumer wired up yet — that applies a template onto a JSON object and
produces an AST any Halogen app can fold into `H.ComponentHTML`. The
motivating case: UI panels that are otherwise hand-written `HH.div`/`HH.p`
PureScript, where a template would be a more concise and more data-driven
way to express the same thing.

Named inspirations: HAML for terse block-nesting syntax, `jq` for the
data-processing/mapping half, Lisp for keeping the core language small,
Markdown for approachable surface syntax.

## Scope decisions

- **Standalone module, no consumer wired up.** This ships as its own
  package/module with its own test suite (fixture JSON in, expected AST
  out). It does not touch any existing panel in a host app. A concrete
  first consumer can adopt it later once the design has proven itself —
  don't force that migration bet into this scope.
- **Action/event handling is decoupled via a string token in the
  template, parsed by the library, dispatched by the host.** A template
  can attach an arbitrary string to an element (e.g.
  `.button("Select", action: "select:$itemId")`); the library's parser
  recognizes the *syntax* (an action attribute holding a string, with the
  same `` `$var` `` interpolation used elsewhere in the template) but does
  not interpret its *meaning* — the parsed AST exposes it as an opaque
  `ActionToken Text` for the host to map onto real Halogen `Action`s via a
  lookup function the host supplies (`Text -> Maybe action`). This is
  strictly more decoupled than a fixed action vocabulary: a host that
  wants read-only rendering just supplies a mapping that always returns
  `Nothing` (no-op), while a host that wants full interactivity can wire
  every token it defines in its own template strings. The library never
  needs to know what a "select" or "navigate" action is.
- **Parser built on an existing PureScript parser-combinator library**,
  not hand-rolled recursive descent — `purescript-parsing` is the
  standard choice for this in the PureScript ecosystem. **Needs
  confirming before implementation**: it isn't in the pinned package set
  (`registry: 77.11.0`), so confirm it publishes a `spago.yaml`/`purs.json`
  compatible with whatever `spago` version this ends up building against
  before wiring it in.
- **Fixed small builtin set for the computation language, no registry.**
  `count`/`cardinality`, `map`, and a handful of others get hardcoded into
  the evaluator as the initial set — no `Text -> (Json -> Json)`
  extension mechanism. Grow the builtin list only when a real template
  needs a function that isn't there yet — a standing bias against
  designing for hypothetical future requirements.

## Shape (from the original sketch, unchanged)

```
-- computations
count=cardinality($ctx.items)

-- template
.h1("This is a template.")
.p("there are `$count` item(s)")

.table(
  .thead("title", "link")
  .tbody(
    $ctx.items.map((item) =>
      .tr(
        .td($item.title),
        .td(.a("href": $item.url)),
      )
    )
  )
)
```

Two phases, matching the two blocks above:

1. **Pre-fold/computation phase** — a small expression language
   evaluated once against the input `$ctx` JSON, binding names (`count`)
   that the template body can reference. Fixed builtins only (see above).
2. **Template phase** — HAML-like block nesting (`.tag(...)`) that
   produces the output AST. Supports backtick-interpolation of bound
   names/JSON paths (`` `$count` ``, `$item.title`) and first-class
   iteration over JSON arrays (`.map((item) => ...)`).

## Output: a generic AST, not Halogen-specific

The library's output type is a small generic node AST (tag, attributes
map — including the opaque `ActionToken` slot above, children) — not
`H.ComponentHTML` directly. A separate, thin "fold into Halogen" function
(`Node action -> H.ComponentHTML w action`, taking the host's action-token
lookup function) converts that generic AST to real Halogen output. Keeping
the two separate means the parser/evaluator core has no Halogen dependency
at all and could, in principle, fold to something else (plain HTML string,
a different UI framework) later — though no such second consumer is
planned; this split is just what naturally falls out of decoupling action
dispatch from parsing, not extra scope on its own.

## Explicitly not in this scope

- Migrating any existing hand-written panel onto this.
- An extensible builtin-function registry.
- Two-way binding / form input handling beyond the opaque action-token
  attachment described above — `HE.onValueInput`-style continuous input
  is a different problem (needs a live value, not a fire-once action) and
  isn't addressed by this design.

## Suggested first deliverable

A standalone module (new top-level directory or a package inside the host
app, TBD at implementation time) with:
1. Parser (via `purescript-parsing`, pending the package-set check above)
   for both the computation block and the template block.
2. Evaluator producing the generic `Node` AST, fixed builtin set.
3. A `foldToHalogen` conversion function taking a host action-token
   lookup.
4. A test suite: fixture JSON + template string in, expected `Node` AST
   out — no Halogen rendering required to test the core.

No specific panel adopts it yet; that's a separate future decision once
the module exists and its ergonomics can be judged against a real
candidate — a dashboard-style widget renderer being the most likely first
fit, given its repetitive per-widget table rendering.

## Detailed design (2026-07-16)

Resolves the one open blocker above and works the shape sketch into
concrete types/grammar/layout, ready to implement without further design
decisions.

### Package placement

**Own top-level package, `tramaj/`, not a directory inside a host
app.** Reasons: (1) it has no consumer yet, so folding it into a host's
`spago.yaml` would add a dependency (`parsing`, pulled in for no current
caller) to a package that ships as a real product; (2) keeping it
standalone means its own test suite runs via its own `spago test`,
isolated from the host build entirely, matching "does not touch any
existing panel" literally, not just in spirit. When a consumer adopts it,
that's the point to add `tramaj` as a path or git dependency in the
host's `spago.yaml` — not before.

`tramaj/spago.yaml`, pinned to the **same registry version as the
intended host** (`77.11.0`) so the two packages never drift onto
incompatible core-library versions if they're later linked:

```yaml
package:
  name: tramaj
  dependencies:
    - prelude
    - parsing
    - argonaut-core
    - ordered-collections
    - arrays
    - strings
    - maybe
    - either
    - transformers
    - halogen        # only for Tramaj.Halogen's foldToHalogen; the
                      # parser/evaluator modules below never import it
  test:
    main: Test.Main
    dependencies:
      - effect
      - console
workspace:
  packageSet:
    registry: 77.11.0
```

`halogen` is a dependency of the package as a whole, but confined to one
module (`Tramaj.Halogen`) — everything else (`Tramaj.Ast`,
`Tramaj.Parser`, `Tramaj.Eval`) has zero Halogen import, so the
parser/evaluator core is trivially usable outside Halogen too, per the
"could fold to something else" note above. No test framework — the suite
is a bare `Effect Unit` with manual assertions via `log`
(fixture-in/AST-out comparisons via `Eq`-derived `Node`, failing loud via
`Effect.Exception.throw` on mismatch) rather than pulling in a spec-runner
dependency.

### Module layout

```
tramaj/
  spago.yaml
  src/
    Tramaj/
      Ast.hs         -- wrong-language slip guard: these are all .purs
      Ast.purs        -- Expr, TemplateNode (unevaluated), Node (evaluated output), Json re-export
      Parser.purs     -- parseComputationBlock, parseTemplateBlock, parseProgram
      Eval.purs       -- evalProgram :: Program -> Json -> Either EvalError Node
      Halogen.purs    -- foldToHalogen
  test/
    Test/
      Main.purs
      Fixtures.purs   -- template strings + input Json + expected Node, paired
```

(The stray `Ast.hs` line above is a typo-guard note to future-me, not a
real file — delete this parenthetical when scaffolding.)

### Grammar

Two blocks, computation then template, separated by a blank line (matching
the sketch). EBNF-ish, `"literal"` for fixed tokens:

```
program        := comp-block? blank-line template-block

comp-block     := (binding newline)*
binding        := ident "=" expr

expr           := fun-call | path | string-lit | number-lit
fun-call       := ident "(" expr ("," expr)* ")"
path           := "$" ident ("." ident)*
string-lit     := '"' (char | "`" interp-ref "`")* '"'
number-lit     := digit+ ("." digit+)?
interp-ref     := "$" ident ("." ident)*

template-block := node
node           := "." ident "(" node-args? ")"
node-args      := node-arg ("," node-arg)*
node-arg       := named-arg | child-arg
named-arg      := ident ":" value
child-arg      := value | node | map-expr
value          := string-lit | path
map-expr       := path "." "map" "(" "(" ident ")" "=>" node ")"
```

Notes tightening the sketch (and correcting one internal inconsistency the
original informal sketch had — `.a("href": $item.url)` used `:` while the
scope-decision prose's `action=` example used `=`; **`:` is the one real
syntax**, used below and in the implementation):
- `path` bound by a computation-block `binding` (e.g. `count=cardinality(...)`)
  and a *bare* `$name` in the template (e.g. `` `$count` `` in
  `.p("there are `$count` item(s)")`) resolve through the **same lookup**:
  bound computation names and `$ctx`-rooted JSON paths share one namespace,
  distinguished only by whether the first segment matches a binding name or
  `ctx`. `$item` inside a `.map((item) => ...)` body is a binding scoped to
  that body only (shadows nothing at top level since `item` isn't a
  computation-phase name).
- Trailing commas are permitted in `node-args` (visible in the sketch's
  `.td($item.title), .td(.a("href": $item.url)),`) — the parser accepts and
  discards one optional trailing `,` before `)`.
- **A node's parenthesized list is heterogeneous** — `named-arg` and
  `child-arg` can appear in any order in the same list (`.button("Select",
  action: "select:$itemId")` has a `child-arg` first, `named-arg`
  second). The parser buckets each parsed `node-arg` into one of two
  output lists by which alternative matched — `named-arg`s become
  `TElement`'s attrs, `child-arg`s become its children, each list keeping
  its own relative order — rather than trying to preserve one interleaved
  list end to end. This is also why a bare `value` positional arg (e.g.
  `.td($item.title)`, `.h1("This is a template.")`) is **not** an
  attribute — it's a `child-arg`, i.e. a text child, exactly like a
  string/path used anywhere else a child is expected.
- An **action token** is just another `named-arg` with a reserved key,
  `action:`, whose value is a `value` (string-lit-with-interpolation or bare
  path) like any other attribute — no separate grammar production needed.
  `.button("Select", action: "select:$itemId")` parses as an ordinary
  node with one child-arg and one named-arg; `Eval` special-cases the
  `action` key when building `Node`'s `action` field (below) instead of
  folding it into `attrs`.

### Core types (`Tramaj.Ast`)

```purescript
-- Computation-phase expressions (unevaluated)
data Expr
  = Path (Array String)         -- ["ctx", "items"] / ["item", "title"]
  | FunCall String (Array Expr) -- cardinality($ctx.items)
  | StringLit (Array StringPart)
  | NumberLit Number

data StringPart = Lit String | Interp (Array String)  -- the `$foo.bar` pieces

-- Template-phase AST (unevaluated — still holds Expr/paths, not resolved values)
data TemplateNode
  = TElement String (Array (Tuple String Expr)) (Array TemplateNode)
    -- ^ tag, named attrs (key, value-expr), children
  | TValue Expr
    -- ^ a bare child-arg value (string-lit or path), rendered as NText
  | TMap (Array String) String TemplateNode   -- path, bound name, body
    -- ^ TMap ["ctx","items"] "item" body ≡ $ctx.items.map((item) => body)

-- Evaluated output AST — no Expr/paths left, no Halogen dependency
data Node
  = NElement
      { tag :: String
      , attrs :: Map String String   -- resolved, action excluded
      , action :: Maybe String       -- opaque ActionToken payload, resolved
      , children :: Array Node
      }
  | NText String

derive instance Eq Node
derive instance Eq TemplateNode -- etc., for test fixtures/debugging

type Program = { bindings :: Array (Tuple String Expr), root :: TemplateNode }
```

`Node`'s `action :: Maybe String` *is* the "opaque `ActionToken Text`" from
the scope decisions above — modeled as `Maybe String` rather than a
wrapper newtype since nothing in this package interprets it; the newtype
would just be ceremony. The host-side lookup function
(`String -> Maybe action`) is applied only in `Tramaj.Halogen`.

### Evaluator (`Tramaj.Eval`)

```purescript
data EvalError
  = UnboundName String
  | UnknownFunction String
  | PathNotFound (Array String)
  | TypeMismatch String        -- e.g. cardinality() on a non-array/object

evalProgram :: Json -> Program -> Either EvalError Node
```

Fixed builtin set (per scope decision — grown only on real demand):
- `cardinality` / `count` (alias) — `Json` (array or object) `-> Int`,
  stringified on interpolation.
- `map` — not a builtin *function* value; handled structurally via
  `TMap` in the template phase (it produces nodes, not a scalar/JSON
  value, so it doesn't fit the `FunCall` shape at all). Listed here only
  because the sketch's "count/cardinality, map, and a handful of others"
  phrasing could otherwise read as one flat function table.

Evaluation order: run all `comp-block` bindings once against `$ctx` in
declaration order (later bindings may reference earlier ones, not the
reverse — no forward references, no recursion, matching "small expression
language" from the scope note), producing a `Map String Json` environment;
then walk `TemplateNode` resolving every `Path`/`Interp` against
`bindings ∪ {"ctx": input}`, producing `Node`. A `TMap` walks the target
JSON array, binding the loop variable fresh per iteration in a child scope
that shadows nothing else, and concatenates each iteration's evaluated
body as a `children` list.

### Halogen fold (`Tramaj.Halogen`)

```purescript
foldToHalogen
  :: forall action slots m
   . (String -> Maybe action)
  -> Node
  -> H.ComponentHTML action slots m
```

`NText s` → `HH.text s`. `NElement` → `HH.element (HH.ElemName tag) attrs
children`, with `action` (if `Just token` and the lookup returns `Just a`)
added as an `HE.onClick \_ -> a` — click is the only event this design
wires (matches "fire-once action", explicitly not the continuous-input
case ruled out of scope). A token the host's lookup maps to `Nothing`
(including every token when the host wants read-only rendering) attaches
no handler at all.

### Test suite shape

`test/Test/Fixtures.purs` pairs `{ template :: String, ctx :: Json,
expected :: Node }` fixtures covering: a plain nested element tree, a
computation-block binding referenced via backtick-interpolation, a bare
`$path` positional/named arg, `.map` over an array producing repeated
children, and an `action:` named-arg producing `NElement`'s `action`
field. `Test.Main` parses + evals each fixture and compares against
`expected` via `Eq Node`, `throw`-ing with a diff-ish message (template
name, expected vs actual `show`) on the first mismatch — matching the
existing bare-`Effect` test style rather than introducing a spec runner.

### Suggested build order within this item

1. `Tramaj.Ast` (no logic, just types + derived `Eq`/`Show`) — nothing
   to get wrong, fastest way to get the shape reviewed.
2. `Tramaj.Parser` for `comp-block` first (smaller grammar), then
   `template-block`, tested directly against fixture strings without
   `Eval` involved yet (parser output compared via `Eq Program`/`Eq
   TemplateNode`).
3. `Tramaj.Eval` against already-parsed fixtures.
4. `Tramaj.Halogen` last — the only module depending on `halogen`, and
   the only one needing a host lookup function, which is easiest to write
   once real `Node` values from step 3 exist to test it against.

**Scaffolded 2026-07-16 — all four steps done**, in that order, in the new
`tramaj/` package. `spago build` and `spago test` both pass (5
end-to-end fixtures in `tramaj/test/`). Two corrections made against
this design during implementation, both folded back into the sections
above: (1) `TemplateAttr`/`TPositional` didn't survive contact with the
grammar — a bare positional value (`.td($item.title)`) turned out to
render as a text *child*, not an attribute, so `TemplateNode` gained a
`TValue` constructor and attrs became plain `Tuple String Expr`, named-only;
(2) `action=` (scope-decision prose) vs `action:` (formal grammar) was a
real inconsistency in the original sketch, resolved in favor of `:`
everywhere. Not done: adopting it in any real panel (deliberately out of
scope — see above).

**Playground added 2026-07-17**: a browser playground — a template
textarea and a JSON-context textarea, rendering live — as the first real
exercise of this package inside an actual host build, plus a static
language-reference block covering the primitives/grammar/builtin list
above. Still just a standalone demo, not a real panel. Later references
below to "the playground" mean this.

## Open follow-ups (not yet designed) — 2026-07-17

Recorded here since they change assumptions this design document currently
states as settled:

- **Dashboard-widget integration** needs a new "textual/template renderer"
  widget mode and a `$ctx = { items: [...] }` context shape where each
  item carries the full JSON for the thing being rendered — current values
  *and* metadata — which a summary-shaped widget entry type typically
  doesn't expose. A per-item template override, selected by a reserved
  metadata key on the item itself, is the likely mechanism. None of this
  is designed yet.
- **First-class function values.** The scope decision above ("fixed small
  builtin set... `FunCall` in `Expr`") assumed a function call always
  reduces to a `Json` scalar. Real usage wants more: a computation-block
  binding that holds a *function value* itself, values that compose with
  each other, and the result still bound to a name for reuse later in the
  same template — a genuine extension to `Expr`/`Node`, not an
  implementation detail of the current design. Not scoped; would need its
  own design pass (does it subsume `.map`'s special-cased `TMap`? does it
  strain "no extension registry" or satisfy it in a new way via
  composition of the existing fixed builtins?) before any of the
  `tramaj/` modules change.

**Added 2026-07-17, after the language extensions below landed** (kept
brief here):

- **A richer `action` value.** `Node`'s `action :: Maybe String` is a raw
  post-interpolation string today; a template can't attach real
  structure, only text a host has to parse back apart. Passing a full
  JSON object instead (`action: {"type": "select", "itemId":
  $itemId}`) would need `action` to become `Maybe Json`, which also
  changes `Tramaj.Halogen.foldToHalogen`'s host-lookup signature
  (`String -> Maybe action` → `Json -> Maybe action`) — breaking for the
  one already-shipped consumer (the playground).
- **New fixed builtins** (still "fixed set, no registry" — just growing
  the hardcoded list): conjunction/disjunction over multiple clauses
  (`and(...)`/`or(...)` or similar), a predicate function (equality/
  comparison/presence — there's no way to produce a boolean at all
  today), and object/array lookup by a *computed* key/index (today's only
  access is a static dotted `$path` segment or whole-array `.map`). None
  scoped — signatures, error behavior, and whether a predicate/lookup
  builtin implies the template block needs a conditional/branch construct
  (it has none today) all need a design pass.

## Language extensions implemented 2026-07-17

Four grammar changes landed the same day the follow-ups above were
recorded — all superseding specific pieces of the "Grammar"/"Core types"
sections earlier in this document, which describe the language as it
shipped 2026-07-16. None of these touch the "first-class function values"
follow-up above — only the fixed builtins are callable, still.

- **Three leader characters, one job each.** `.` starts an element
  (unchanged). `$` reads a bound name/`$ctx`-path — unchanged in spirit,
  but now also optionally prefixes a call (`$cardinality(...)`, see
  below). **`@` is new**: it *defines* a computation-block binding — every
  binding is now `@name=expr`, not bare `name=expr`
  (`count=cardinality(...)` from the original examples is now
  `@count=cardinality(...)`). `@`/`$` are deliberately symmetric: a
  setter and a getter for the same binding namespace.
- **Kebab-case identifiers everywhere.** `rawIdent` (used for binding
  names, path segments, node tags, bare attribute keys, and builtin call
  names) now accepts internal hyphens — `@my-var=...`, `$ctx.foo-bar`,
  `.my-tag(...)` all parse. Still must start with a letter (never a digit
  or hyphen), so there's no ambiguity with a number literal.
- **Function calls: `name(args)` and `$name(args)` are now the same
  thing.** Both spell "look up `name` in the environment (bound
  computation names ∪ the fixed builtins) and apply it" — today that
  only ever resolves to a builtin, since there's no user-bindable
  *function* value yet (see the follow-up above), so both spellings are
  currently interchangeable in practice, kept as two accepted surface
  forms rather than picking one. `Expr`'s `FunCall String (Array Expr)`
  became `Call (Array String) (Array Expr)` — an array to leave room for
  a dotted callee later, though today's evaluator rejects anything but a
  single segment (`Call ["cardinality"] [...]` — a multi-segment callee
  like `$ctx.foo(...)` is a `TypeMismatch` at eval time, not a parse
  error, since "is this callable" isn't knowable until the environment is
  resolved).
- **Quoted attribute keys.** A named-arg key can now be a bare identifier
  *or* a double-quoted string with no interpolation (`"attr-kebab-case":
  value` alongside `bare-key: value`) — mostly redundant with kebab-case
  bare idents now being legal, but quoting still covers keys `rawIdent`
  can't represent at all (spaces, etc.), and JSON-like object-literal keys
  (below) reuse the same quoted-string parser.
- **Attribute values generalized from `value := string-lit | path` to
  the full `expr`** — so `"attr-kebab-case": $cardinality($ctx.items)` (a
  call), a number, or an array/object literal are all valid attribute
  values now, not just a string or bare path.
- **Attrs-before-children is hard-enforced.** A node's argument list must
  put every named-arg before every child-arg — `.foo(.p("hi"), "bar":
  "baz")` (a child before an attr) is now a parse error, not silently
  accepted. Implemented as a post-parse check over the already-parsed
  arg list (`Tramaj.Parser.node`'s `ensureAttrsBeforeChildren`) rather
  than reshaping the `node-args` grammar production itself — simpler, and
  the error is still a real `ParseError`.
- **JSON-like array/object literals in `expr`** — `@nums=[1,2,3]` and
  `@wrapped={"items": $ctx.items}` both work now (`Expr` gained
  `ArrayLit (Array Expr)`/`ObjectLit (Array (Tuple String Expr))`);
  object-literal keys are always quoted (real-JSON convention, unlike
  attribute keys which accept either). Element/entry values are full
  `expr`, so literals can nest arbitrarily and embed `$ctx` paths/calls.
- **Backtick interpolation generalized from a bare path to a full
  `expr`** — `` `$cardinality($nums)` `` inside a string literal now
  works, not just `` `$count` ``. `StringPart`'s `Interp (Array String)`
  became `Interp Expr`.

All eight fixtures in `tramaj/test/Test/Fixtures.purs` (plus a
dedicated ordering-rejection check in `Test.Main`) cover every change
above; `spago test` passes. The playground's default example and in-app
language reference were updated to match (now use `@`-prefixed bindings).

## Predicate/lookup builtins implemented 2026-07-17

Resolves two of the three "new fixed builtins" items noted above
(conjunction/disjunction, a predicate function, and object/array
lookup) — the third (a richer
`action` value) and the still-separate "user-definable functions" gap
remain undesigned. Still "fixed set, no extension registry" — these are
hardcoded additions, not a registry mechanism.

- **A boolean literal, finally.** `Expr` gained `BoolLit Boolean`, parsed
  from the bare identifiers `true`/`false` (via `Tramaj.Parser.boolLit`,
  tried before `call` since both start with a bare identifier — `try`
  backtracks cleanly to `call` for every other name, so `truest` or a
  hypothetical builtin aren't misparsed). Without this there was no way
  to write a literal boolean at all, and no builtin produced one either
  (`cardinality`/`count` are the only prior builtins, both numeric).
- **`not(a)`** — boolean negation.
- **`and(a, b, ...)` / `or(a, b, ...)`** — variadic conjunction/
  disjunction, folding over however many arguments are given, including
  zero (`and()` is `true`, `or()` is `false` — the vacuous case,
  mathematically standard, not specially rejected).
- **`eq(a, b)`** — deep equality over arbitrary `Json`, via `Json`'s own
  `Eq` instance (`argonaut-core` already derives structural equality, so
  no custom comparison needed).
- **`lt(a, b)` / `lte(a, b)` / `gt(a, b)` / `gte(a, b)`** — numeric
  comparison; both arguments must be `Json` numbers.
- **`has(container, key)`** — a presence/absence predicate, deliberately
  *tolerant*: a missing object field, an out-of-range array index, or
  even a container/key of the wrong shape entirely all just answer
  `false` rather than raising an `EvalError`. `has` exists specifically so
  a template can test for something without already knowing it's there,
  so making it error on exactly the cases it's meant to detect would
  defeat the point.
- **`lookup(container, key, fallback)`** — the dynamic counterpart to a
  static `$path` segment (which only ever names a fixed field): looks up
  an object field by a `Json` string key or an array element by a `Json`
  (non-negative integer) index, where the key/index is itself computed
  rather than a literal path segment. Takes a **mandatory third argument**
  — the fallback returned for a missing field, an out-of-range index, or
  a wrong-shaped container/key — so `lookup`, like `has`, never errors;
  it just returns a value instead of a boolean. (First implemented
  2-argument and erroring like static path resolution does, matching
  `resolvePath`'s behavior — changed same-day to the tolerant
   3-argument form instead, so a template author isn't forced to already
  know a key exists just to look it up safely.)
- **`branch(fallback, pred1, val1, pred2, val2, ...)`** — "if `pred1`,
  `val1`; else if `pred2`, `val2`; …; else `fallback`," as one builtin
  call rather than new template-block syntax. This directly answers the
  "does a predicate/lookup builtin imply the template block needs a
  conditional/branch construct" question below — the answer landed as
  *no new template syntax*, just a builtin that lets a computation-block
  binding hold a conditionally-chosen **value** (`.map`'s the only
  templating-block-level control-flow-shaped construct, and stays that
  way). **Important limitation inherited from how every builtin call is
  evaluated**: every argument — every predicate *and* every value, taken
  or not, plus the fallback — is evaluated eagerly before `branch` ever
  runs, exactly like `lookup`'s fallback above; there is no
  short-circuiting/laziness anywhere in this language. A `val2` that would
  itself error stays fatal even if `pred1` already matched and `val2` was
  never "the answer" — every value in the chain must be safe to evaluate
  regardless of which predicate wins.

Six new fixtures cover this (boolean literal + `not`/`and`/`or`/
comparison composition, `eq`, `has`'s tolerant behavior across present/
absent/in-range/out-of-range cases, `lookup`'s fallback on both object and
array access, and `branch` both matching a predicate and falling all the
way through) — 14 fixtures total in
`tramaj/test/Test/Fixtures.purs`, `spago test` passes.

## Functional map/filter/scan + template-block branch, implemented 2026-07-17

Resolves the "possibility to introduce functions" direction from a
different angle than the still-unscoped "first-class function values"
idea: rather than general user-defined functions, three specific
array-transform primitives (`map`/`filter`/`scan`) and a template-block
`branch(...)` were added, each with a dedicated, narrow grammar shape —
not a step toward general function values (still unscoped).

- **`map(arr, (item) => expr)`, `filter(arr, (item) => pred)`,
  `scan(arr, init, (acc, item) => expr)`** — new `Expr` constructors
  (`MapExpr`/`FilterExpr`/`ScanExpr`), usable anywhere `expr` is (a
  computation-block binding, an attribute value, nested inside another
  call). None of these are ordinary `Call`s: a `Call`'s arguments are
  all eagerly evaluated to `Json` before dispatch, which can't represent
  a lambda body — each lambda-bound name only makes sense evaluated once
  per array element, with a fresh binding each time (the same shape
  `TMap`'s iteration already had). So each gets dedicated parser shapes
  (`Tramaj.Parser.specialFormExpr`), tried as a whole `identifier`
  before falling through to `call` — `mapper(...)` isn't chopped into a
  bogus `map` plus leftover `per(...)`. `scan` uses **`scanl` semantics**:
  the output array is `[init, step(init, x1), step(step(init, x1), x2),
  ...]` — one longer than the input, seed first, not `scanl1`.
  **Important limitation** shared by all three: the lambda isn't a
  general function value — it only ever appears as this literal, inline
  argument; it can't be bound to a name (`@f=(x) => ...`) and reused
  elsewhere. That remains the separate, still-unscoped "first-class
  function values" gap.
- **`map(...)` in the template block is now functional, not OOP-style.**
  `$ctx.items.map((item) => .li(...))` **no longer parses** — replaced
  by `map($ctx.items, (item) => .li(...))`, matching the expr-level form
  above but producing a `TMap` (structural — repeats a *node*, not a
  value) instead of a `MapExpr`. This is a real breaking change to
  already-shipped syntax, done deliberately per direct request ("map
  syntax in template block should be functional rather than OOP-like").
  A nice side effect: `TMap`'s array argument is now a general `Expr`
  (`Tramaj.Ast`), not just a static path — `map(filter($ctx.items,
  (x) => ...), (item) => ...)` works, which the old path-suffix syntax
  couldn't express at all (there was nothing to suffix `.map` onto a
  `filter(...)` call).
- **`branch(...)` in the template block** — `TBranch` selects exactly
  one child *node* rather than a value: `branch(fallbackNode, pred1,
  node1, pred2, node2, ...)`. This is a second, independent `branch`
  form alongside the existing expr-level `branch` builtin (same name,
  different grammar position, disambiguated the same way `map` is —
  child-arg position vs. expr position — with genuinely different
  evaluation semantics): **only the chosen node is ever evaluated**
  (`Tramaj.Eval.pickBranch` selects first, `evalTemplate` runs only
  on the winner), unlike the expr-level `branch`, whose arguments are all
  pre-evaluated `Json` before dispatch and so must all be error-free
  regardless of which one wins. This makes the template-block `branch`
  strictly more forgiving of an unreachable branch's own errors than its
  expr-level namesake.

Five new fixtures (19 total) in `tramaj/test/Test/Fixtures.purs`
cover this: the template's functional `map(...)` replacing the old OOP
syntax, expr-level `map`/`filter`/`scan` (including `map` composing over
a `filter`/`lookup`-derived array, and rendering a `scan`'s output via the
template's `map`), and template-block `branch(...)` both selecting a
node and falling back. `spago test` passes. The playground's
default example, in-app reference text, and every fixture using the old
`$path.map(...)` syntax were updated to the functional form.

## Bindable lambdas (first-class function values), implemented 2026-07-17

This is the resolution of the "First-class function values" follow-up
flagged repeatedly throughout this document (originally under "Open
follow-ups"), now closed. Previously, `map`/`filter`/`scan`'s lambda only ever
existed as a literal, inline argument; it couldn't be bound to a name and
reused. That restriction is gone.

- **`LambdaExpr (Array String) Expr`** — `(p1, p2, ...) => body` — is a
  new `Expr` constructor, usable anywhere `expr` is: inline as a call
  argument (unchanged surface syntax from before) *or* as the
  right-hand side of a binding, `@my-fn=(x) => $gt($x, 10)`.
- **A new evaluation-time `Value` type** (`Tramaj.Eval`, not exported
  — purely an internal representation): `VJson Json | VClosure (Array
  String) Expr Env`. `Env` is now `Map String Value`, not `Map String
  Json` — a binding can hold either kind of value. Evaluating a
  `LambdaExpr` produces a `VClosure`, capturing the environment *at that
  point* (lexical scoping — the body can see whatever was in scope where
  it was written, not just its own parameters).
- **`Call`'s dispatch now checks the environment before falling back to
  the fixed builtin table.** `$name(args)` first looks up `name` in
  `env`; if it's a `VClosure`, it's invoked directly (arguments evaluated
  as `Value`s, not coerced to `Json` — so a closure can be passed as an
  argument to another closure, giving genuine higher-order functions,
  e.g. `@apply=(f, x) => $f($x)`); only if `name` isn't bound at all does
  evaluation fall through to `evalBuiltin` (unchanged). This means a
  user binding can shadow a builtin name if they choose to reuse it —
  an accepted edge case, not guarded against.
- **A bound closure can be passed to `map`/`filter`/`scan` by
  reference**, not just written inline — `map($ctx.items, $my-fn)` works
  exactly like `map($ctx.items, (item) => ...)`, since `fn` in each of
  those three primitives is just an ordinary `expr` (see the "Functional
  map/filter/scan" section above) — no special-casing needed to support
  this, it fell out of the design for free once lambdas became real
  values.
- **Every place that previously expected a bare `Json` from `evalExpr`
  now goes through a new `evalExprAsJson` coercion** (`requireJson`),
  which errors clearly if the expression actually evaluated to a
  closure (interpolating `` `$my-fn` `` into a string without calling
  it, storing a closure in an array/object literal, passing one to a
  fixed builtin that isn't `map`/`filter`/`scan` — all rejected with a
  `TypeMismatch` pointing at calling it first).
- **No recursion, by construction, not by choice.** `evalBindings`
  inserts a binding's value only *after* evaluating its right-hand side,
  so a closure's captured environment never includes its own
  not-yet-inserted name. `@fact=(n) => $fact($n)` parses fine but fails
  at eval time the moment `fact` is called — `$fact` inside its own body
  resolves against the closure's *captured* (pre-self) environment, not
  the calling environment, so it's simply not found there (falls through
  to the builtin table, which doesn't have it either, so
  `UnknownFunction`). Recursive closures would need either a different
  binding strategy (e.g. inserting a placeholder before evaluating the
  RHS) or explicit fixed-point machinery — neither implemented; flagged
  as a known limitation, not a bug.

Four new success fixtures (23 total) cover: calling a bound lambda by
name, passing one to `map` by reference instead of inline, lexical
capture of an outer binding, and a closure passed as an argument to
another closure. Three new negative checks (in `Test.Main`, alongside the
existing ordering-rejection check) cover: arity mismatch, no-recursion,
and using a bound closure as a bare value without calling it — all
`spago test`. Verified live in the browser playground too: bound
`is-big`/`apply`/`get-title` closures called, composed, and passed by
reference, with correct rendered output.

## Structured actions (`action(...)`), implemented 2026-07-17

Closes the "richer `action` value" follow-up flagged earlier in this
document — `Node`'s `action` field is no longer
an opaque post-interpolation string; it's a structured payload a host
dispatcher can pattern-match directly.

- **New surface syntax**: `action(eventType, keyExpr, payloadExpr)`
  appears directly among a node's arguments — `.button("Select",
  action(on-click, "select", {"itemId": $itemId}))` — **not**
  nested under an `action:` attribute key the way the original
  opaque-string design worked (that `action:` syntax no longer parses
  the old way at all — `action` is no longer a magic reserved attribute
  key filtered out of `attrs` after the fact; it's genuinely a different
  kind of node argument now). `eventType` is a bare identifier from a
  small fixed set validated at eval time (today, only `"on-click"` —
  `Tramaj.Eval.supportedActionEventTypes`); `keyExpr` evaluates to a
  `Json` string, `payloadExpr` to arbitrary `Json`. A node may have at
  most one `action(...)` (a second is a parse error); it counts as
  attr-like for the attrs-before-children ordering rule.
- **AST**: `Tramaj.Ast` gained `TAction String Expr Expr`
  (`TemplateNode`'s `TElement` grew a 4th field, `Maybe TAction`, instead
  of smuggling the action through the `attrs` list) and `type
  ActionPayload = { eventType :: String, key :: String, payload ::
  Json }` — what `Node`'s `action` field now holds, and what the host's
  dispatcher receives, replacing the old `Maybe String`.
- **`Tramaj.Halogen.foldToHalogen`'s signature changed**: `(String
  -> Maybe action)` → `(ActionPayload -> Maybe action)` — a real breaking
  change to the one existing consumer (the playground),
  fixed in the same pass. `eventType` is always `"on-click"` today (the
  only value that passes eval-time validation), so the fold still always
  wires `HE.onClick` when an action is present, unconditionally — no
  dispatch-by-eventType logic needed yet, though the full payload
  (including `eventType`) reaches the host in case a future host wants
  to branch on it itself.
- **The playground now has a real dispatcher**, not `const Nothing`:
  every `action(...)` click becomes a genuine Halogen action carrying the
  key and payload, appended to an action-log list in the host's state and
  rendered as a new "Action log" panel next to "Rendered" — newest entry
  first, with a "Clear" button. The playground's default example was updated to
  include a "Select" button per list item wired to `action(on-click,
  "select-item", {"title": $item.title})`, so the feature is visible
  without editing anything.

Two new fixtures/checks (23 fixtures unchanged in count — the old
`action:`-string fixture was rewritten in place, not added to) plus two
new negative eval-time checks (`action(...)` rejects an unrecognized
event type; a node can have at most one `action(...)`, a parse-time
rejection) in `tramaj/test/`. `spago test` passes. Verified live in
the browser: clicking "Select" on each rendered list item produced a
real Halogen action, correctly appended to the log with the right
key/payload in the right order; "Clear" correctly emptied it.

## Markup validation at the Halogen fold, implemented 2026-07-17

Resolved the follow-up above. `Tramaj.Halogen` now exports
`isValidAttrName :: String -> Boolean` (alphanumeric plus `-`/`_` only —
deliberately stricter than what HTML itself permits, since the only
names templates should ever need are kebab-case/snake_case identifiers)
and `validateAttrNames :: Node -> Array String`, which walks the whole
tree and returns every invalid attribute key found (deduplicated, `[]`
if the tree is safe to fold). `foldToHalogen` itself is unchanged —
still trusts its input — so this is opt-in: a caller runs
`validateAttrNames` on the evaluated `Node` first and decides what to do
with a non-empty result, rather than folding straight through and
risking the uncaught `Element.setAttribute` `DOMException` described
above.

The playground is the first caller: it checks
`validateAttrNames` right after `evalProgram` succeeds and, on a
non-empty result, renders an inline error ("Invalid attribute name(s):
... — attribute keys may only contain letters, digits, '-' and '_'")
instead of calling `foldToHalogen`. Verified live in the browser: a
template with a `"bad attr:name": "x"` attribute now renders that error
message with no console exceptions, where it previously threw an
uncaught `DOMException` mid-render; the default demo template still
renders normally. `spago build`/`spago test` pass for both `tramaj`
and the host package.

## action(...)'s eventType generalized to any expr, implemented 2026-07-17

`TAction`'s first field (`eventType`) was a bare identifier keyword
(`action(on-click, ...)`), checked at parse time only insofar as it had
to look like an identifier, then validated against a fixed set at eval
time. Motivation for changing it: this language isn't meant to stay
Halogen-only — a future email or static-site renderer has no DOM events
at all, so baking a DOM-event-shaped bare keyword into the parser itself
was the wrong level to enforce that concern. `TAction` is now `TAction
Expr Expr Expr` — all three positions (`eventType`, `key`, `payload`)
are ordinary `expr`s. Surface syntax changes accordingly:
`action("on-click", "key", {...})` — `eventType` needs quotes now (it's
a string literal, like `key`), but it can equally be a computed
expression, e.g. `action($ctx.eventName, "key", {...})`.
`Tramaj.Eval.evalAction` evaluates `eventType` to a `Json` string
(erroring if it isn't one) before checking it against
`supportedActionEventTypes` — that fixed-set check itself is unchanged
and is specifically the *Halogen* host's vocabulary (today just
`"on-click"`), not a language-level restriction; a different host would
define its own accepted set.

Existing fixtures/docs updated for the new quoting requirement (`.button
(action(on-click, ...))` → `.button(action("on-click", ...))`)
throughout `tramaj/test/`, the playground's default template, and its
in-app reference text.
Added a new fixture demonstrating a computed `eventType`
(`action($ctx.eventName, ...)`) resolving correctly. `spago test` passes
(24 fixtures). Verified live in the browser: the playground's default
demo (still using a literal `"on-click"`) renders and dispatches clicks
correctly; no console errors.

## AST inspection panel in the playground, implemented 2026-07-17

`Tramaj.Ast` now exports `nodeToJson :: Node -> Json`, a plain
debugging/inspection serialization of the evaluated `Node` tree (not a
wire format read back in anywhere) — `{"type": "element", "tag": ...,
"attrs": ..., "action": ..., "children": [...]}` / `{"type": "text",
"text": ...}`. The playground adds a third card, AST,
to the left of Rendered and Action log, showing `nodeToJson`'s output
pretty-printed (`stringifyWithIndent 2`). The parse/eval computation
producing the `Node` is factored into a shared
`computeTemplatingNode :: State -> Either String Node`, used by both the
AST and Rendered panels, so they can't disagree about what they're
each showing. Verified live in the browser against the default demo
template: the AST panel shows the full evaluated tree (including the
`action` field's `eventType`/`key`/`payload`) in sync with what Rendered
displays.

## `fold(arr, init, fn)` builtin, implemented 2026-08-22

A fourth functional array primitive alongside `map`/`filter`/`scan`
(§"Functional map/filter/scan..." above): `Expr` gained `FoldExpr Expr
Expr Expr`, parsed as its own dedicated special form exactly like `scan`
(`Tramaj.Parser.specialFormExpr`'s `foldShape`), sharing `scan`'s
`(acc, item)` step signature and `scanl` (seed-first) iteration order —
but where `scan` returns every intermediate accumulator as an array one
longer than the input, `fold` returns only the **final** accumulator, a
plain `Json` value (`init` unchanged, returned as-is, for an empty
array). It exists specifically for the common case where only the
end result of an accumulation is wanted (a running total, a single
"did any item match" boolean) and building the whole `scan` array just
to read its last element is wasted work. Implemented in both
`tramaj` (PureScript) and `tramaj-hs` (Haskell); two new
fixtures on each side (a non-empty and an empty-array case) bring the
PureScript fixture count to 27 in `tramaj/test/Test/Fixtures.purs`,
`spago test` passes; the Haskell port's `tramaj-hs/test/unit/Tramaj/EvalSpec.hs`
mirrors both, `cabal test unit` passes.

## `concat`/`append` builtins, implemented 2026-08-24

Two more fixed builtins, for working with arrays produced by `map`/
`filter`/`scan`/`fold`/`lookup`/literals: **`concat(a, b, ...)`** —
variadic, joins any number of arrays (`concat()` is `[]`) into one,
preserving order, erroring if any argument isn't itself an array — and
**`append(arr, item)`** — a new array with `item` added at the end,
where `item` is any `Json` value (including an array/object, added as
one element, not spliced in; that's what `concat` is for). Unlike
`map`/`filter`/`scan`/`fold`, neither takes a lambda, so both are
ordinary `Call`-dispatched builtins (`Tramaj.Eval.evalBuiltin`) —
no new `Expr` constructor or dedicated parser special-form needed, same
as `cardinality`/`has`/`lookup`/etc. Two new fixtures on each side
(`concat` over two `$ctx`-bound arrays plus an array literal; `append`
checked via `cardinality` growing by one) bring the PureScript fixture
count to 29 in `tramaj/test/Test/Fixtures.purs`, `spago test`
passes; `tramaj-hs/test/unit/Tramaj/EvalSpec.hs` mirrors both,
`cabal test unit` passes (42 examples). The playground's in-app
language reference and `specs/llm.md`'s builtin table were updated to
match.

## Imports, partial imports, postfix field access, action remapping, implemented 2026-08-2x

Four related additions, all in `tramaj` (PureScript) and mirrored in
`tramaj-hs` (Haskell), landed close together (git log: "Add imports",
"Adapt playground", "Support postfix .field access", "Add an event
contramap primitive", "Implement libraries in haskell and in the cli").
Together they let one program reference another by name and compose
their document output and actions — the first mechanism in the language
for referencing anything outside the current program/`$ctx`.

- **`import(nameExpr, paramsExpr)`** — a new special form (`Expr` gained
  `ImportExpr Expr Expr`), evaluated by running another parsed program (a
  **library**) with `paramsExpr` as *that library's own* `$ctx`, entirely
  separate from the importing template's `$ctx`. Libraries are resolved
  from a host-supplied `LibraryTable = Map String LibrarySource`
  (`Tramaj.Eval`), where `LibrarySource` is either `ProgramSource`
  (element-rooted, like an ordinary template) or `JsonSource`
  (expression-rooted, reusing the JSON-mode entry point added
  2026-07-16-ish under "Detailed design"/§5.1b of `specs/llm.md`) — which
  one a given library is is a host-loading detail. The result is a new
  internal `Value` case, `VEnv`, exposing `.rendered` (the library's
  evaluated root — a `Node` for a `ProgramSource`, plain JSON for a
  `JsonSource`) and `.vals` (every one of the library's own top-level
  `@`-bindings, by name) via ordinary field access (below). Re-entering a
  library name already in progress on the current call chain is a new
  `ImportCycle` error, not infinite recursion; importing a name the host
  never supplied is `UnknownLibrary`.
- **`partial-import(nameExpr, paramsExpr)`** — like `import`, but
  tolerant of incomplete params: if evaluating the library fails
  specifically because of a missing `$ctx.<field>` the library itself
  needed, the failure downgrades to a suspended callable value (`VPartial
  name paramsGiven`) instead of erroring. Applying that value to one more
  JSON object argument (`$button({"title": "Save"})`) shallow-merges it
  into the params already given and retries, completing (same result as
  `import` with the merged params) or suspending again — so params can be
  supplied incrementally, including via currying across multiple call
  sites. Any other failure (unknown library, a cycle, a real bug in the
  library) still propagates immediately; only a missing-`$ctx`-field
  failure suspends. **Known limitation, not fixed**: a library that
  itself performs a nested `import`/`partial-import` with its own
  incomplete params produces the same shape of missing-field error, which
  the outer partial can't distinguish from its own — the outer partial
  may suspend waiting on a param it can never actually complete this way.
  A library that imports something else is expected to keep that inner
  import fully applied.
- **Postfix field access** — `Expr` gained `FieldAccess Expr (Array
  String)`: any `call` or special-form result (`import(...)`,
  `$button({...})`, `map(...)`, etc. — anything ending in `)`) may be
  followed by one or more `.field` segments with no whitespace
  (`import("nav", {}).vals.greeting`). This is additive to the existing
  prefix `Path` production (`$ctx.items`) and does **not** relax the
  standing restriction that a dotted path can't be called — `$ctx.foo(...)`
  is still rejected; `FieldAccess` only ever wraps a call/special-form
  result. Evaluation shares one `walkFields` helper between `Path`
  resolution and `FieldAccess`, which understands walking through a plain
  JSON object, a `VNode`, or a `VEnv` — so `.rendered`/`.vals` and one
  more segment into a library's own bindings all just work the same way a
  `$ctx.foo.bar` path already did.
- **`remap-actions(nodeExpr, fnExpr)`** — the "event contramap"
  primitive: a special form (needs to walk a whole `Node` tree, so it
  can't be an ordinary `Call`) that rewrites every `action(...)` found
  anywhere in a document tree by applying an arbitrary closure of shape
  `{eventType, key, payload} -> {eventType, key, payload}` to each one,
  recursively through children. There is **no restriction to prefixing or
  any other fixed shape** — the closure can rewrite `eventType`, `key`,
  and `payload` however it likes; its result must have string
  `eventType`/`key` fields or evaluation is a `TypeMismatch`. `nodeExpr`
  may be a `VNode`, a `VEnv` (remapped recursively through every value it
  holds, including nested sub-imports), or a suspended partial import — in
  the last case the function is queued (`VRemapPartial`) and applied once
  the partial eventually completes, so a `remap-actions` wrapping can be
  attached once, before the value that completes the partial import is
  even in scope (e.g. inside a `map(...)` body). Multiple `remap-actions`
  calls chain in application order, including across partial-import
  completion. A no-op on a node/env with no actions anywhere, and a no-op
  on a `JsonSource` library's plain-JSON `.rendered` (nothing to remap).
- **CLI**: `tramaj-cli` (PureScript; there is no separate Haskell
  CLI, `tramaj-hs` ships as a library only) gained a repeatable
  `--lib name=path` flag, resolving each name to a file on disk, parsed
  once at startup — auto-detecting element-mode vs JSON-mode by trying
  `parseProgram` first, falling back to `parseJsonProgram`. This is what
  makes `import`/`partial-import` usable from the command line at all;
  the playground was also adapted to let a template reference a second,
  in-browser template as a library.

**Note on `specs/position.md`.** That document (added later, as a
positioning/vision piece) describes both import names and action keys as
"statically identifiable" — inspectable without evaluation, with action
adaptation restricted to identity-or-static-prefix only (an
`adapt-actions` primitive). **None of that is what shipped here.**
`import`/`partial-import`'s name argument and `action`'s key argument are
both ordinary `expr`s, evaluated dynamically like any other argument, and
`remap-actions` — the primitive that actually landed — allows completely
arbitrary rewriting of `eventType`/`key`/`payload`, not just prefixing.
`specs/llm.md` §3.9/§5.2 flag this explicitly as an aspiration not yet
enforced. If the static-name/static-key/prefix-only restriction is wanted
later, it needs its own design and implementation pass — nothing here
enforces it today.

## Static import names, implemented 2026-08-26

First half of closing the gap the note above flags: **import names are now
statically identifiable**, per `specs/position.md` §1/§9. Action keys and
`remap-actions`'s arbitrary rewriting are unchanged — that's still open, see
the note above and `specs/llm.md` §5.2.

- **`ImportExpr`/`PartialImportExpr`'s name field is a bare `String`, not an
  `Expr`.** `import(nameExpr, paramsExpr)` used to accept any expression in
  the name position; `importShape`/`partialImportShape` (`Tramaj.Parser`,
  both languages) now parse it with `quotedKey` — the same
  no-interpolation double-quoted-string production object-literal keys use
  — so `import($ctx.libname, {})` is a **parse error**, not a runtime
  `TypeMismatch`. Only `paramsExpr` remains a computed expression.
- **Enforced without a runtime check.** Since the grammar itself no longer
  has a production for a computed import name, there was nothing left for
  `Tramaj.Eval` to validate — `evalExpr`'s `ImportExpr`/`PartialImportExpr`
  cases now use the name directly, and the `expectLibName` runtime check
  they used to call (in both `Tramaj.Eval.purs` and `Tramaj.Eval.hs`) is
  gone, dead code once the name can't be anything but a `String` already.
- **Parser fix needed alongside this**: `specialFormExpr` used to wrap
  *all* of name recognition and shape parsing in one `try`, so a
  recognized-but-malformed special form (e.g. `import` followed by
  something other than a quoted string) silently backtracked into the
  generic `call` production, producing a meaningless `Call ["import"]
  [...]` that only failed later, at eval time, as `UnknownFunction
  "import"` — not the intended parse-time rejection. Fixed by narrowing
  the `try` to cover only "is this identifier one of the seven special-form
  names" — once recognized, the corresponding shape parser runs without
  further backtracking, so its failure is a genuine parse error. This
  applies to all seven special forms (`map`/`filter`/`scan`/`fold`/
  `import`/`partial-import`/`remap-actions`), not just the two touched by
  this change, since they all shared the same dispatch.
- **The actual payoff**: `Tramaj.Ast.staticImportNames :: Program -> Set
  String` (`Tramaj.Ast.staticImportNames :: Program -> Set Text` on the
  Haskell side) walks a parsed program's bindings and template-block root
  recursively — through every `Expr`/`TemplateNode`/`TAction`/
  `StringPart` — and collects every import/partial-import name referenced,
  without evaluating anything. A host or tool can now enumerate a
  template's library dependencies up front.
- Fixture fallout: every existing `import("nav", ...)`-style fixture was
  already a literal, so all pass unchanged. New rejection fixtures added
  on both sides: `import($ctx.libname, {})`/`partial-import($ctx.libname,
  {})` (element mode) and `import($ctx.libname, {})` (JSON mode,
  PureScript only — `tramaj-hs` has no JSON-mode parse-rejection test file
  to add one to).
- `specs/llm.md` §3.9's divergence-from-`position.md` callout is gone
  (import names now match); the grammar (`§3`) and AST (`§4.1`) sections
  are updated to show `name` as a bare literal, not `nameExpr`.
