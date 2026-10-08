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
Designed in §17 below; not implemented.

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

## 17. Destructuring binding patterns: object patterns only, pure desugaring

*Status: proposed, for owner review. Nothing here is implemented; `specs/reference.md` §8/§14 keep calling destructuring deferred until a port lands.*

§7 deferred destructuring as "pure desugaring". This section pins down what that
means, because two facts about the language constrain it. Field access is
`walkFields`, which reads **objects only** (an array segment is a `TypeMismatch`),
and the only way to reach an array element is `lookup(container, key, fallback)`,
whose fallback is mandatory. So a pattern can be faithful to an ordinary `$x.a`
read for objects, and cannot be for arrays.

**Scope.** Object patterns, in two positions: an `@` binding and a lambda
parameter (so also the lambdas passed to `map`/`filter`/`scan`/`fold`). Not in
`import` parameters, not in `value(...)`.

```
pattern ::= name | "{" field { "," field } "}"
field   ::= name                 -- reads the field of that name, binds it to that name
          | name ":" pattern     -- reads the field, binds/destructures it as `pattern`

@{title, kind: k, meta: {owner}} = $ctx.item
@row=({title, kind}) => .li("`$title` (`$kind`)")
```

`{name}` is the same shorthand as the object literal's `{foo}`; `{bar: baz}`
reads field `bar` and binds `baz` (the JS reading, not the object literal's:
in a literal the right side is an expression, in a pattern it is a pattern).
`@{` cannot be confused with `@name` since a name starts with a letter.

**Desugaring** (the core AST does not change):

- `@{a, b: c} = e` then `rest` lowers to `Let "a" (e.a) (Let "c" (e.b) rest)`,
  fields in written order. When `e` is a path (`$ctx.item`), the reads are the
  extended paths (`$ctx.item.a`), so a missing field raises the same
  `PathNotFound ["ctx","item","a"]` a hand-written read would, and
  `contextHoles`/`unsuppliedParams` see the same reads they see today. When `e` is
  anything else (a call, a literal), it is bound once to a hidden name and the
  reads go through it.
- A nested pattern desugars the same way against the sub-path.
- A lambda `(p1, p2) => body` lowers to `Lambda [h1, h2] body'` where a pattern
  position gets a hidden parameter name and `body'` is `body` wrapped in the
  lets above. Arity is unchanged (a pattern takes one position), so arity errors
  and `map`'s per-element binding are unaffected.
- Hidden names must not be writable by the surface grammar (a name is letters,
  digits, `_` and internal `-`); each port picks its own spelling. A hidden
  binding is never reported as a symbol's `"binding"` (v3-symbols §5.2) and never
  appears in an error path except through the temp case above.

**Semantics** are exactly those of the reads it lowers to: a field the value
lacks is `PathNotFound`; a non-object source is `TypeMismatch`; extra fields are
ignored; a symbol source projects (v3-symbols §1.6), since a projection is a path
read. Static analyses, node JSON and the v4 `@x : T = e` sugar are untouched.
An annotation on a pattern (`@{a} : T = e`) is a parse error in this pass.
Duplicate names within one pattern are a parse error; shadowing an earlier
binding follows the ordinary `Let` rules.

**Rejected or deferred**

- *A core `LetPattern` constructor.* Would put a change in every port's
  evaluator, analyses and node model, which is what "desugaring only" avoids.
- *Array patterns `[x, y]`.* The only element read is `lookup` with a mandatory
  fallback, so the lowering would silently turn a missing element into a value
  instead of failing. Wait for an index read that fails like `PathNotFound`.
- *Defaults `{a = 1}`.* Expressible later as `branch(1, has($s, "a"), $s.a)`, but
  it needs a decision on whether `null` counts as present.
- *Rest `{a, ...r}`.* Needs "object without these keys", which no builtin
  provides.
- Reserve `=` and `...` inside a pattern as a parse error with a clear message,
  so defaults and rest stay available later.

**Follow-up once approved:** the parser change in the PureScript reference, then
`tramaj-hs`, `tramaj-rs`, `tramaj-js` and `tramaj-py`; corpus cases for a bound
field, a renamed field, a nested pattern, a lambda parameter (also under `map`),
a missing field, a non-object source, a symbol source, a call as source, a
duplicate name and a rejected default/rest; then `reference.md` §8/§14 and
`final-touches.md`.

**Questions for the owner.** (1) Object-only scope, with array patterns waiting
on a failing index read. (2) `{bar: baz}` as the rename spelling. (3) Annotated
patterns rejected for now. (4) Reserve default and rest syntax as a parse error.

## 18. Arithmetic: integers and floats as two types, nine named builtins, no operators, and a term for what a symbol leaves unevaluated

*Status: accepted by the owner on 2026-10-06, with the decisions listed at the end. The normative text is written: `reference.md` §3, §5, §6, §9, §11 (*Arithmetic*), §12 and §13; `node-json.md` (*Numbers*); `v3-symbols.md` §1.1, §1.4, §1.5, §1.9, §5.2 to §5.5 and §6 to §9; `v4-types.md` §1; `laws.md`. Nothing here is implemented in any port, and each of those passages says so.*

`reference.md` §11 states that a template "compares and selects, it does not
compute", and §5 and this file's §9 lean on it. This section proposes to
reverse that position, so it records why first.

**Why reverse it.** The position assumed that every derived number can be
computed by whoever builds the context. That holds when the host and the
template author are the same party. It fails when they are not: a template
handed a set of counters by a host it does not control cannot show a subtotal,
a share in percent or a bar width unless someone upstream precomputes each one
and stores it next to the raw numbers. The template then depends on a second
program staying in step with it, which is the coupling a template language
exists to remove. The reversal is narrow: the *grammar* does not change at all.

