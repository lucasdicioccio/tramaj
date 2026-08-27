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
