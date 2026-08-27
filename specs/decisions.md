# Tramaj — resolved spec conflicts (v2 iteration, 2026-08-27)

`specs/archive/core.md`, `specs/archive/merged2.md`,
`specs/archive/constraints.md` and `specs/archive/value.md` are overlapping
drafts that contradict each other in several places. This document
records which reading won for the v2 implementation, so the next reader does not
re-derive them from four drafts.

This file records *why* each conflict was resolved the way it was.
`specs/reference.md` records *what* the language actually is, and is the
document to read first; `specs/node-json.md` is normative for the output
representation.

(All of these now live in `specs/archive/`, with a README of their own.
`constraints.md` is `merged2.md` with an older §17; `merged2.md` supersedes it
entirely. `llm.md`, `templating-language.md` and `position.md` describe the v1
language; `v2.md` and `merged.md` are earlier v2 sketches.)

## 1. Documents are expressions

`Element` and `Fragment` are `Expr` constructors. The v1 split between a
computation-phase `Expr` and a template-phase `TemplateNode` is gone, along with
the separate template-phase `map`/`branch`/value forms. A document node is an
ordinary value: bindable, passable, returnable.

This closes the `limitations` entry "node in the computation block".

## 2. Imports: `FromContext`, and no `PartialImport`

merged2 §17 wins over the `PartialImport` constructor still listed in core.md and
in merged2's own §23 AST dump (both stale).

One `Import(name, parameters)` constructor. Each parameter is either `Expr(e)` or
`FromContext(path)`. An import is *partial* exactly when it still has unresolved
`FromContext` parameters — partiality is declared, not inferred.

This deletes v1's `tryPartial` heuristic, which decided an import was partial by
catching a `PathNotFound` whose path began with `ctx`. It also makes the set of
values a program needs from its completion context statically computable
(`contextHoles`), which `specs/laws.md` asks for under "bubbled up context holes".

Consequence: a genuinely missing `$ctx.x` inside a library is a hard error again,
rather than being silently reinterpreted as "this import must be partial".

**Superseded by §10**, which keeps one `Import` constructor and the
`FromContext` parameter but reverses what `ctx(path)` *means* and what makes an
import partial.

## 3. `branch` is uniformly lazy

core.md wins over merged2 §13/§14's lazy-template / eager-expression split. That
split keyed on a document/expression distinction that no longer exists once
documents *are* expressions (§1 above).

One core `Branch(condition, then, else)`; only the selected arm is evaluated, in
every position. The surface form `branch(fallback, p1, v1, p2, v2, ...)` desugars
to nested `Branch`, and `branch` is no longer an ordinary builtin.

## 4. Fragments are `.(...)`, `<>` is concat

merged2 spells concat `a <> b` (§18) and opens a fragment with `<>` (§10). Those
collide.

Concat keeps `<>`. A fragment is written `.(child, child)` — a tagless element,
reusing the `.` document leader, unambiguous with everything else in the grammar.

## 5. Node has three constructors, with two value slots

value.md gives `Node` six constructors (`Null`/`Boolean`/`Number`/`Text`/
`Element`/`Fragment`); merged2 §1 gives three (`Text`/`Element`/`Fragment`).

Resolution: three constructors, with enough expressivity inside them to carry what
value.md's scalar constructors carried —

