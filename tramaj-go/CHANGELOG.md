# Changelog

The full entries are on the site's changelog page,
`website/src/changelog-tramaj-go.cmark`. A Go release is a git tag of the
form `tramaj-go/vX.Y.Z` (see `../RELEASING.md`).

## 0.3.0 (2026-10-24)

The first release: `go get github.com/lucasdicioccio/tramaj/tramaj-go@v0.3.0`.
It is numbered with tramaj-rs, tramaj-py and tramaj-js 0.3.0, which carry the
same language; there was no 0.1.0 or 0.2.0 tag.

**The Go port**: parser, evaluator (concrete and symbolic modes), the `Node`
JSON codec, the static analyses and a `tramaj-go` CLI, checked against
`../corpus/cases` by `corpus_test.go`. Standard library only, Go 1.21+.

**Language v5.** Integers and floats are two types (`int64` and `float64` in a
`tramaj.JSON` value), the arithmetic profile (off by default; `Options`,
`EvalProgramWith`, `RunProgramWith`, the CLI's `--arithmetic`), terms over
symbols, `sort-by`, `sort-by-descending` and `format-number`.

**`?shape(key, shape)` allocates a structure of symbols** with one key and
one site (`../specs/v3-symbols.md` §1.2, `../specs/decisions.md` §19). Each
`~name` or `~name(e)` marker in the shape is a symbol `[key, "name"]` or
`[key, "name", e]` at the form's site, and `{~name}` is short for
`{name: ~name}`. It lowers at parse time, so the AST and the envelope are
unchanged.

**Symbolic mode: a symbol or a term as the key of `has` or `lookup` is
`NotConcrete`** (`../specs/v3-symbols.md` §1.5). A concrete key keeps the
tolerant behaviour: a missing key, an out-of-range index or a wrong-shaped
container still answers `false` or the fallback.

**Parse errors point at the mistake.** An unclosed `(`, `[`, `{`, string or
interpolation is reported where the closer was looked for, naming its opener
and where it is. `ParseError` carries `Line` and `Column` (1-based) next to
`Pos` and `Msg`, and `Error()` includes them:
`at char 8 (line 1, column 9): expected ')' to close the '(' of .div at line 1, column 5`.
