# Changelog

## 0.3.0.0

Implements v2 of the language. This is a rewrite of the semantic core, not an
extension of it -- every program, every host and every fixture is affected.
`../specs/decisions.md` records the design conflicts this resolved and which
reading of the specs won.

**Documents are expressions.** `Element` and `Fragment` are ordinary `Expr`
constructors, so a document node is a value that can be bound, passed to a
lambda and returned from one -- which is what makes the JSX-children pattern
work. The separate template-phase AST (`TemplateNode`, `TElement`, `TValue`,
`TMap`, `TBranch`) and its duplicated `map`/`branch` forms are gone, and so is
`JsonProgram`: `Program` is now `DocumentProgram`/`ExpressionProgram`, told
apart by the root's own form.

**New `Tramaj.Node`**, the normative interchange format specified in
`../specs/node-json.md` and implemented with both an encoder and a strict
decoder. `Text` carries a `Value` rather than a `String` and `Element` gains a
value slot, so a scalar child stays a scalar instead of being stringified;
attribute values are arbitrary values; an element may carry any number of
actions rather than at most one; fragments are real nodes; and every node
carries an annotations map that transformations preserve.

**New `Tramaj.Analysis`**: `staticImportNames`, `staticActionKeys` and
`contextHoles`, each with a deep variant that follows imports through a
library table and cuts cycles. `staticActionKeys` applies action adaptation
rather than ignoring it, so a prefixed subtree's keys are known without
evaluating anything.

**Imports declare their holes.** One `import(name, {k: expr, k2: ctx(path)})`
form; `partial-import` is gone. An import is partial exactly when a parameter
is still `ctx(path)`, so partiality is read off the source instead of being
inferred by running the library and catching a `PathNotFound` that started with
`ctx` -- which means a genuinely missing parameter is now the hard error it
always was, rather than being silently reinterpreted as partiality.

**Other language changes.** `a <> b` concatenates strings, arrays or objects
(mixed types rejected, objects right-biased). `branch` is uniformly lazy and a
core constructor rather than a builtin, so an unreached arm's errors never
surface. `remap-actions` becomes `adapt-actions(node, prefix("ns:") | identity
[, fn])`, its prefix a static literal, its optional closure limited to the
event type and payload. Fragments are written `.(a, b)`. An action's event
joins its key in being a static literal. String literals gain escape sequences
including `\u{...}`; objects gain shorthand `{foo}` and bare keys. Builtins are
values in the initial environment, so one can be passed by reference; `str` is
new and `branch` is no longer among them.

Two parser bugs found while porting, both of the shape the 2026-08-26 pass
fixed for special forms: a malformed `action(...)`/`value(...)` in an element
argument backtracked into a meaningless `Call` instead of failing, and a
backtick in a static string position was silently taken as a literal rather
than reported as an interpolation that cannot go there.

Not yet ported to the PureScript `tramaj` package, which still implements v1.

## Unreleased

Adds `fold(arr, init, fn)`, a fourth functional array primitive alongside
`map`/`filter`/`scan`: same `(acc, item)` step and `scanl` iteration order as
`scan`, but returns only the final accumulator instead of every intermediate
step. Also adds `concat(a, b, ...)` (variadic array-joining) and
`append(arr, item)` (add a single element at the end) as ordinary builtins.
Purely additive; no existing behavior changed. Ported in lockstep to the
PureScript `tramaj` package.

## 0.2.0.0

Adds a JSON-producing mode for hosts that want the data half of the language on
its own: `Tramaj.Ast.JsonProgram`, `Tramaj.Parser.parseJsonProgram` and
`Tramaj.Eval.evalJsonProgram`. Same computation block and same expression
language as `parseProgram`/`evalProgram`, but the root is an expression rather
than an element, so the result is an aeson `Value` instead of a document `Node`
-- nothing is stringified through `jsonToDisplayString`. Purely additive; no
existing behavior changed. Haskell-only, with no counterpart in the PureScript
`tramaj` package.

## 0.1.0.0

Initial release, extracted from the repository it was written in. Ports the
PureScript `tramaj` package's `Tramaj.Ast` / `Tramaj.Parser` /
`Tramaj.Eval` to megaparsec + aeson.
