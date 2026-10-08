# Shared conformance corpus

Language-neutral test cases, run identically by every implementation (the
six listed under *Running*). See `roadmap-to-v4` Phase 0 for why this exists:
v3's correctness is largely byte-equality between two independently written
implementations, which two hand-maintained, per-language fixture lists cannot
demonstrate.

## Layout

Each case is a directory under `cases/`:

```
cases/<NNN-slug>/
  meta.json        required: {"name", "kind", "mode", "expect"?, "errorKind"?,
                      "profiles"?}
  template.tramaj   required: the program source, verbatim
  ctx.json          required unless expect is "parse-error" or "analysis":
                      the context value (JSON, may be `null`)
  expected.json     required when expect is "success" (the default): the
                      expected result, in specs/node-json.md form when kind
                      is "document", or an ordinary JSON value when kind is
                      "expression"
  analysis.json     required when expect is "analysis": the expected result
                      of each named static analysis
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
  envelope, not just `"root"`. An `"analysis"` case evaluates nothing and
  has no `mode`.
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
    text of each number in `ctx.json` (see `profiles` below) and MUST NOT
    read `ctx.json` of a case it skips, since its own JSON parser may refuse
    `1e400`.
  * `"analysis"` — the template MUST parse, and each static analysis named
    in `analysis.json` MUST give the result written there. Nothing is
    evaluated: no `ctx.json`, no `expected.json`, no `mode`. See *Analysis
    cases* below.
* `errorKind` — required when `expect` is `"eval-error"`: the name of the
  `EvalError` constructor the case must raise (e.g. `"UnboundName"`,
  `"TypeMismatch"`). Only the constructor is checked — error message
  text is implementation-defined (reference.md §13) — except where a case's
  own comment says the payload is being checked too (see the evaluation-order
  fixtures), because there the payload is the very thing under test, not
  prose.
* `profiles` — optional, defaults to `[]`: the profiles to activate for the
  case. A runner runs a case when its implementation can provide every
  profile listed, with exactly those profiles on, and skips it otherwise.
  The names in use (specs/decisions.md §18):
  * `"base"` — the language without any profile. Every implementation
    provides it and it is always on, so listing it changes nothing; a case
    may list it to say that running without any profile is its point.
  * `"arithmetic"` — the arithmetic profile (reference.md §11). It is on for
    a case only if the case lists it. A case that does not list it runs with
    arithmetic off on every implementation, where the arithmetic names
    are unbound and `sum(1, 2)` is an `UnboundName`; that is how the
    behaviour of an implementation without the profile is tested.
  * `"int53"` and `"int64"` — the integer range (reference.md §13): the
    guaranteed 53-bit range only, or the full 64-bit range. An
    implementation provides exactly one of the two. A case names one only
    when its result depends on the range: `sum(9007199254740991, 1)` is a
    `NotRepresentable` under `"int53"` and `9007199254740992` under
    `"int64"`. A case that stays inside the guaranteed range, or outside 64
    bits, names neither and runs on both.
  * `"int-float"` — integers and floats are two types. This is a transition
    tag, not a profile: it names a part of the base language that not every
    implementation has yet, and goes away once all six have it. An
    implementation names its integer range once it provides `"int-float"`,
    since before that it has no integer type to give a range to.

  Three more names are transition tags of the same kind
  (specs/decisions.md §20): each names a part of the language that needs no
  profile and that not every implementation has yet.
  * `"sort"` — the `sort-by` and `sort-by-descending` forms. A case whose
    keys are floats, or that depends on an integer and a float being two
    types, lists `"int-float"` as well.
  * `"format-number"` — the `format-number` builtin. Every such case lists
    `"int-float"` too, since the first argument is typed by it.
  * `"round"` — `round`, the tenth arithmetic builtin. It is a name of its
    own, beside `"arithmetic"`, because some implementations provided
    `"arithmetic"` when the profile had nine names. Every such case lists
    `"arithmetic"` and `"int-float"` too, and an implementation provides
    `"round"` only together with `"arithmetic"`.

  A case without `profiles` runs everywhere, with no profile on. A case that
  lists several names runs only where all of them are provided. `mode` is
  not a profile and is unchanged.

  `profiles` replaces the earlier `requires` list, which said what an
  implementation had to support without saying what to turn on. The names
  carried over unchanged, so a case written with `"requires"` is migrated by
  renaming the key. A runner refuses a case that still has a `requires` key
  rather than running it without its gate.

  In a case that lists `"int-float"`, the text of a number in `ctx.json`
  and `expected.json` is significant: `3` is an integer and `3.0` a float
  (reference.md §3, node-json.md *Numbers*), so the two are different
  contexts and different expected values. A runner that provides
  `"int-float"` reads both files with a parser that keeps that difference,
  and one that provides `"int64"` keeps the digits of an integer beyond
  2^53 as well. These files are written by hand; do not regenerate them
  with a tool that rewrites numbers.

## Analysis cases

A case with `"expect": "analysis"` checks the static analyses of
reference.md §9, which answer from the program text alone. It has a
`template.tramaj`, an `analysis.json`, and `libs/` when a deep variant needs
a library table; it has no `ctx.json`, no `expected.json` and no `mode`.

`analysis.json` is an object. Each key is the name of an analysis, as
reference.md §9 spells it, and each value is the expected result as an
array:

```json
{
  "arithmeticOps": ["floor", "sum"],
  "deepArithmeticOps": ["floor", "negate", "sum"]
}
```

A set of names is an array of strings and a set of paths an array of arrays
of strings (`[["spec", "replicas"]]`). The array is written sorted, strings
by code point and paths element by element, so that the file has one
spelling. A runner compares it with the result as a set, and refuses an
array that repeats an element.

The analyses a case may name:

| name | result | provided by |
|---|---|---|
| `staticImportNames`, `transitiveImportNames` | names | all six |
| `staticActionKeys`, `deepActionKeys` | names | all six |
| `contextHoles`, `deepContextHoles`, `contextReads` | paths | all six |
| `arithmeticOps`, `deepArithmeticOps` | names | PureScript, Haskell, TypeScript |

A runner runs the case when its implementation provides every analysis
named in `analysis.json` (and every profile in `profiles`, as for any case),
and skips it otherwise. A case should therefore name analyses that the same
implementations provide: one that adds `arithmeticOps` to a case about
imports takes that case away from three runners.

The arithmetic analyses do not need the arithmetic profile, and their cases
do not list it: nothing is evaluated, and `deepArithmeticOps` is what a host
without the profile uses to refuse a program up front.

`unsuppliedParams` has no case shape yet: its result is a list of pairs,
not a set.

## Skipped cases

Each runner holds the list of profiles its implementation can provide, next
to the code that reads `meta.json` (`providedProfiles`, or the same name in
the language's own spelling), and the table of analyses beside it
(`providedAnalyses`):

| implementation | profiles |
|---|---|
| PureScript | `base`, `int-float`, `arithmetic`, `int53`, `sort`, `format-number`, `round` |
| Haskell | `base`, `int-float`, `arithmetic`, `int64`, `sort`, `format-number`, `round` |
| TypeScript | `base`, `int-float`, `arithmetic`, `int53` |
| Rust, Go, Python | `base` |

The other four lists do not hold `"sort"`, `"format-number"` or `"round"`
yet, so the cases that list one are skipped by those four suites.

An implementation that gains a capability adds the name there, and the cases
that list it start running in that suite; no case needs editing.

In the Haskell and PureScript implementations the arithmetic profile is an
option of each evaluation, off by default. Their runners turn it on for a
case that lists `"arithmetic"` and leave it off for every other case. The
TypeScript implementation has the same option, with nine names: it provides
`"arithmetic"` and not `"round"`, and its integer range is `"int53"`. The
other three do not implement arithmetic yet, so the ten names are unbound
there whatever a runner does: they run the cases that do not list
`"arithmetic"` and skip the ones that do. When one of them gains the
profile it must come as a per-evaluation option, since its runner has to
keep it off for the cases that do not list it.
`round` is the tenth name under the same option, in the two
implementations that have it.

The expected texts of the `format-number` and `round` cases come from one
reference computation (exact rational arithmetic over the value of each
literal), cross-checked against ECMAScript's `toFixed` below `1e21`, and the
expected output of the other `"sort"`, `"format-number"` and `"round"` cases
was written by hand from specs/reference.md §11. The Haskell and PureScript
implementations, written independently of both, give every one of them.

A name the runner does not know is, by that rule, not provided, so the case
is skipped rather than rejected.

A skipped case is not a passed one, and each runner reports it apart, with
what was not provided (`not provided: int64`, or
`not provided: analysis arithmeticOps` for an analysis):

* PureScript — a `skip - <case> (not provided: ...)` line per case, and the
  summary line counts the skipped cases separately
* Haskell — the example is pending (`# PENDING: not provided: ...`), counted
  in hspec's `N pending`
* Rust — libtest cannot skip part of a test, so the runner writes
  `skipped: <case> (not provided: ...)` lines and a count to stderr,
  uncaptured
* TypeScript — the test is registered with `it.skip`, counted in vitest's
  `N skipped`
* Go — the subtest calls `t.Skip`; `go test -v` lists it as `--- SKIP`
* Python — the test raises `unittest.SkipTest`, counted in `OK (skipped=N)`

`runner-checks/unsupported-profile/` is a case, outside `cases/`, that
lists a profile no implementation will ever provide (`never-declared`) and
whose `expected.json` is wrong on purpose. Each suite has one test that
feeds it to its runner and checks that it is skipped; a runner that ignored
`profiles` would run it and fail. Because the Go and TypeScript checks go
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

A case belongs here only if every implementation that runs it can do so
byte-for-byte identically. Behavior that is legitimately implementation-specific (error
message wording, host-only checks) stays in each suite's own tests.
