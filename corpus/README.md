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
  meta.json        required: {"name", "kind", "mode", "expect"?, "errorKind"?}
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
    error given by `errorKind`. No `expected.json` is read.
* `errorKind` — required when `expect` is `"eval-error"`: the name of the
  `EvalError` constructor the case must raise (e.g. `"UnboundName"`,
  `"TypeMismatch"`). Only the constructor is checked — error message
  text is implementation-defined (reference.md §13) — except where a case's
  own comment says the payload is being checked too (see the evaluation-order
  fixtures), because there the payload is the very thing under test, not
  prose.

## Running

Both suites read this directory directly rather than embedding cases in
source:

* `tramaj/test/Test/Main.purs` — `runCorpus`
* `tramaj-hs/test/unit/Tramaj/CorpusSpec.hs`

A case belongs here only if both implementations can run it byte-for-byte
identically. Behavior that is legitimately implementation-specific (error
message wording, host-only checks) stays in each suite's own tests.
