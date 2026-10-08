# Shared conformance corpus

Language-neutral test cases, run identically by both implementations
(`tramaj` and `tramaj-hs`). See `roadmap-to-v4` Phase 0 for why this exists:
v3's correctness is largely byte-equality between two independently written
implementations, which two hand-maintained, per-language fixture lists cannot
demonstrate.

## Layout

Each case is a directory under `cases/`:

```
cases/<NNN-slug>/
  meta.json        required: {"name", "kind", "mode", "expect"?, "errorKind"?,
                      "requires"?}
  template.tramaj   required: the program source, verbatim
  ctx.json          required unless expect is "parse-error": the context
                      value (JSON, may be `null`)
  expected.json     required when expect is "success" (the default): the
                      expected result, in specs/node-json.md form when kind
                      is "document", or an ordinary JSON value when kind is
                      "expression"
  libs/*.tramaj     optional: library sources, one file per import name
                      (e.g. libs/button.tramaj is importable as "button")
```

`meta.json` fields:

* `name` — human-readable description, matches the directory's slug
* `kind` — `"document"` (must evaluate to a node) or `"expression"` (must
  evaluate to an ordinary value). Documentation only: a `"success"` case is
  checked by comparing the mode-aware output wholesale against
  `expected.json`, which already reflects the kind, so neither runner reads
  this field.
* `mode` — the evaluation mode to run the case in: `"concrete"` (byte-for-byte
  `reference.md`) or `"symbolic"` (wraps the result in the v3-symbols §5.2
  envelope). Both are run through the same `runProgram mode` entry point in
  each implementation, so `expected.json` for a symbolic case is the whole
  envelope, not just `"root"`.
* `expect` — optional, defaults to `"success"`:
  * `"success"` — the template parses, evaluates, and matches `expected.json`
  * `"parse-error"` — the template MUST fail to parse. No `ctx.json` or
    `expected.json` is read.
  * `"eval-error"` — the template MUST parse but fail to evaluate, with the
    error given by `errorKind`. No `expected.json` is read. A context the
    implementation's decoder refuses is expressed this way too, with
    `errorKind` `"TypeMismatch"` (reference.md §3, v3-symbols §5.3): a
    reserved key, a malformed symbol reference or term, an integer outside
    the integer range, a float too large for a double. `ctx.json` is always
    well-formed JSON; what is refused is its content, by the implementation
    and not by the runner. A runner therefore hands the implementation the
    text of each number in `ctx.json` (see `requires` below) and MUST NOT
    read `ctx.json` of a case it skips, since its own JSON parser may refuse
    `1e400`.
* `errorKind` — required when `expect` is `"eval-error"`: the name of the
  `EvalError` constructor the case must raise (e.g. `"UnboundName"`,
  `"TypeMismatch"`). Only the constructor is checked — error message
  text is implementation-defined (reference.md §13) — except where a case's
  own comment says the payload is being checked too (see the evaluation-order
  fixtures), because there the payload is the very thing under test, not
  prose.
* `requires` — optional, defaults to `[]`: the names of what an
  implementation must support for the case to apply to it. A runner skips a
  case that names a requirement its implementation does not declare, so the
  corpus can be ahead of an implementation without turning its suite red.
  The names in use (specs/decisions.md §18):
  * `"int-float"` — integers and floats are two types
  * `"arithmetic"` — the arithmetic builtins
  * `"int64"` — integers cover the full 64-bit range, beyond the guaranteed
    53-bit one

  and (specs/decisions.md §20):
  * `"sort"` — the `sort-by` and `sort-by-descending` forms. A case whose
    keys are floats, or that depends on an integer and a float being two
    types, names `"int-float"` as well.
  * `"format-number"` — the `format-number` builtin. Every such case names
    `"int-float"` too, since the first argument is typed by it.
  * `"round"` — `round`, the tenth arithmetic builtin. It is a name of its
    own, beside `"arithmetic"`, because some implementations declared
    `"arithmetic"` when the profile had nine names. Every such case names
    `"arithmetic"` and `"int-float"` too, and an implementation declares
    `"round"` only together with `"arithmetic"`.

  A case without `requires` runs everywhere, as before. A case that names
  several requirements runs only where all of them are declared.

  In a case that requires `"int-float"`, the text of a number in `ctx.json`
  and `expected.json` is significant: `3` is an integer and `3.0` a float
  (reference.md §3, node-json.md *Numbers*), so the two are different
  contexts and different expected values. A runner that declares
  `"int-float"` reads both files with a parser that keeps that difference,
  and one that declares `"int64"` keeps the digits of an integer beyond
  2^53 as well. These files are written by hand; do not regenerate them
  with a tool that rewrites numbers.

## Skipped cases

Each runner holds the list of requirements its implementation declares, next
to the code that reads `meta.json` (`supportedRequirements`, or the same name
in the language's own spelling). The PureScript list holds `"int-float"` and
the Haskell list `"int-float"`, `"int64"` and `"arithmetic"`; every other
list is empty today. No list holds `"sort"`, `"format-number"` or `"round"`
yet, so the cases that name one are skipped by every suite. An implementation
that gains a capability adds the name there, and the cases marked with it
start running in that suite; no case needs editing.

In the Haskell and Purescript implementations the arithmetic profile is an option of each
evaluation, off by default. Its runner turns it on for a case that names
`"arithmetic"` and leaves it off for every other case, where the nine
arithmetic names are unbound. `round` will join them under the same option.

Until an implementation runs them, the expected texts of the
`format-number` and `round` cases stand on one reference computation
(exact rational arithmetic over the value of each literal), cross-checked
against ECMAScript's `toFixed` below `1e21`. The expected output of the other
new cases was written by hand from specs/reference.md §11.

A name the runner does not know is, by that rule, not declared, so the case
is skipped rather than rejected.

A skipped case is not a passed one, and each runner reports it apart:

* PureScript — a `skip - <case> (requires ...)` line per case, and the
  summary line counts the skipped cases separately
* Haskell — the example is pending (`# PENDING: requires ...`), counted in
  hspec's `N pending`
* Rust — libtest cannot skip part of a test, so the runner writes
  `skipped: <case> (requires ...)` lines and a count to stderr, uncaptured
* TypeScript — the test is registered with `it.skip`, counted in vitest's
  `N skipped`
* Go — the subtest calls `t.Skip`; `go test -v` lists it as `--- SKIP`
* Python — the test raises `unittest.SkipTest`, counted in `OK (skipped=N)`

`runner-checks/unsupported-requirement/` is a case, outside `cases/`, that
names a requirement no implementation will ever declare (`never-declared`)
and whose `expected.json` is wrong on purpose. Each suite has one test that
feeds it to its runner and checks that it is skipped; a runner that ignored
`requires` would run it and fail. Because the Go and TypeScript checks go
through the test framework's own skip, those two suites always show this one
skipped test.

## Running

Every suite reads this directory directly rather than embedding cases in
source:

* `tramaj/test/Test/Corpus.purs` — `runCorpus`
* `tramaj-hs/test/unit/Tramaj/CorpusSpec.hs`
* `tramaj-rs/tests/corpus.rs`
* `tramaj-js/test/corpus.test.ts`
* `tramaj-go/corpus_test.go`
* `tramaj-py/tests/test_corpus.py`

A case belongs here only if both implementations can run it byte-for-byte
identically. Behavior that is legitimately implementation-specific (error
message wording, host-only checks) stays in each suite's own tests.