**Two number types.** Arithmetic is where "numbers are doubles" (ref §13)
stops being good enough: a counter must add exactly and a ratio must not. The
value domain's `Number` therefore splits in two, and nothing converts between
them unless the program says so.

- An **integer** is a signed whole number, held exactly. Every port MUST
  cover the **guaranteed range**, `-(2^53 - 1)` to `2^53 - 1`, which is the
  set of integers a double holds without ambiguity, so a port on JavaScript
  can keep an integer in a `number` and test a result with
  `Number.isSafeInteger`. A port SHOULD cover the full signed 64-bit range,
  `-2^63` to `2^63 - 1`, and MUST NOT go beyond it. A port's range is one of
  those two, and it documents which.
- Inside the guaranteed range all ports agree. Between the two ranges a port
  either holds the value exactly or refuses it, and never rounds it; which of
  the two is implementation-defined (ref §13), and a portable program stays
  inside the guaranteed range. Outside 64 bits every port refuses.
- A **float** is an IEEE 754 binary64, finite, with no negative zero (ref §5).
- *Literals need no new syntax.* The grammar of ref §5 is unchanged; what a
  literal denotes now depends on its form. One with neither a fraction nor an
  exponent is an integer (`1`, `-7`, `1_000_000`); one with either is a float
  (`1.0`, `-1.5`, `1e5`). An integer literal outside the port's range is a
  parse error, as `1e400` already is. The sign is part of the literal, so
  `-9223372036854775808` is in the 64-bit range.
- *A JSON number is read by the same rule*, applied to its text: `3` is an
  integer, `3.0` and `3e0` are floats. An integer-form number outside the
  port's range is rejected rather than rounded. This holds for the context, for
  library parameters and for a seeded value.
- *Serialization keeps the type.* Wherever a value is written as JSON (the
  `Node`, the symbolic envelope, canon), an integer is written as decimal
  digits and a float always carries a fraction or an exponent: the shortest
  round-trip text of ECMAScript's `Number::toString`, with `.0` appended when
  that text has neither (`1.0`, `100000000000.0`, `1e+21`, `0.1`). `str`
  follows the same rule, so `str(1)` is `1` and `str(1.0)` is `1.0`. This
  changes today's rendering of a whole-valued float and of nothing else.
  Canon stays injective (v3-symbols §1.4), which it must, since `1` and `1.0`
  are now two values.
- *`eq` and the comparisons follow their existing rules.* `eq` does not
  coerce across types, so `eq(1, 1.0)` is `false`, like `eq(1, "1")`.
  `lt`/`lte`/`gt`/`gte` take two integers or two floats, and a mixed pair is a
  `TypeMismatch`, like any other mixed pair (ref §6).
- *v4-types.* §1's primitive `number` splits into `int` and `float`. Its
  stated reason for leaving `Int` out was that the value domain had no such
  boundary; it now has one.

The cost of the JSON rule is that the type of a context number is decided by
whoever serialized it, and a producer whose language has one number type
writes the float `3.0` as `3`. A template that expects a float from a host it
does not control therefore normalizes at the point of use, with `real`, which
accepts either type. The alternative, promoting an integer silently when it
meets a float, is the conversion this section declines: it is inexact above
`2^53`, and it would make the type of a result depend on the data.

A port whose host passes native values rather than JSON text maps its native
integer and float types to the two types. A port on JavaScript must say how it
classifies a `number`, and must read JSON text with a parser that keeps
integer digits past `2^53`. Both are that port's binding and are not
normative here; the corpus is JSON text and follows the rule above.

**Scope.** Nine builtins, as ordinary names in the initial environment. No
infix operator, no new leader, no new literal form.

| builtin | arity | operands | concrete result |
|---|---|---|---|
| `sum(…)` | one or more | all integers or all floats | left fold of `+` |
| `product(…)` | one or more | all integers or all floats | left fold of `*` |
| `negate(x)` | 1 | integer or float | `-x`, of the same type |
| `quotient(a, b)` | 2 | two floats | `a / b`, correctly rounded |
| `inverse(x)` | 1 | float | `quotient(1.0, x)`, by definition |
| `floor-quotient(a, b)` | 2 | two integers | the largest integer not above `a / b` |
| `modulo(a, b)` | 2 | two integers | `a - b * floor-quotient(a, b)` |
| `floor(x)` | 1 | float or integer | the largest integer not above `x`, as an integer |
| `real(x)` | 1 | integer or float | the float nearest to `x` |

```
@subtotal = sum($ctx.compute, $ctx.storage, negate($ctx.credit))
@share    = branch(0, gt($ctx.total, 0),
                   floor-quotient(product(100, $ctx.used), $ctx.total))
@stripe   = branch("odd", eq(modulo($i, 2), 0), "even")
@total    = sum(0.0, map($ctx.lines,
                         (l) => product(real($l.qty), real($l.price))))
```

- *`real` and `floor` are the only conversions*, one in each direction, and
  each accepts both types so that it can normalize a number of unknown type:
  `real` of a float and `floor` of an integer are the identity. `real` of an
  integer is exact inside the guaranteed range; beyond it, on a 64-bit port,
  it rounds to nearest, ties to even.
- *Subtraction is not a builtin.* Negation is exact for a float, so
  `sum(a, negate(b))` is bit for bit `a - b`. For integers the guaranteed
  range is symmetric, so the same holds; on a 64-bit port the two differ for
  the single operand `b = -2^63`, whose negation is out of range. A
  `difference` would add a name for that one value.
- *Float division is a primitive, although it was not asked for by name.*
  `product(a, inverse(b))` rounds twice where `a / b` rounds once, and the
  results differ: `product(49.0, inverse(49.0))` is `0.9999999999999999`, so
  `floor` of it is `0`; 98, 103 and 107 behave the same way. `quotient` is
  therefore the primitive and `inverse(x)` is defined as `quotient(1.0, x)`,
  which keeps the requested name and its meaning.
