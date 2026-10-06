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

## 18. Arithmetic: six named builtins, no operators, and a term for what a symbol leaves unevaluated

*Status: proposed, for owner review. Nothing here is implemented; `specs/reference.md` §11 keeps saying "there is no arithmetic" until a port lands.*

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

**Scope.** Six builtins, as ordinary names in the initial environment. No infix
operator, no new leader, no new literal form.

| builtin | arity | concrete result |
|---|---|---|
| `sum(…)` | any, including zero | left fold of `+` from `0`; `sum()` is `0` |
| `product(…)` | any, including zero | left fold of `*` from `1`; `product()` is `1` |
| `negate(x)` | 1 | `-x` |
| `inverse(x)` | 1 | `quotient(1, x)`, by definition |
| `quotient(a, b)` | 2 | `a / b` |
| `floor(x)` | 1 | the largest integer not above `x` |

```
@subtotal = sum($ctx.compute, $ctx.storage, negate($ctx.credit))
@share    = branch(0, gt($ctx.total, 0),
                   floor(quotient(product(100, $ctx.used), $ctx.total)))
@total    = sum(map($ctx.lines, (l) => product($l.qty, $l.price)))
```

- *Subtraction is not a builtin.* Negation is exact in IEEE 754, so
  `sum(a, negate(b))` is bit for bit `a - b`. A `difference` would add a name
  and no value.
- *Division is one, although it was not asked for by name.* The same argument
  fails for it: `product(a, inverse(b))` rounds twice where `a / b` rounds
  once, and the results differ. `product(49, inverse(49))` is
  `0.9999999999999999`, so `floor` of it is `0`; 98, 103 and 107 behave the
  same way. A share computed that way would be off by one unit for arbitrary
  inputs. `quotient` is therefore the primitive and `inverse(x)` is defined as
  `quotient(1, x)`, which keeps the requested name and its meaning.
- *`floor` is the single integer primitive.* Without one, no ratio can be
  turned into a whole number of percent or pixels. Modulo and truncation are
  expressible from it. Rounding to nearest and decimal formatting are display
  concerns and are left to the number-formatting work, since
  `floor(sum(x, 0.5))` only approximates rounding (it is wrong for the double
  just below `0.5`).
- *`min` and `max` are left out.* Their identities are the infinities, which
  are not values (below), so the zero-argument case could not follow `sum()`
  and `and()`. `fold` with a `branch` covers the concrete case.

The existing `-` rule is untouched: `-` stays part of a number literal, `--`
stays a comment, `<>` stays the only infix operator, and §9's argument that no
expression begins with a hyphen still holds. Only the parenthetical in ref §5
("there is no arithmetic") needs rewording to "there are no arithmetic
operators".

**Arrays as arguments.** `sum` and `product` flatten their arguments by the
rule children (ref §6) and `!` (v3-symbols §2.2) already use: an array
contributes each of its elements, recursively, in order. So `sum($xs)`,
`sum(1, $xs, 2)` and `sum([1, [2, 3]])` are all legal, and `sum([])` is `0`.
There is no spread syntax and this does not add one; a separate
`sum-of(array)` form would make the author pick a spelling by the shape of the
data, and the language already answers "an array in a sequence position is a
sequence" twice. The four fixed-arity builtins do not flatten: `negate([1])`
is a `TypeMismatch`, and `map($xs, $negate)` is the way to write it. `and`,
`or` and `concat` are unchanged.

**Optional, but builtin: a profile.** Arithmetic is a third profile next to
v3-symbols §5.5's core and symbolic ones, and independent of both.

- An implementation with the **arithmetic profile** puts the six names in the
  initial environment. One without it does not, and a program that uses one
  fails with the existing `UnboundName`. No new refusal mechanism is needed,
  and none at parse time is possible: these are names, not syntax, and
  `@sum = …` may legitimately bind one.
- Because builtins are ordinary bindings, a program that already binds `sum`,
  `floor` or any of the others (a binding, a lambda parameter, a pattern name)
  shadows the builtin and behaves exactly as before. Adding the names breaks
  no existing program.
- A new static analysis, `arithmeticOps` with a deep variant, reports which of
  the six names a program references **free**, called or passed by reference
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

1. *Operands are IEEE 754 binary64.* A port that holds numbers in a wider type
   (an arbitrary-precision integer or decimal) MUST convert each operand to the
   nearest double before computing. This narrows ref §13's "number precision"
   entry for arithmetic: the result of these builtins is not
   implementation-defined.
2. *One correctly rounded operation at a time*, round to nearest, ties to even.
   `sum` and `product` are a left fold over the flattened operands, starting
   from the identity: `sum(a, b, c)` is `((0 + a) + b) + c`. No pairwise or
   compensated summation, no reordering, and no fused multiply-add: a port
   whose compiler may contract `a * b + c` must prevent it. Starting from the
   identity is exact (`0 + a` and `1 * a` are `a`), so it changes no result and
   removes the one-operand special case.
3. *A non-finite result is an error*, of a new kind `NotFinite`. NaN and the
   infinities are not JSON and are not values. This covers `inverse(0)`,
   `quotient(x, 0)`, `quotient(0, 0)` and overflow with one rule and no test
   for a zero divisor. Once a fold's running value is non-finite it stays so,
   so checking the final result is equivalent to checking each step.
   Underflow is not an error: the result is the nearest double, which may be
   zero, as for a literal (ref §5).
