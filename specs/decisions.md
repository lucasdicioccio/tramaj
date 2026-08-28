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

## 11. Prescribed evaluation order (v3-symbols §4)

`reference.md` §13 left the order in which a call's arguments, an array's
elements, an object's fields and a special form's arguments evaluate
unspecified. v3 removes that freedom: all four evaluate strictly in source
order, left to right, everywhere. Nothing about `reference.md`'s own examples
depended on the freedom being there — no observable difference in a
concrete-mode result follows from picking source order over any other — so
this costs a conforming host nothing.

What earns the decision its own entry is v3, not v2: once evaluation can
*emit* (a constraint, a symbol allocation, a site index), order stops being
purely internal and becomes part of the result. Symbol site numbering
(v3-symbols §1.4) and constraint emission order (§4's dedup, "first position
kept") are both defined in terms of "source order", which is meaningless
unless every implementation evaluates in the same order to produce it. Fixing
the order was therefore a precondition for allocation ids and dedup being
well-defined at all, not an independent stylistic choice — which is why it
shipped in Phase 1, before either.

## 12. Deduplication is by evaluated equality, first position kept

Two emitted constraints with equal name and equal already-evaluated
arguments are one constraint (v3-symbols §4); two symbol-table entries with
the same id are one entry. Both keep the *first* occurrence's position, not
the last and not a stable sort by some other key.

Equality is on the evaluated `Value`, not on the expression that produced it:
`!constraint("k", 1)` and `!constraint("k", $ctx.one)` collide if `$ctx.one`
evaluates to `1`, because what the host receives is one fact stated twice, not
two different facts. This is why dedup happens once, globally, after
evaluation finishes accumulating emissions — folding it into `tellConstraints`
itself would compare not-yet-evaluated expressions and miss exactly the
collisions that matter.

"First position kept" rather than "last" is arbitrary as a matter of the
document's own semantics — a set has no order — but not arbitrary as a matter
of stable, cross-implementation output: fixing *a* rule, and the same rule
everywhere, is what makes two implementations produce byte-identical
envelopes for a program that constrains something twice.

## 13. `canon` is compact JSON with quoted top-level strings, not `str`

An allocation's identity (v3-symbols §1.4) is `#<site>:<canon key>`, where
`canon` is compact JSON with object keys sorted — deliberately *not* `str`
(ref §6's display rendering), even though the two agree on every array and
object. They disagree at exactly one point: `str` renders a top-level string
raw (`str("3")` is the three characters `3`), while `canon` quotes it
(`canon("3")` is `"3"`, four characters including the quotes).

That one point is load-bearing. Allocation identity must be injective: two
different keys must never produce the same id. `str(3)` and `str("3")` render
to the same characters — a number and a string that happen to look alike —
so building an id from `str` would silently merge `?(3)` and `?("3")` into
one variable at the same site. Quoting a top-level string is the smallest
change that restores injectivity without disturbing the one thing `str` and
`canon` are both for elsewhere: nested strings inside an array or object are
already quoted by ordinary JSON encoding, so `canon` and `str` already agree
everywhere except the position `str` treats specially for display.

## 14. v4-types: declarations and annotations stay in the `Let`/`Emit` chain

roadmap-to-v4 Phase 8 posed the choice directly: either a declaration block on
`Program`, or a new constructor nested in the same statement chain `Let` and
`Emit` already occupy. The chain won, for both `TypeDecl` (Phase 8) and, later,
`TypeAnnotate` and `TypeEmit` (Phases 11-12) — every v4 construct that needed a
place in the AST went into the chain rather than growing `Program`.

The consequence stated in roadmap-to-v4 Phase 15 follows directly:
`Program = DocumentProgram Expr | ExpressionProgram Expr` is untouched by v4,
exactly as it was by v3, so every host that pattern-matches `Program` keeps
compiling and **v4 ships as a minor bump**, not a major one. The catch Phase 8
flagged — the chain is lexical and non-recursive by construction, while
`type Tree = | Leaf | Node { l : Tree, r : Tree }` needs `Tree` in scope inside
its own body — is resolved by treating a declaration as gathered, not
evaluated: `Tramaj.Ast.typeDecls` collects every `TypeDecl` in a chain before
`Tramaj.Types.resolveTypeExpr` resolves any of them, so a self-reference is a
lookup against the whole gathered set rather than a scoping problem at all.

## 15. Canonical type ids: a quoted library key, and the bare word `root`

v4-types §3 fixes the grammar `ref ::= library ":" name [...]` and its own
worked examples insert `library` — an arbitrary host-chosen `staticString` —
unquoted. Doing that literally breaks injectivity for the one case those
examples never exercise: a declaration with *no* importing library at all (an
ordinary `type X = ...` in the program being resolved, not reached through any
`import`). That case needs some token for "no library", and no bare word is
safe for it, because a library can legally be named `"root"`, or even `""` —
`staticString` forbids only a literal `"` or a backtick.

The fix follows from that one forbidden character. Every real library key is
wrapped in a literal pair of quotes in the rendered id (safe, and injective,
precisely because a key can never itself contain one), and the bare, unquoted
word `root` is reserved for "this program, not a library" — a token no quoted
key can ever equal, since a quoted key always begins with `"`. `name` itself
is never quoted: the grammar already guarantees it is a colon-free identifier
(`Tramaj.Parser`'s `typeField`, tightened in the same phase to reject a
quoted-string field name for exactly this reason), so `library <> ":" <> name`
is unambiguous to split however many colons `library` contains.

## 16. A `Ref`'s arguments include every unsupplied type parameter, as a hole

roadmap-to-v4 Phase 10 builds a `Ref`'s `arguments` map from the target
library's own type parameters (`typeParams`), not from what a particular
import happens to supply. An unsupplied parameter still gets a slot in the
map — rendered as its own `RVar`, the same shape a bare `%ctx.path` hole
renders as — rather than being silently omitted.

This was not the first attempt: omitting an unsupplied argument is simpler and
matches every worked example that happens to be fully applied, but it breaks
v4-types §4's own promise. `requireClosed` (the `PartialType` check) walks a
resolved type looking for a `Var` anywhere, including inside a `Ref`'s
arguments — an omitted argument is invisible to that walk, so a reference to a
library still missing a parameter would silently pass as closed. Filling the
slot with `RVar` is what makes §3's own worked example (`payload=%ctx.p`,
explicitly shown *with* an unfilled argument) the actual behavior rather than
an illustration of a case the implementation could not otherwise produce.
