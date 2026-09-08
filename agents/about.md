# tramaj — project context

A small, expression-oriented template language that turns a JSON context into a portable document tree (`Node` AST). Hosts decide how to render that tree — Halogen HTML, JSON, YAML, etc.

- **v2** (stable base): documents are ordinary values, HAML-like `.tag(...)` syntax, `@name=expr` bindings, `$path` reads, `a <> b` concat, imports, actions, and a small builtin set.
- **v3** (frozen, implemented): symbolic values (`?`), constraints (`!`), `Concrete`/`Symbolic` modes, and the `tramaj/symbolic/1` envelope.
- **v4** (draft but implemented): nominal types, type parameters via imports, canonical type ids, `@x : T = e` annotations, and `!type-constraint(...)`.

There are two independent implementations that target the same grammar and share a language-neutral conformance corpus.

## Packages

| Package | Language | Role |
|---|---|---|
| `tramaj/` | PureScript | Core: `Ast`, `Parser`, `Eval`, `Node`, `Analysis`, `Types`. No DOM dependency. |
| `tramaj-halogen/` | PureScript | `foldToHalogen` — folds a `Node` into Halogen HTML and wires `action(...)` clicks. |
| `tramaj-cli/` | PureScript | Node CLI: `tramaj-cli [--lib name=path ...] [--mode concrete|symbolic] <template> <context>`. |
| `playground/` | PureScript | Browser playground with tabs-as-libraries, live AST/render/action-log/symbol/type panels. |
| `tramaj-hs/` | Haskell | Independent server-side port on megaparsec + aeson. Same five modules. |

## Authoritative specs

All specs live under `specs/`:

- `specs/reference.md` — the language as implemented.
- `specs/node-json.md` — normative JSON representation of the evaluated `Node` AST.
- `specs/laws.md` — design properties (determinism, static analysis, embeddability).
- `specs/decisions.md` — resolved conflicts and rationale.
- `specs/v3-symbols.md` — symbolic values and constraints.
- `specs/v4-types.md` — types, declarations, parameters, canonical identity.

## Language leaders

| Leader | Meaning |
|---|---|
| `.` | document: `.tag(...)` element or `.(...)` fragment |
| `$` | read a binding / path |
| `@` | define a binding |
| `!` | emit a constraint (statement position) |
| `?` | symbolic allocation/demand (v3) |
| `%` | type hole (v4) |
| `--` | single-line comment |

## Key design points

- **Documents are values.** `Element` and `Fragment` are `Expr` constructors; there is no separate template-phase AST.
- **Static positions.** Import names, action keys, adaptation prefixes, and `ctx(...)` paths are literal strings, so static analyses need no evaluation.
- **Lazy imports.** An import accumulates parameters and runs only when `.rendered` or `.vals` is read.
- **Only the root allocates symbols.** Libraries containing `?(key)` raise `AllocationInLibrary`.
- **Mode is a host choice.** `Concrete` produces plain Node/value JSON; `Symbolic` wraps the result in the `tramaj/symbolic/1` envelope.
- **Types are erased before evaluation.** `@x : T = e` becomes `@x=e` plus a `has-type` constraint carrying `T`'s canonical id.
- **Type identity is string equality.** Canonical ids use quoted library keys and the bare word `root` for the current program.

## Core modules

| Module | Purpose |
|---|---|
| `Tramaj.Ast` | Semantic AST and helpers: `subExprs`, `unlets`, `numberAllocs`, `stmts`, `typeDecls`. |
| `Tramaj.Parser` | Surface syntax → core AST; desugars interpolation, branch, object shorthand, types. |
| `Tramaj.Eval` | `evalProgram`/`runProgram`; `Value` domain; `Emissions`; builtins; imports; action adaptation. |
| `Tramaj.Node` | `Node` AST and strict JSON encode/decode per `specs/node-json.md`. |
| `Tramaj.Analysis` | Static analyses: imports, actions, context holes, unsupplied params, constraints, symbols, types. |
| `Tramaj.Types` | v4 type resolution, canonical ids, `typeClosure`, `eraseTypes`, `typeConstraints`. |

## Build & test

```bash
# install esbuild for bundling
npm install
export PATH="$PWD/node_modules/.bin:$PATH"

# PureScript
spago build
spago test -p tramaj
spago run -p tramaj-cli --args "template.txt context.json"
./playground/serve.sh --watch

# Haskell
cabal build all
cabal test unit
```

## Conformance corpus

Shared cases live in `corpus/cases/`. Each case contains:

- `meta.json` — name, kind, mode, expected result type
- `template.tramaj` — the program
- `ctx.json` — context JSON
- `expected.json` — expected output
- `libs/*.tramaj` — optional libraries

Runners: `tramaj/test/Test/Corpus.purs` and `tramaj-hs/test/unit/Tramaj/CorpusSpec.hs`.

## Long-term memory

Important findings are stored in `agents/memory.db`, table `findings`, with categories such as `overview`, `language_v2`, `language_v3`, `language_v4`, `eval`, `parser`, `analysis`, `types_module`, `packages`, `build`, `corpus`, `decisions`, `open_items`.

## Open items

- v4: transparent alias, application sugar, possible `Program`-breaking declaration block, type-directed projection, unifying `?`/`%` realms, row polymorphism.
- Language-level: destructuring, calling a call's result directly `f(x)(y)`, negative/exponent number literals.

## File authority

`agents/filelist.txt` is the canonical file list for this project.
