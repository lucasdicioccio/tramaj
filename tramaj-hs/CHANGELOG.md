# Changelog

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