- *Integer division has its own name.* `quotient` over two integers is a
  `TypeMismatch` and does not mean floored division. If one name covered
  both, `quotient($ctx.used, $ctx.total)` would be `0.5` or `0` depending on
  whether the producer wrote `1.0` or `1`, with no error either way.
  `floor-quotient` rounds toward negative infinity, which agrees with `floor`.
- *`modulo` is its remainder*, so `a` is always
  `b * floor-quotient(a, b) + modulo(a, b)` and the result is zero or has the
  sign of the divisor. It is expressible from the other builtins, as
  `sum(a, negate(product(b, floor-quotient(a, b))))`, and is a builtin
  because that is too long to write correctly each time a template stripes
  rows or groups items.
- *Rejected: a `divmod` returning both.* Over a symbol it would be a term
  standing for a pair, and a term has no projection (below). Reading the pair
  would also need an object pattern, since array patterns are not available
  (§17).
- *`inverse` takes a float only.* The inverse of an integer is not an integer
  except for `1` and `-1`.
- *Rounding to nearest and decimal formatting are left out.* They are display
  concerns and belong to the number-formatting work;
  `floor(sum(x, 0.5))` only approximates rounding (it is wrong for the double
  just below `0.5`).
- *`min` and `max` are left out of this cut.* `fold` with a `branch` covers
  the concrete case. Adding them later is compatible: they would refuse an
  empty call as `sum` does.

The existing `-` rule is untouched: `-` stays part of a number literal, `--`
stays a comment, `<>` stays the only infix operator, and §9's argument that no
expression begins with a hyphen still holds. Only the parenthetical in ref §5
("there is no arithmetic") needs rewording to "there are no arithmetic
operators".

**Arrays as arguments.** `sum` and `product` flatten their arguments by the
rule children (ref §6) and `!` (v3-symbols §2.2) already use: an array
contributes each of its elements, recursively, in order. So `sum($xs)`,
`sum(1, $xs, 2)` and `sum([1, [2, 3]])` are all legal.
There is no spread syntax and this does not add one; a separate
`sum-of(array)` form would make the author pick a spelling by the shape of the
data, and the language already answers "an array in a sequence position is a
sequence" twice. The seven fixed-arity builtins do not flatten: `negate([1])`
is a `TypeMismatch`, and `map($xs, $negate)` is the way to write it. `and`,
`or` and `concat` are unchanged.

An empty `sum` or `product` has no operand to take a type from, so it is a
`TypeMismatch`: `sum()`, `sum([])` and `product([[]])` alike. A fold over a
list that may be empty is seeded with the identity of the intended type,
`sum(0, $xs)` or `sum(0.0, $xs)`, as in the example above. Returning an
integer `0` instead would give a float total the wrong type on empty data
only, which is the kind of failure the seed makes impossible.

**Optional, but builtin: a profile.** Arithmetic is a third profile next to
v3-symbols §5.5's core and symbolic ones, and independent of both. The two
number types are not part of it: they belong to the value domain in every
profile.

- An implementation with the **arithmetic profile** puts the nine names in
  the initial environment. One without it does not, and a program that uses
  one fails with the existing `UnboundName`. No new refusal mechanism is
  needed, and none at parse time is possible: these are names, not syntax, and
  `@sum = …` may legitimately bind one.
- Because builtins are ordinary bindings, a program that already binds `sum`,
  `floor` or any of the others (a binding, a lambda parameter, a pattern name)
  shadows the builtin and behaves exactly as before. Adding the names breaks
  no existing program.
- A new static analysis, `arithmeticOps` with a deep variant, reports which of
  the nine names a program references **free**, called or passed by reference
  (`fold($xs, 0, $sum)`). It is scope-aware, so a shadowed name is not
  reported, and it over-approximates like every analysis in ref §9. A host
  without the profile refuses a program up front when `deepArithmeticOps` is
  non-empty, the same way `deepConstraintKinds` is used.

*Rejected: a reserved library, `import("math", {})`.* Its optionality story is
the cleanest available, since `UnknownLibrary` and `staticImportNames` already
exist. It costs every call three segments (`$m.vals.sum(…)`), needs an import
with an empty parameter object, would be the first library that cannot be
written in Tramaj, and takes a name out of the host's library table, which
ref §7 gives to the host entirely.

**Concrete semantics.** These are the rules that make six ports agree byte for
byte.

1. *No coercion and no promotion.* An operand that is not a number is a
   `TypeMismatch` (`sum(1, "2")`, `sum(null)`, `negate(true)`), like `eq`'s
   refusal to equate `1` and `"1"`. So is a number of the wrong type
   (`sum(1, 1.5)`, `quotient(1, 2)`, `floor-quotient(1.0, 2.0)`, `inverse(2)`), and so is
   a wrong argument count for a fixed-arity builtin, and so is a `sum` or
   `product` with no operand after flattening. All operands are checked,
   in flattened order, before anything is computed, so
   `sum(1e308, 1e308, "a")` is a `TypeMismatch` and not a `NotRepresentable`.
2. *Integer arithmetic is exact or it is an error.* `sum` and `product` are a
   left fold over the flattened operands, starting from the first, and every
   step is checked: `sum(a, b, c)` is `(a + b) + c`. A step whose mathematical
   result is outside the port's range is a `NotRepresentable`, and nothing
   wraps, saturates or rounds. The check is per step, so
   `sum(9223372036854775807, 1, -1)` is an error on every port although its
   total is in the 64-bit range. The same kind covers `floor-quotient(x, 0)`
   and `modulo(x, 0)` and, on a 64-bit port,
   `negate(-9223372036854775808)` and
   `floor-quotient(-9223372036854775808, -1)`. A port that keeps integers in doubles can
   implement the check as "the computed result is not a safe integer": a sum
   or product of two safe integers that leaves the guaranteed range rounds to
   a double of magnitude at least `2^53`, which is never one.
