# templating-lang

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

The full grammar, builtin set, and design rationale live in
[`specs/templating-language.md`](specs/templating-language.md).

## Packages

| Package | Language | What it is |
|---|---|---|
| [`templating/`](templating) | PureScript | The core: `Templating.Ast`, `Templating.Parser`, `Templating.Eval`. No DOM, no Halogen — usable from any host. |
| [`templating-halogen/`](templating-halogen) | PureScript | `Templating.Halogen.foldToHalogen` — folds an evaluated `Node` into `Halogen.HTML`, wiring `action(...)` to the host's own `Action` type. |
| [`templating-cli/`](templating-cli) | PureScript | Node CLI: template file + JSON context file → the evaluated AST as JSON on stdout. |
| [`templating-hs/`](templating-hs) | Haskell | Independent port of Ast/Parser/Eval on megaparsec + aeson, for evaluating templates server-side. |

`templating-halogen` is a separate package precisely so that `templating` itself
never pulls in Halogen; that is what lets `templating-cli` (and any other
non-browser host) depend on the core alone.

## Two implementations, one grammar

`templating-hs` is a hand-written port, not a shared core behind an FFI. The two
implementations are kept in agreement by test fixtures that were ported
one-for-one: `templating/test/Test/Fixtures.purs` (24 fixtures) is the original,
and `templating-hs/test/unit/Templating/EvalSpec.hs` mirrors it.

**Known gap:** that agreement is maintained by hand and is not mechanically
enforced — there is no shared golden-file corpus and no cross-language
conformance runner, so the two suites can drift silently. Both `nodeToJson`
implementations emit the same JSON shape, so such a harness could be built on
that format without new code in either package. Contributions welcome.

## Building

### PureScript

The three PureScript packages form a single [Spago](https://github.com/purescript/spago)
workspace rooted at this repository, so all commands run from the repo root:

```bash
spago build                 # all three packages
spago test -p templating    # the fixture suite
spago run  -p templating-cli --args "template.txt context.json"
```

To produce a standalone CLI bundle:

```bash
# note: --outfile is resolved relative to the package directory
spago bundle -p templating-cli --platform node --outfile dist/templating-cli.js
node templating-cli/dist/templating-cli.js template.txt context.json
```

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
    templating:
      git: "https://github.com/lucasdicioccio/templating-lang.git"
      ref: v0.1.0
      subdir: templating
    templating-halogen:
      git: "https://github.com/lucasdicioccio/templating-lang.git"
      ref: v0.1.0
      subdir: templating-halogen
```

Cabal, in your `cabal.project`:

```
source-repository-package
  type: git
  location: https://github.com/lucasdicioccio/templating-lang.git
  tag: v0.1.0
  subdir: templating-hs
```

## Publishing

Not on the PureScript registry or Hackage yet. Doing so needs a `publish:` block
(license, location, version) in each `spago.yaml` and a commitment to semver;
that is deliberately deferred until the API has settled.

## License

MIT — see [LICENSE](LICENSE).
