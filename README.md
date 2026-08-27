# tramaj

A small template language for turning a JSON value into a document tree.

Templates are meant to be comfortable to write by hand *and* easy for an LLM to
emit: a HAML-like block syntax for structure, a `jq`-flavoured expression
language for the data half, and a deliberately tiny builtin set. Rendering is
decoupled from the language — evaluation produces a generic `Node` AST, and it
is the host that decides whether that becomes Halogen HTML, JSON, or anything
else.

A template is an optional block of `@name=expr` bindings followed by a root
expression:

```
@items=$ctx.items
@n=cardinality($items)
.div(class: "items",
  .h1("Items"),
  .p("there are `$n` of them"),
  .ul(map($items, (i) => .li(action("on-click", "select", {"id": $i.id}), $i.name))))
```

Bindings are evaluated once, in order. `` `$n` `` interpolates into a string;
a bare `$path` can be used directly as a child. `action(...)` attaches an
opaque, structured action to an element — the language recognises the syntax
but assigns it no meaning, leaving the host to map the key onto a real event
handler.

## v2

v2 is expression-oriented: documents *are* values, so an element or fragment
can be bound, passed to a lambda, and returned from one — which is what makes
the JSX-children pattern work without a separate template-value category.

```
@kids=.(.p("one"), .p("two"))            -- a fragment, as an ordinary value
@panel=(title, children) =>
  .section(.h2($title), $children)

.main($panel("Deployment", $kids))
```

Also new in v2: a normative JSON interchange format for the evaluated document
([`specs/node-json.md`](specs/node-json.md)) in which scalars stay scalars and
an element may carry many actions; `a <> b` concatenation over strings, arrays
and objects; imports that declare their own holes with `ctx(path)` rather than
having partiality inferred; action adaptation restricted to a static prefix;
and three static analyses that answer what a program imports, what actions it
can emit, and what context it still needs — without evaluating it.

**Reference for v2**: [`specs/merged2.md`](specs/merged2.md) is the fullest
description of the language, [`specs/core.md`](specs/core.md) the condensed core
AST, [`specs/node-json.md`](specs/node-json.md) the normative output format, and
[`specs/decisions.md`](specs/decisions.md) records which reading won wherever
those drafts contradict each other — read that one first.

**v1 references**, describing the superseded language:
[`specs/llm.md`](specs/llm.md), with
[`specs/templating-language.md`](specs/templating-language.md) as the historical
design record. Both are now historical; nothing in the repository implements v1.

## Packages

| Package | Language | What it is |
|---|---|---|
| [`tramaj/`](tramaj) | PureScript | The core: `Tramaj.Ast`, `Tramaj.Parser`, `Tramaj.Eval`, `Tramaj.Node`, `Tramaj.Analysis`. No DOM, no Halogen — usable from any host. |
| [`tramaj-halogen/`](tramaj-halogen) | PureScript | `Tramaj.Halogen.foldToHalogen` — folds an evaluated `Node` into `Halogen.HTML`, wiring each `action(...)` to the host's own `Action` type. Returns an *array*, since a fragment is several siblings with no wrapper. |
| [`tramaj-cli/`](tramaj-cli) | PureScript | Node CLI: template file + JSON context file → the evaluated AST as JSON on stdout. |
| [`playground/`](playground) | PureScript | Browser playground — edit a template and a JSON context, see the AST, the rendered HTML, and the actions it dispatches. |
| [`tramaj-hs/`](tramaj-hs) | Haskell | The same five modules on megaparsec + aeson, for evaluating server-side. No browser runtime. |

`tramaj-halogen` is a separate package precisely so that `tramaj` itself
never pulls in Halogen; that is what lets `tramaj-cli` (and any other
non-browser host) depend on the core alone.

## Two implementations, one grammar

`tramaj-hs` is a hand-written port, not a shared core behind an FFI, and the
two implementations are kept in agreement by hand-ported test fixtures.

**Known gap:** that agreement is still not mechanically enforced — there is no
shared corpus and no cross-language conformance runner, so the two suites can
drift silently.

v2 narrows the gap without closing it. Both suites now assert against the same
normative representation ([`specs/node-json.md`](specs/node-json.md)) rather
than against their own internal types, and both fixture tables are written as
template / context / expected-JSON triples — so a fixture and its counterpart
can be compared by reading them. The remaining step is a single corpus file
both runners read, checking each implementation against the specification
rather than against the other. Contributions welcome.

The port already earned its keep: it caught a divergence that neither side's
own suite could have. PureScript's `Char` is a UTF-16 code unit, so
`\u{1F600}` and every other astral escape failed to parse there while parsing
fine in Haskell.