3. *Float arithmetic is one correctly rounded operation at a time*, round to
   nearest, ties to even, over the same left fold. No pairwise or compensated
   summation, no reordering, and no fused multiply-add: a port whose compiler
   may contract `a * b + c` must prevent it.
4. *A non-finite float result is a `NotRepresentable`* as well. NaN and the
   infinities are not JSON and are not values. This covers `inverse(0.0)`,
   `quotient(x, 0.0)`, `quotient(0.0, 0.0)` and overflow with one rule and no
   test for a zero divisor. Once a fold's running value is non-finite it stays
   so, so checking the final result is equivalent to checking each step.
   Underflow is not an error: the result is the nearest double, which may be
   zero, as for a literal (ref §5).
5. *There is no negative zero.* A float result that is zero is `0.0`, as for
   literals: `negate(0.0)` is `0.0`, and so is `product(-1.0, 0.0)`.
6. *The conversions.* `floor` of a float whose floor is outside the port's
   integer range is a `NotRepresentable`: `floor(1e19)` on every port,
   `floor(1e16)` on a 53-bit one. `real` never fails: every integer has a
   nearest double, and it is finite.
7. *`str` renders what the value is*, so `sum(0.1, 0.2)` interpolates as
   `0.30000000000000004` and `sum(0.5, 0.5)` as `1.0`. Hiding either belongs
   to formatting, not to arithmetic.

`NotRepresentable` is the one new error kind: the operation has no result in
the type of its operands. Division by a value that happens to be zero at
render time is the case a template will meet in practice (an empty counter).
It is an error rather than `null` or `0` because either of those would flow
into the document as a plausible-looking answer. The guard is the lazy
`branch` shown above, whose unselected arm is never evaluated (ref §6).

**Symbolic semantics.** v3-symbols §1.5 makes everything that inspects a symbol
`NotConcrete`, and §9 declined symbolic strings because "the value domain would
gain terms, not just variables". Arithmetic over a symbol is that step. Three
ways to take it:

- *(a) A term in the value domain.* `sum(1, $s, 2)` evaluates to a value that
  records the operation and its operands.
- *(b) A derived symbol plus an emitted constraint.* `sum($a, $b)` yields a
  fresh symbol and emits a constraint relating it to its operands, so the value
  domain stays term-free.
- *(c) Two libraries with the same names*, one concrete and one symbolic,
  chosen by the author.

**Recommended: (a).**

(c) is ruled out by v3-symbols §5.1: a library written against `?ctx.path` must
run whether its caller supplied a number or a symbol, so its author cannot know
which library to call. It is also the eye strain the request asked to avoid.

(b) keeps the value domain flat, which suits a solver, but breaks four rules
the language holds elsewhere. The derived symbol needs an id that is identical
across ports, and a builtin has no site (it can be passed by reference and
called under `map`), so the id would have to be the canonical rendering of the
operation and its operands: the term, hidden in a string the host must parse.
A builtin would emit, where today only `!` does and a constraint never reached
by a `!` is discarded (§2.2). A library doing arithmetic on a symbolic
parameter would mint symbols, against §1.4's "only a root program may
allocate". And the language would claim constraint names (`"sum"`) in a
vocabulary §0 gives wholly to the host.

(a) costs one new tagged shape. What distinguishes it from the declined
symbolic strings: text had a better alternative (separate children, §1.8, which
a form renderer wants anyway) and numbers have none; and the vocabulary is
closed, nine operations whose meaning the language itself defines, so a term is
not host vocabulary. It is the computation the language would have performed
had it known the operands, handed over undone.

```text
Value
  = ...
  | Term  op: String, arguments: List<Value>   -- arguments: numbers, symbols, terms
```

- A call to one of the nine builtins whose flattened operands are all numbers
  computes, as above. If at least one operand is a symbol or a term, the result
  is a `Term` with that `op` and **the flattened operands exactly as written**:
  same order, nothing folded, nothing simplified, no nested term spliced.
  `sum(1, $s, 2)` is `sum(1, $s, 2)`, not `sum($s, 3)`; `inverse($s)` is
  `inverse($s)`, not `quotient(1.0, $s)`.
- Preserving rather than folding is forced by both types: `(1.0 + s) + 2.0`
  and `s + 3.0` are different doubles for some `s`, and for integers one
  grouping can overflow where the other does not. It buys the **residual
  law**: a host that evaluates a term by the concrete rules above, after
  substituting numbers for its symbols, gets byte for byte what the program
  would have produced had those numbers been in the context, errors included.
  It also keeps the promise of §0 that Tramaj solves nothing, and it is the
  least code in six ports.
- A symbol operand stands for one number of either type, and a term carries no
  type. Concrete operands are checked as far as they can be without it: each
  must be a number, and those of one call must agree with each other and with
  what the builtin accepts, so `sum("a", $s)`, `sum(1, $s, 2.0)` and
  `quotient(1, $s)` are `TypeMismatch`. Nothing is inferred through a symbol
  or a nested term: `sum(real($s), 1)` is built, and fails when the host
  evaluates it, as the residual law says it should. `inverse($s)` is a term
  even if the host later supplies `0.0`, and the author who cares writes
  `!constraint("ne", $s, 0.0)` in the host's vocabulary.
- A term is data, exactly as a symbol is (§1.5): it may be bound, passed,
  stored, placed in an attribute, a payload, a value slot or a text child, used
  as a constraint argument, and used as an operand. `constraint("lte",
  sum($a, $b), 10)` is the point of the exercise.
