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
  meta.json        required: {"name", "kind", "mode"}
  template.tramaj   required: the program source, verbatim
  ctx.json          required: the context value (JSON, may be `null`)
  expected.json     required: the expected result, in specs/node-json.md
                      form when kind is "document", or an ordinary JSON
                      value when kind is "expression"
  libs/*.tramaj     optional: library sources, one file per import name
                      (e.g. libs/button.tramaj is importable as "button")
```

`meta.json` fields:

* `name` — human-readable description, matches the directory's slug
* `kind` — `"document"` (must evaluate to a node) or `"expression"` (must
  evaluate to an ordinary value)
* `mode` — the evaluation mode to run the case in. `"concrete"` today;
  `"symbolic"` once v3 lands (roadmap Phase 2)

## Running

Both suites read this directory directly rather than embedding cases in
source:

* `tramaj/test/Test/Main.purs` — `runCorpus`
* `tramaj-hs/test/unit/Tramaj/CorpusSpec.hs`

A case belongs here only if both implementations can run it byte-for-byte
identically. Behavior that is legitimately implementation-specific (error
message wording, host-only checks) stays in each suite's own tests.