4. *There is no negative zero.* A result that is zero is `0`, as for literals:
   `negate(0)` is `0`, and so is `product(-1, 0)`.
5. *No coercion.* An operand that is not a number is a `TypeMismatch`
   (`sum(1, "2")`, `sum(null)`, `negate(true)`), like `eq`'s refusal to equate
   `1` and `"1"`. A wrong argument count for a fixed-arity builtin is a
   `TypeMismatch` too. All operands are checked, in flattened order, before
   anything is computed, so `sum(1e308, 1e308, "a")` is a `TypeMismatch` and
   not a `NotFinite`.
6. *`str` is unchanged*, so `sum(0.1, 0.2)` interpolates as
   `0.30000000000000004`. That is what the double is; hiding it belongs to
   formatting, not to arithmetic.

Division by a value that happens to be zero at render time is the case a
template will meet in practice (an empty counter). It is an error rather than
`null` or `0` because either of those would flow into the document as a
plausible-looking answer. The guard is the lazy `branch` shown above, whose
unselected arm is never evaluated (ref §6).

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
closed, six operations whose meaning the language itself defines, so a term is
not host vocabulary. It is the computation the language would have performed
had it known the operands, handed over undone.

```text
Value
  = ...
  | Term  op: String, arguments: List<Value>   -- arguments: numbers, symbols, terms
```

- A call to one of the six builtins whose flattened operands are all numbers
  computes, as above. If at least one operand is a symbol or a term, the result
  is a `Term` with that `op` and **the flattened operands exactly as written**:
  same order, nothing folded, nothing simplified, no nested term spliced.
  `sum(1, $s, 2)` is `sum(1, $s, 2)`, not `sum($s, 3)`; `inverse($s)` is
  `inverse($s)`, not `quotient(1, $s)`.
- Preserving rather than folding is forced by floating point: `(1 + s) + 2` and
  `s + 3` are different doubles for some `s`. It buys the **residual law**: a
  host that evaluates a term by the concrete rules above, after substituting
  numbers for its symbols, gets byte for byte what the program would have
  produced had those numbers been in the context. It also keeps the promise of
  §0 that Tramaj solves nothing, and it is the least code in six ports.
- Concrete operands of a term are still checked (`sum("a", $s)` is a
  `TypeMismatch`). A symbol operand is not: what it stands for is the host's.
  `inverse($s)` is a term even if the host later supplies `0`, and the author
  who cares writes `!constraint("ne", $s, 0)` in the host's vocabulary.
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

**Follow-up once approved.** Normative text: ref §5 (the parenthetical), §9
(`arithmeticOps`), §11 (the table and the "no arithmetic" paragraph), §12
(`NotFinite`), §13 (precision); v3-symbols §1.1, §1.5, §5.2 to §5.5, §7, §8 and
§9's third "declined" entry; `laws.md` for the residual law. Then the
PureScript reference and the Haskell, Rust, TypeScript, Go and Python ports.
The corpus needs a way to mark a case as needing a profile (an optional
`"requires": ["arithmetic"]` in `meta.json`), and these families:

- identities: `sum()`, `product()`, `sum([])`, one operand;
- flattening: nested arrays, arrays mixed with scalars, a `map` result;
- fold order: a three-operand sum whose two groupings differ
  (`sum(0.1, 0.2, 0.3)` is `0.6000000000000001`), and the same for `product`;
- `quotient` against `product` with `inverse` (49), and `inverse` itself;
- `floor` of negatives, of integers, of values past 2^53;
- zero: `negate(0)`, `product(-1, 0)`, an underflowing product;
- `NotFinite`: `inverse(0)`, `quotient(0, 0)`, overflow in `sum` and `product`,
  and the `branch` guard that avoids it;
- `TypeMismatch`: each non-number operand kind, wrong arity, an array given to
  a fixed-arity builtin, and precedence over `NotFinite`;
- operands above 2^53 arriving through the context;
- a builtin passed by reference to `map` and `fold`; a shadowing binding;
- terms: mixed operands preserved in order, a nested term, a flattened array of
  symbols, a term in an attribute, a payload, a value slot, a text child and a
  constraint argument;
- terms refused: every inspecting builtin, interpolation, projection;
- deduplication of two constraints over equal and over reordered terms;
- seeding: a well-formed term round-trips, a malformed or symbol-free one is
  rejected, and `"$term"` in a concrete-mode context is rejected;
- the residual law: one program run symbolically, and concretely with the
  symbol seeded as a number.

**Questions for the owner.**

1. `quotient` and `floor` in the first cut, beyond the four names asked for;
   `min`/`max`, rounding and formatting left out.
2. Flattening arrays in `sum`/`product`, and not in `and`/`or`.
3. A profile gated by `UnboundName` and `deepArithmeticOps`, rather than a
   reserved `import("math", {})`.
4. `NotFinite` as a new error kind, and division by zero as an error rather
   than a value.
5. Terms in the value domain, preserved exactly as written. The alternative
   worth a second look is folding a *leading* run of concrete operands, which
   is exact (`sum(1, 2, $s)` to `sum(3, $s)`) but is a rewrite rule every port
   must then share.
6. Reserving `"$term"` in every profile, which rejects a context that carries
   that key today, and keeping the envelope at `tramaj/symbolic/1`.