- Everything that inspects refuses, as for a symbol: `branch`, `eq`, `lt`,
  `lte`, `gt`, `gte`, `str` and interpolation, `cardinality`, `has`, `lookup`,
  `<>`, a `map` spine and an allocation key are `NotConcrete` on anything
  containing a term. The comparisons do **not** become symbolic: a boolean term
  could only feed `branch`, and control flow must be concrete.
- A term has no projection. `$t.field` is a `TypeMismatch`, since a term stands
  for a number and a number has no fields.
- A symbol operand counts as one number. A symbol standing for a whole array
  cannot be summed; that is §1.7's ceiling, unchanged.
- Equality of terms, for constraint deduplication (§4), is structural:
  `sum($a, 1)` and `sum(1, $a)` are two terms.
- Concrete mode is untouched. No symbol can exist there (§5.1), so no term can.

**Envelope.** The value domain gains a third tagged shape:

```json
{"$term": "sum", "arguments": [1, {"$sym": "#0:\"s\"", "path": []}, 2]}
```

- Numbers inside a term are written by the serialization rule above, so `1`
  and `1.0` stay distinct. The residual law depends on it, and a host that
  evaluates terms must read them with a parser that keeps the difference.
- Both fields are required. `"$term"` joins `"$sym"` and `"$type"` as a key
  reserved in the value domain in both modes and all profiles (§5.3): a parse
  error in a program, rejected in a context unless it is a well-formed term in
  symbolic mode. Well-formed means a known `op`, the right argument count, and
  arguments that are numbers, symbols or terms with at least one symbol
  somewhere inside. Seeding (§5.4) accepts it on those terms.
- The envelope's own fields do not change, and the format stays
  `tramaj/symbolic/1`, following v4-types §8. A term can reach a host only if
  that host enabled the arithmetic profile, which is the host changing its
  mind in §5.2's sense, and `deepArithmeticOps` tells it beforehand which
  operations can appear.
- No list is added. A term is carried where it is used; it is not an entity
  with an identity, so it has no table.

**Follow-up.** This is two pieces of work. The number split lands first, on
its own, in every port; the builtins follow. The split does not depend on the
arithmetic profile, and until the builtins land a program has no conversion
between the two types, so no release should fall between the two where that
can be avoided.

*The number split* touches every port and existing fixtures. Normative text:
ref §3 (the value domain), §5 (what a literal denotes), §6 (`str`, `eq`, the
comparisons), §13 (the precision entry becomes the integer range); `node-json.md` and
v3-symbols §1.4 for serialization and canon; v4-types §1 (`int` and `float`
for `number`). The PureScript reference and the TypeScript port can stay on
doubles with the 53-bit range, and still need to tell `3` from `3.0` in JSON
text, which `JSON.parse` alone does not; Python needs range checks on its
unbounded integers; Haskell, Rust and Go need the two cases kept apart where
they are one today, and take the 64-bit range. The corpus marks a case that
needs the wider range (`"requires": ["int64"]` in `meta.json`); every other
case stays inside the guaranteed one or outside 64 bits, where all ports
agree. Fixtures:

- literals: each form to its type, both ends of the guaranteed range, one
  past each end of the 64-bit range, and both 64-bit ends under `int64`;
- context numbers: `3`, `3.0`, `3e0`, both ends of the guaranteed range, an
  integer-form number beyond 64 bits rejected, and under `int64` one above
  2^53 kept exactly;
- serialization: a whole-valued float in a `Node` attribute, in `str`, in
  interpolation, nested in an array, and in canon; a round trip of each type;
- `eq(1, 1.0)`, and each comparison over a mixed pair;
- existing fixtures that render a whole-valued float or compare a float with
  an integer literal, which change and must be reviewed one by one.

*The builtins.* Normative text: ref §5 (the parenthetical), §9
(`arithmeticOps`), §11 (the table and the "no arithmetic" paragraph), §12
(`NotRepresentable`); v3-symbols §1.1, §1.5, §5.2 to §5.5, §7, §8 and §9's
third "declined" entry; `laws.md` for the residual law. Then the six ports.
The corpus needs a way to mark a case as needing a profile (an optional
`"requires": ["arithmetic"]` in `meta.json`), and these families:

- the empty case: `sum()`, `product()`, `sum([])` and a nested empty array
  refused, one operand of each type, and the seeds `sum(0, [])` and
  `sum(0.0, [])`;
- flattening: nested arrays, arrays mixed with scalars, a `map` result;
- integers: exact sums and products up to the ends of the guaranteed range,
  overflow past 64 bits in `sum` and `product`, and a fold that overflows at a
  step although its total is in range; under `int64`, exact results above
  2^53, both range ends, and `negate(-9223372036854775808)`;
- `floor-quotient` and `modulo`: each sign combination, an exact division, a
  zero divisor for each, the identity that relates them, and under `int64`
  `floor-quotient(-9223372036854775808, -1)` with `modulo` of the same pair;
- float fold order: a three-operand sum whose two groupings differ
  (`sum(0.1, 0.2, 0.3)` is `0.6000000000000001`), and the same for `product`;
- `quotient` against `product` with `inverse` (49.0), and `inverse` itself;
- `floor` of negative floats, of whole-valued floats, of an integer, and of a
  float past the 64-bit range;
- `real` of a float and of integers up to the ends of the guaranteed range;
  under `int64`, integers above 2^53 that round down, round up and tie;
- zero: `negate(0.0)`, `product(-1.0, 0.0)`, an underflowing product;
- `NotRepresentable` for floats: `inverse(0.0)`, `quotient(0.0, 0.0)`, overflow
  in `sum` and `product`, and the `branch` guard that avoids it;