## Building

You need `purs` and `spago` on your `PATH` (e.g.
`npm install -g purescript spago`), plus GHC and `cabal` for the Haskell package.

Anything that **bundles** — the playground and the CLI — also needs `esbuild`,
which `spago` shells out to and cannot supply itself. It is a devDependency here,
so `npm install` once in the repo root covers it:

```bash
npm install                        # esbuild, for `spago bundle`
export PATH="$PWD/node_modules/.bin:$PATH"
```

Without that (and without a global esbuild) `spago bundle` fails with
*"Failed to find esbuild. Have you installed it, and is it in your PATH?"*.
`playground/serve.sh` does both steps for you.

### PureScript

The four PureScript packages form a single [Spago](https://github.com/purescript/spago)
workspace rooted at this repository, so all commands run from the repo root:

```bash
spago build                 # all four packages
spago test -p tramaj        # the fixture suite
spago run  -p tramaj-cli --args "template.txt context.json"
spago run  -p tramaj-cli --args "--lib greeter=greeter.txt template.txt context.json"
```

### Playground

The fastest way to get a feel for the language — a template box, a JSON context
box, and three live views of the result (the evaluated `Node` tree as JSON, that
tree folded to real HTML, and a log of the `action(...)` clicks it dispatches):

```bash
./playground/serve.sh            # bundle, then serve on http://localhost:8099
./playground/serve.sh --watch    # also rebuild on .purs changes (reload to see them)
PORT=9000 ./playground/serve.sh  # serve elsewhere
```

`--watch` also watches `tramaj/src` and `tramaj-halogen/src`, so it is a
usable loop for working on the language itself, not just on templates.

It is also the reference example of an *interactive* host: `Playground.Main`'s
`dispatchAction` turns every `action(...)` into a real Halogen action, where a
read-only host would pass `const Nothing` to `foldToHalogen`.

To produce a standalone CLI bundle:

```bash
# note: --outfile is resolved relative to the package directory
spago bundle -p tramaj-cli --platform node --outfile dist/tramaj-cli.js
node tramaj-cli/dist/tramaj-cli.js template.txt context.json
node tramaj-cli/dist/tramaj-cli.js --lib greeter=greeter.txt template.txt context.json
```

Repeat `--lib name=path` for as many libraries as a template's `import(...)`
calls need. There is no mode to detect: a library is just a program, and what
its root produces decides whether the CLI prints a document or a plain value.

### Haskell

```bash
cabal build all
cabal test unit
```

## Consuming from your own project

Neither half is published to a registry yet (see *Publishing* below). Depend on
them from git in the meantime.

Spago, in your `spago.yaml` — note the `subdir`, since this is a mono-repo:

```yaml
workspace:
  extraPackages:
    tramaj:
      git: "https://github.com/lucasdicioccio/templating-lang.git"
      ref: v0.1.0
      subdir: tramaj
    tramaj-halogen:
      git: "https://github.com/lucasdicioccio/templating-lang.git"
      ref: v0.1.0
      subdir: tramaj-halogen
```

Cabal, in your `cabal.project`:

```
source-repository-package
  type: git
  location: https://github.com/lucasdicioccio/templating-lang.git
  tag: v0.1.0
  subdir: tramaj-hs
```

## Roadmap to a stable release

"v2" above names the second iteration of the *language*; no package here has
had a stable release yet. Assume anything can still change.

Done in the second iteration:

- syntax for combining and constructing records — `a <> b` over strings,
  arrays and objects, plus object shorthand and bare keys;
- the restrictions that make imports, action keys and adaptation statically
  analysable, and the analyses that read them;
- a normative output format both implementations must encode and decode.

Still open:

- revisit the naming and combinators of the primitives;
- destructuring in `let` and lambda parameters — planned as pure desugaring
  (merged2 §19), so it needs no change to the core AST;
- a shared cross-implementation conformance corpus (see the known gap above);
- more regression and compatibility tests before anything is called stable.

Then: simple but effective typing. The AST is built to accept it — node
annotations are the place derived type/domain information goes, and the
semantics deliberately avoid equating "unknown" with `null`, so a
constraint-aware evaluator can reuse the same AST rather than forking the
language (`specs/merged2.md` §22).


## Publishing

Not on the PureScript registry or Hackage yet. Doing so needs a `publish:` block
(license, location, version) in each `spago.yaml` and a commitment to semver;
that is deliberately deferred until the API has settled.

## License

MIT — see [LICENSE](LICENSE).