- the text leaf carries a `Value`, not a `String`, so a number child stays a
  number (value.md's "scalar values without implicit conversion");
- `Element` gains a `value: Value` slot alongside its children.

See `specs/node-json.md` for the normative shape. Also settled there: attribute
values are arbitrary `Value`s rather than display strings, an element may carry
many actions rather than at most one, and every node carries an annotations map.

## 6. `adapt-actions`: static prefix, closure for the payload

core.md's `ActionAdaptation = Identity | Prefix String` wins for the **key**: the
prefix is a static string literal, so the full set of action keys a subtree can
produce is computable without evaluating anything.

The rewriting **closure is retained** as an optional third argument, for
`eventType` and `payload` only — v1 use cases transform a payload as a function of
the original action, which a closure-free adaptation cannot express. A `key` field
in the closure's result is ignored; the prefixed key always wins.

## 7. Surface sugar in scope for v2

In: string escape sequences (the open `limitations` entry), object shorthand
`{foo, bar}`, unquoted object keys, and the `<>` concat operator.

Deferred: destructuring in `let`/lambda parameters (merged2 §19 calls it planned;
it is pure desugaring and can land later without touching the core AST).

## 8. Smaller calls made from the specs

- **An action's event is a static string literal**, matching `Action event:
  String` in both core.md and merged2 §23. In v1 it was an arbitrary expression.
  The host still owns the event *vocabulary*; only the position is static.
- **String interpolation desugars away.** core.md: interpolation "does not require
  a separate AST node". `"a `$x` b"` lowers to `Concat` over a `str(...)` builtin,
  so `StringPart` is not part of the core AST.
- **Lambdas keep multiple parameters** (merged2 §7) rather than core.md's single
  `parameter`: `fold`/`scan` need `(acc, item)` and the language has no currying.
- **Builtins are values in the initial environment.** merged2 §23 allows either a
  dedicated constructor or ordinary calls; making them values keeps `Call`
  uniform and lets a builtin be passed by reference, e.g. `map($xs, $not)`.

## 9. Comments are `--` to the end of the line

This reverses a v1 decision rather than resolving a conflict between drafts:
`archive/llm.md` §"no comments" states that nothing is stripped and that `--`
is a parse error. It was a defensible v1 position — a template written by a
generator has no author to leave notes for — but v2's programs carry
bindings, lambdas and imports, and the drafts' own examples annotate them
with `--` because there is nothing else to reach for.

`--` and not `#`, `//` or `;`: the drafts, the reference and this repository's
README were already writing `--` in every commented example, so the syntax
was chosen years before it was implemented. It also costs nothing in the
grammar — no expression begins with a hyphen, because there is no arithmetic
and no negative literal (§11, §14 of the reference).

Single-line only, and deliberately so. A block form buys little in a language
whose programs are this short, and costs a nesting rule, an
unterminated-comment failure mode, and a second place where `--` inside a
string has to be reasoned about.

The one thing it did cost: names now refuse a *trailing* hyphen. Both
implementations previously read a name as a letter followed by any run of
name characters including `-`, so `$x-- note` lexed as a name `x--`, silently,
even though the reference has always said hyphens are *internal*. Enforcing
what the reference said is what keeps a comment written hard against a name
from being swallowed by it.

## 10. `ctx(path)` substitutes at the wiring site; omission is what defers

This reverses §2's reading of `FromContext`, keeping its AST and its static
analysis and changing its semantics.

Under §2, `ctx(path)` declared a hole to be filled by a *completion context*:
the import evaluated to a partial value, and calling it with an object read
each declared path out of that object. The ambient `$ctx` was never consulted,
which made `ctx(foo)` and `$ctx.foo` name entirely different things.

Two problems showed up in use. The first is that the obvious reading of
`import("hello", {foo: ctx(foo)})` — *pass my own `$ctx.foo` through* — was
not the implemented one, and the failure mode was silent: a completion context
carrying a different key left the parameter deferred, and the error surfaced
much later, as `.rendered` on something still partial. The second is that the
"bubbled up context holes" the laws ask for did not actually bubble anywhere.
A hole belonged to the import's own completion context, so a library's holes
and its importer's holes were unrelated sets that `deepContextHoles` could
only union and hope the reader interpreted correctly.

So `ctx(path)` now reads the importing program's own context, at the point the
import is written, and means exactly what `$ctx.path` means. The AST node and
`contextHoles` survive unchanged, and they are the entire justification for the
form: a path in a static position is a hole an analyzer can enumerate, where
the same read inside an arbitrary expression is not. `ctx(...)` buys static
visibility and nothing else, and that is a fair trade to state plainly rather
than dress up as a second kind of context.

What then defers an import is **omission**: a parameter the import does not
list, supplied later by calling the import value with more parameters,
right-biased. This is not v1's `tryPartial` heuristic returning — nothing
catches a `PathNotFound` and reinterprets it as partiality. It is simpler than
either: an import accumulates parameters, and running it is a separate event.

That event is **reading a field off it**. An import runs at `.rendered` or
`.vals`, not where it is written, which is what makes one wired-up import
reusable across a `map` with each iteration supplying its own parameter. The
evaluator therefore keeps no notion of "still missing": there is no list of
what a library needs, and it does not compute one. A library that reads a path
nobody supplied fails with its own `PathNotFound`, wrapped in the new
`InLibrary` error naming it. Deciding statically what is missing is
`Tramaj.Analysis`'s job (`contextReads`, `unsuppliedParams`), where an
over-approximation is useful and cannot break a program that would have run.

Consequences worth stating: an import parameter that is simply absent is no
longer an error at all, reversing §2's last paragraph; `ctx(path)` where the
context lacks the path *is* an error, at the import rather than inside the
library; and `PartialImport` in the value domain became `Import`, an import
that has not run yet, which every import is until a field is read off it.