- `TypeMismatch`: each non-number operand kind, each mixed pair of number
  types, each builtin given the type it does not accept, wrong arity, an array
  given to a fixed-arity builtin, and precedence over `NotRepresentable`;
- a builtin passed by reference to `map` and `fold`; a shadowing binding;
- terms: mixed operands preserved in order, a nested term, a flattened array of
  symbols, concrete operands of two types refused, an integer and a float
  operand each surviving the envelope, a term in an attribute, a payload, a value slot, a text child and a
  constraint argument;
- terms refused: every inspecting builtin, interpolation, projection;
- deduplication of two constraints over equal and over reordered terms;
- seeding: a well-formed term round-trips, a malformed or symbol-free one is
  rejected, and `"$term"` in a concrete-mode context is rejected;
- the residual law: one program run symbolically, and concretely with the
  symbol seeded as a number.

**Decided by the owner, 2026-10-06.**

1. Nine builtins: the four asked for, plus `quotient`, `floor-quotient`,
   `modulo`, `floor` and `real`. `min`/`max`, rounding and formatting are left
   out, and `divmod` is rejected.
2. `sum` and `product` flatten arrays; `and`/`or` do not. An empty `sum` or
   `product` is a `TypeMismatch`, and the seed is the idiom.
3. A profile gated by `UnboundName` and `deepArithmeticOps`, not a reserved
   `import("math", {})`.
4. `NotRepresentable` as the one new error kind, for integer overflow,
   division by zero and a non-finite float alike. Integer overflow is checked
   at each step of a fold. Division by zero is an error and not a value.
5. Terms in the value domain, preserved exactly as written, with no folding of
   concrete operands.
6. `"$term"` reserved in every profile, which rejects a context that carries
   that key today. The envelope stays `tramaj/symbolic/1`.
7. A fraction or an exponent makes a literal a float, so `1e5` is a float. No
   new syntax.
8. A JSON number is typed by its text. The producer decides the type of a
   context number, and `real` is the author's defence.
9. `str(1.0)` renders as `1.0`, by the same rule as JSON serialization. This
   changes existing output for whole-valued floats.
10. Strict comparisons: `eq(1, 1.0)` is `false` and `gt(1.5, 0)` is a
    `TypeMismatch`. An existing `gt($ctx.ratio, 0)` over a float must become
    `gt($ctx.ratio, 0.0)`.
11. The number split ships first, ahead of the builtins.
12. Integers are guaranteed to 53 bits and recommended at 64, with exactly
    those two ranges permitted. In the gap a port holds the value exactly or
    refuses it. A value a 64-bit port emits above 2^53 is rejected by a 53-bit
    port that receives it.

**Decided afterwards, 2026-10-07.** Points the fixtures found open or
contradictory. The owner's rule: error on input that is unexpected, or whose
acceptable semantics are hard to converge on, with an existing error kind.
Where this list and the text above disagree, this list and the normative
specs win.

1. A concrete structure holding a term counts, iterates and merges, as one
   holding a symbol does (v3-symbols §1.7, §1.9). `eq`, `str` and an
   allocation key refuse anything *containing* a term; the rest refuse a
   term given as the operand or container. Reason: a term is refused exactly
   where a symbol is, so no port needs a second rule or a deep scan.
2. `negate([$s])`, and any array given to a fixed-arity builtin, is a
   `TypeMismatch`, not a `NotConcrete` (v3-symbols §1.9). Reason: these
   builtins do not flatten, so nothing looks inside the array, and it is
   what the residual law gives once `$s` is a number.
3. A well-formed seeded term is one a call could have built: exactly the
   keys `"$term"` and `"arguments"`, number arguments that agree in type and
   suit the builtin, no array argument, and every nested term well-formed,
   so containing a symbol (v3-symbols §5.3). Reason: the decoder reuses the
   call's check, and a host cannot seed what the language cannot produce.
4. The decoder's rejection is a `TypeMismatch` in both modes, for a reserved
   key and a malformed symbol or term alike (v3-symbols §5.3, §6). Cases 360
   to 369 are confirmed. Reason: it is what `"$sym"` and `"$type"` already
   raise in every port.
5. *Not decided.* How the corpus expresses behaviour of a 53-bit-only port
   or of one without the arithmetic profile, and a case shape for
   `arithmeticOps`, are corpus mechanisms the rule does not settle.
6. A demand needs no binding to be an operand: `sum(?ctx.s, 1)` is legal and
   its symbol table entry has `"binding": null` (v3-symbols §1.3, §5.2).
   Reason: a demand is an expression, and refusing it inline would change
   the v3 grammar.
7. Wording. ref §11's example of a step overflow on every implementation is
   `product(4294967296, 4294967296, 0)`; `sum(9223372036854775807, 1, -1)`
   is the 64-bit example and a parse error on a 53-bit port. A demand's
   origin path omits `ctx` (v3-symbols §5.2), as the ports and case 066
   have it.
8. An integer-form context number outside the port's range is a
   `TypeMismatch` (ref §3, §12), and the corpus writes it as an
   `eval-error` case, like a reserved key. Reason: one refusal for
   everything the context decoder rejects; `NotRepresentable` stays an
   operation that had no result.
9. `-0.0` in context JSON is `0.0`, and `-0` the integer `0` (ref §3). It is
   not rejected. Reason: a JSON number is read as the literal of the same
   text, which already says so; rejecting would need a second number reader
   and would refuse what common serializers write for a negative zero.
10. A context float too large for a double (`1e400`) is a `TypeMismatch`;
    one too small rounds to zero (ref §3, `node-json.md`). Reason: the same
    literal rule, where `1e400` is a parse error.
11. A library parameter is a value the importer built, not JSON text; it
    keeps the type it has and nothing is typed again at the import (ref §3).
    Reason: "typed by its text" has no text to apply to there.

