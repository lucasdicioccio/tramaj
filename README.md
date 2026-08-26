# tramaj

A small template language for turning a JSON value into a document tree.

Templates are meant to be comfortable to write by hand *and* easy for an LLM to
emit: a HAML-like block syntax for structure, a `jq`-flavoured expression
language for the data half, and a deliberately tiny builtin set. Rendering is
decoupled from the language — evaluation produces a generic `Node` AST, and it
is the host that decides whether that becomes Halogen HTML, JSON, or anything
else.

A template is an optional block of `@name=expr` bindings followed by exactly one
root element:

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

**[`specs/llm.md`](specs/llm.md) is the reference** — overview, design
constraints, grammar, AST, how to embed it in a host, and the CLI. Start there,
and point agents at it.

[`specs/templating-language.md`](specs/templating-language.md) is the historical
design record: why each decision went the way it did, in the order it was made.
It preserves superseded intermediate designs on purpose, so where the two
disagree, `llm.md` is correct.

## Packages

| Package | Language | What it is |
|---|---|---|
| [`tramaj/`](tramaj) | PureScript | The core: `Tramaj.Ast`, `Tramaj.Parser`, `Tramaj.Eval`. No DOM, no Halogen — usable from any host. Also has a JSON mode (`parseJsonProgram`/`evalJsonProgram`): same language, expression root, a JSON value out instead of a document tree. |
| [`tramaj-halogen/`](tramaj-halogen) | PureScript | `Tramaj.Halogen.foldToHalogen` — folds an evaluated `Node` into `Halogen.HTML`, wiring `action(...)` to the host's own `Action` type. |
| [`tramaj-cli/`](tramaj-cli) | PureScript | Node CLI: template file + JSON context file → the evaluated AST as JSON on stdout. |
| [`playground/`](playground) | PureScript | Browser playground — edit a template and a JSON context, see the AST, the rendered HTML, and the actions it dispatches. |
| [`tramaj-hs/`](tramaj-hs) | Haskell | Independent port of Ast/Parser/Eval on megaparsec + aeson, for evaluating templates server-side. Also has a JSON mode (`parseJsonProgram`/`evalJsonProgram`): same language, expression root, a JSON value out instead of a document tree. |

`tramaj-halogen` is a separate package precisely so that `tramaj` itself
never pulls in Halogen; that is what lets `tramaj-cli` (and any other
non-browser host) depend on the core alone.

## Two implementations, one grammar

`tramaj-hs` is a hand-written port, not a shared core behind an FFI. The two
implementations are kept in agreement by test fixtures that were ported
one-for-one: `tramaj/test/Test/Fixtures.purs` (25 fixtures) is the original,
and `tramaj-hs/test/unit/Tramaj/EvalSpec.hs` mirrors it.

**Known gap:** that agreement is maintained by hand and is not mechanically
enforced — there is no shared golden-file corpus and no cross-language
conformance runner, so the two suites can drift silently. Both `nodeToJson`
implementations emit the same JSON shape, so such a harness could be built on
that format without new code in either package. Contributions welcome.

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
spago build                 # all three packages
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

Repeat `--lib name=path` for as many libraries as a template's `import(...)`/
`partial-import(...)` calls need; each file is auto-detected as a plain
template or a JSON-mode library (see `Tramaj.Ast`'s `import`/
`partial-import` docs).

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

## Roadmap to a v1

Assume anything could change until we get to a v1.

- Some more syntax for combining/constructing records.
- Stabilize feature set.
- Revisit syntax/naming/combinators of primitives.
- Add plenty of regression and compatibility tests.

Then for a v2 we'll likely want to add some simple but effective typing.


## Publishing

Not on the PureScript registry or Hackage yet. Doing so needs a `publish:` block
(license, location, version) in each `spago.yaml` and a commitment to semver;
that is deliberately deferred until the API has settled.

## License

MIT — see [LICENSE](LICENSE).