## 19. A traverse form for allocation: `?shape(key, shape)` with `~name` markers

*Status: proposed, for owner review. Nothing here is implemented; `specs/v3-symbols.md` is unchanged until this is approved. The owner has settled seven points: a symbol in a shape is declared by an explicit marker; the marker is named; the form is spelled `?shape`; a duplicate marker name is a parse error; so is a shape with no marker; a marker may be written anywhere in the shape; and under a lambda it carries its own key.*

"Traverse" in the functional sense: walk a structure, run an effect at each
position, get the same structure back. The effect here is allocation.

**What is awkward today.** v3-symbols §1.7 already gives a flat array of symbols
over an existing collection (`map($ctx.services, (s) => ?($s.name))`), and a
grid is two nested `map`s with a `[$r, $c]` key. Those need nothing new. A
structure of symbols does, and most of all one whose size the caller decides:

```
-- one site per symbol, and a key composed by hand at each of them
@cluster = {
  lb:         ?(["cluster", "lb"]),
  placements: map($ctx.vms, (vm) => {
    vm:   $vm.name,
    host: ?(["cluster", "host", $vm.name]),
    zone: ?(["cluster", "zone", $vm.name])
  })
}
```

The gap is one site per symbol and a key composed by hand at each. It is *not*
"N symbols from the number N": that needs a collection of length N, which is a
`range` question and stays out of this section. The caller supplies an array.

**Surface form.** A second allocation form, `?shape`, takes a key and a shape,
and inside the shape a **symbol marker**, `~name`, optionally with a key of its
own:

```
alloc  ::= "?(" expr ")"                 -- v3-symbols §1.2, unchanged
         | "?shape(" expr "," expr ")"   -- key, shape
marker ::= "~" name                      -- inside a shape only
         | "~" name "(" expr ")"         -- with a marker key

@d = ?shape("d", {replicas: ~replicas, zone: "eu", ports: [~http, ~admin]})

@cluster = ?shape("cluster", {
  lb:         ~lb,
  placements: map($ctx.vms, (vm) => {vm: $vm.name, host: ~host($vm.name), zone: ~zone($vm.name)})
})
```

- `~` is a new leader character. It is used nowhere in the grammar today, and a
  name starts with a letter (ref §5), so `~name` is a parse error in every
  existing program. The name follows the `~` directly and obeys the ordinary
  name rule; the `(` of a marker key follows the name directly.
- The shape is an ordinary expression, and a marker is an expression **anywhere
  in it**: an array element, a field value, a call's argument
  (`sum(~a, ~b)`), a `branch` arm, an element's child, a lambda's body. A
  marker belongs to the innermost `?shape` whose shape contains it. Outside
  any shape, and in a `?shape`'s key, it is a parse error.
- **Under a lambda, a marker MUST carry a key.** A lambda's body is evaluated
  once per application, so a marker in it stands for many symbols, and the
  marker key says which one. A bare `~name` inside a lambda that is itself
  inside the shape is a parse error. A lambda *around* the whole form does not
  count: there the form's own key does the job, as in
  `map($ctx.vms, (vm) => ?shape($vm.name, {host: ~host}))`.
- A marker key is legal outside a lambda too. Like any allocation key it is an
  ordinary expression that MUST evaluate to a concrete value.
- A shape MUST contain at least one marker: an allocation form allocates.
  A marker name appears at most once in a form, with or without a key;
  `{web: {port: ~port}, db: {port: ~port}}` is a parse error.
- `?shape` is a parse error today, since a `?` is followed by `(` or by `ctx`,
  so no existing program changes meaning. It takes exactly two arguments.
  `?(a, b)` stays a parse error.
- `shape` is a word under the `?` leader, read the way `ctx` is in `?ctx.path`.
  It is not reserved: `$shape`, `@shape` and `.shape(...)` are unaffected.

It is a special form and not a builtin for the reason `?(k)` is: it needs a
site, and a site is assigned by the parser (v3-symbols §1.4). Keeping the `?`
leader also keeps v3-symbols §5.5 true as written, which a keyword would not:
the core profile rejects the form at parse time with no new rule, and the
marker with it.

**Desugaring** (the core AST does not change). `?shape(k, shape)` at site *n*
lowers to the shape with each marker replaced by an allocation at that site:

```text
~name        Alloc n [k, "name"]         -- what ?([k, "name"]) would be at site n
~name(e)     Alloc n [k, "name", e]      -- what ?([k, "name", e]) would be at site n
```

where `k` is bound once to a hidden name (§17's rule for hidden names) and read
from each marker. Everything else in the shape is left as written. So the form
means exactly what the hand-written expression means, with two differences a
hand-written one cannot have: the key is written once, and all the allocations
share one site. Sites are numbered in one sequence across both forms, and a
marker takes no number of its own.

**Identity.**

```
id = "#" n ":" canon([k, "name"])         -- bare marker
id = "#" n ":" canon([k, "name", e])      -- keyed marker

the cluster above, at site 0, with vms named "a" and "b":
  #0:["cluster","lb"]
  #0:["cluster","host","a"]   #0:["cluster","zone","a"]
  #0:["cluster","host","b"]   #0:["cluster","zone","b"]
```

- The name says which symbol of the shape, the marker key says which
  application of the lambda, and the form's key says which evaluation of the
  site. Each is something the author wrote (v3-symbols §1.2): nothing is
  derived from an index or from evaluation order.
- Sharing happens only where the author's keys are equal: two `vms` with the
  same name share `host` and `zone`, as two services with the same name share
  `?($s.name)` today. A constant marker key under a lambda shares one symbol
  across applications, and is the only way to write that.
- Under nested lambdas the marker key has to distinguish every level:
  `~cell([$r, $c])`.
- The position is not in the id. Reordering the `vms`, or moving a marker to
  another field, keeps every symbol's identity; renaming a marker changes it.
- Injective: `canon` is injective (§13), a name appears once in a form, a pair
  and a triple differ, and a site is one form or the other, so an id from this
  form cannot meet an id from a plain `?(k)`.

**Symbol table and envelope.** No change and no format bump. Each allocation is
an ordinary entry:

```json
{"id": "#0:[\"cluster\",\"host\",\"a\"]",
 "origin": {"kind": "alloc", "site": 0, "key": ["cluster", "host", "a"]},
 "binding": null}
```

- **Order** is that of the lowered expression, under v3-symbols §4 unchanged.
- **`"binding"`** is `null` for every entry: no marker is the whole right-hand
  side of a binding (v3-symbols §5.2), and the name of `@d = ?shape("d", …)`
  names the structure. `origin.key` carries the form's key, the marker's name
  and the marker key.
- A host decoder needs no new case, and cannot tell this form from hand-written
  allocations. The form is a way to write allocations, not a new kind of one.

**Interaction with existing rules.** All of these follow from the lowering.

- *Root only.* `AllocationInLibrary` applies lexically, unchanged.
- *Concrete mode.* `SymbolsUnavailable` when a marker is evaluated, as for a
  `?(k)` written in its place. A form whose markers are never evaluated (an
  empty `vms`, an arm not taken) therefore passes, as the hand-written
  expression does.
- *Demands and seeding.* Unrelated to markers; `?ctx.path` is an ordinary
  expression in a shape: `?shape("d", {replicas: ~replicas, zone: ?ctx.zone})`.
- *Core profile.* Rejected at parse time, as every `?` is.
- *`symbolSites`.* Reports the site once. The number of symbols is a runtime
  fact, as it is for a `?(k)` under a `map`.
- *v4 annotations.* `@xs : [T] = ?shape("xs", [~a, ~b])` is the existing sugar
  (v4-types §7): one `has-type` on the whole array, none per element.

**Errors.** No new kind. `NotConcrete` (a symbol in the form's key or in a
marker key), `SymbolsUnavailable` (concrete mode), `AllocationInLibrary`
(lexical), and parse errors for a marker outside a shape, a bare marker under a
lambda, a shape with no marker, a duplicate marker name, and `?shape` with
other than two arguments.

**Rejected or deferred**

- *`null` as the place of a symbol (the first draft of this section).* It
  needed no token and let a shape come from `$ctx`, but it overloaded `null`:
  a legitimate `null` could not be kept, and data allocated symbols nobody
  wrote. It also needed a new core constructor, since nothing in the core can
  walk a value whose depth is data.
- *The iteration index in the id, with no marker key.* Nothing to write, but
  identity becomes positional (inserting a `vm` renames every later symbol,
  which breaks seeding a previous solution), and the evaluator of every port
  has to track indices through `map`, `filter`, `scan` and `fold`. It is also a
  call-frame identity scheme, which v3-symbols §9 declines.
- *Markers at structural positions only* (the shape, an array element, a field
  value). Simpler, with a static symbol count, but it cannot express a
  collection inside a shape, which is the main use.
- *A bare marker under a lambda sharing one symbol.* What the lowering would
  give unaided, and never what the author of a `map` meant.
- *A duplicate marker name as one shared symbol.* The same field name at two
  depths would silently be one variable. Sharing is written as two reads of
  one binding. The error can be relaxed later.
- *A shape with no marker returned as is.* An allocation form that allocates
  nothing.
- *A bare marker identified by its path.* An array's symbols would be
  identified by index and change identity on reordering.
- *The spelling `?(key, shape)`.* Only a comma would separate it from `?(k)`,
  and the two start with the same characters. A word says which form is meant
  from its first token, to a reader and to a model writing the template.
- *A keyword, `alloc(key, shape)`.* It reserves a name, needs its own rule in
  the core profile, and spells one act two ways beside `?(k)`.
- *`_name` as the marker.* `_` is already a name character and a digit
  separator, and is the likely spelling of "ignore" in a pattern (§17).
- *A general `walk(value, (path, leaf) => …)` constructor.* A recursion scheme
  added to a language that has none.
- *A core `AllocIn` constructor, or a new origin kind.* Neither is needed once
  the form is a lowering.
- *Symbols from a count.* Belongs with a `range`.
- *A shorthand `{~replicas}` for `{replicas: ~replicas}`*, after the object
  literal's `{foo}`. Deferred; see the questions.

**Follow-up once approved:** normative text in `specs/v3-symbols.md` (§1.2,
§1.4, §1.7, §5.2, §7, §8) and `specs/reference.md` (the leader characters and
the syntax table); the parser change in the PureScript reference, then the
other five ports. Corpus families: markers at several depths; an expression
beside a marker; a marker in a call, in a `branch` arm taken and not taken, and
in an element; a keyed marker under `map`, with distinct keys and with equal
keys sharing; nested `map`s with a composite marker key; an empty collection in
both modes; the form under a `map` with a key per iteration; reordered markers
and reordered elements keeping their ids; table order for an object written in
non-sorted key order; `"binding"` bound and inline; a nested form; a symbolic
form key and a symbolic marker key; concrete mode; the form in a library; an
annotated binding emitting a single `has-type`; and the parse errors (a marker
outside a shape and in a form's key, a bare marker under a lambda, a
marker-free shape, a duplicate name, `?shape` with one and with three
arguments, `?(a, b)`).

**Questions for the owner.** (1) `"binding"` as `null` for every entry, which
is what the lowering gives, rather than the structure's name. (2) Whether to
add the `{~replicas}` shorthand now, since `replicas: ~replicas` repeats the
name.
