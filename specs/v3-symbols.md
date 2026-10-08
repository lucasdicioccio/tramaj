# Tramaj v3 — Symbolic values and constraints

This document is **normative** for the symbolic extension. It builds on
`reference.md`, which remains normative for everything else; section numbers
written as *(ref §n)* point there. `node-json.md` is unchanged and remains
normative for the `Node` encoding, which v3 wraps rather than alters.

Types are **not** in v3. Nominal types, type declarations, imported type
namespaces and typed annotations are drafted separately in
[`v4-types.md`](v4-types.md). v3 is complete and implementable without them,
and §9 says how far it gets on its own.

Status: frozen as a design. Not implemented in either `tramaj/` or
`tramaj-hs/`.

**Terms are not in every implementation yet.** §1.9, and what the rest of
this document says about terms and about `"$term"`, is accepted design
(decisions §18). It depends on ref §11's arithmetic profile. `tramaj/`
(PureScript), `tramaj-hs/` (Haskell) and `tramaj-go/` (Go) implement both, for the nine names
other than `round`; the Rust, JavaScript and Python ports have neither
yet. The same holds for the two number types (ref §3) wherever this document
writes a number: in canon (§1.4) and in the envelope (§5.2).

---

## 0. What v3 adds, and the rule it follows

Three things: an expression `?` that introduces a **symbol**, a statement `!`
that emits a **constraint**, and an output mode that carries both.

Everything follows one rule the language already applies to actions and import
names:

> **Tramaj fixes positions and identity. The host owns vocabulary and meaning.**

An action's event and key are static positions; what `"on-click"` means is the
host's business (ref §10). v3 says the same of symbolic variables and
constraints:

| the language guarantees | the host decides |
|---|---|
| a symbolic variable exists, and *which* one it is | what it stands for |
| a constraint was emitted, with these arguments | what `"gte"` means, and how to solve it |
| the set of constraint kinds a program can emit, statically | whether it supports them |

Tramaj therefore solves nothing and checks nothing. It evaluates as far as it
can and serializes what it could not resolve, so that a host fold may run a
solver, render a form, ask a user, or refuse a template whose constraint
vocabulary it does not implement.

---

## 1. Symbols

### 1.1 The value

```text
Value
  = ... as in ref §3 ...
  | Symbol  id: SymbolId, path: List<String>
  | Term    op: String, arguments: List<Value>   -- §1.9; arguments: numbers, symbols, terms
```

A `Symbol` with an empty `path` is an **allocation**; one with a non-empty
path is a **projection** of an allocation (§1.6). A symbol is opaque to the
language: nothing inspects it, and nothing but §1.6's projection derives a new
one from it. A `Term` is an arithmetic operation left unevaluated because one
of its operands is a symbol (§1.9).

### 1.2 `?(key)` — allocation

```
@primary = ?("primary")
@ports   = map($ctx.services, (s) => ?($s.name))
```

`?(expr)` allocates. The argument is an ordinary expression, evaluated where
it is written, and MUST evaluate to a concrete JSON value; a symbol used as a
key is `NotConcrete`.

There is **no keyless form.** A symbol always says what distinguishes it from
its neighbours, so the question "did this mean one variable or many?" is
always answered in the source:

```
map($ctx.services, (s) => ?($s.name))   -- one symbol per service
map($ctx.services, (s) => ?("port"))    -- one symbol, shared by every service
```

Both are legal and mean what they say. A constant key is a constant symbol.
What v3 refuses is the version where the author writes nothing and the
language guesses.

### 1.3 `?ctx.path` — demand

```
@replicas = ?ctx.replicas
```

`?ctx.a.b` evaluates to `$ctx.a.b` and declares *this is a value I intend to
discuss symbolically*. The path MUST be rooted at `ctx`.

**At runtime it means exactly what `$ctx.a.b` means.** Whatever the caller
supplied — a number, a symbol, an object — is what it produces. The
distinction is entirely static, and it is the same trade `ctx(path)` already
makes for import parameters (ref §7): a path in a static position is a demand
an analyzer can enumerate, where the same read buried in an arbitrary
expression is not.

An unsupplied demand:

* **in the root program**, allocates the symbol `#` + the path (§1.4). The
  root's caller is the host, the host declined to supply, and the root runs
  once, so it may allocate.
* **in a library**, is `PathNotFound`, wrapped in `InLibrary` naming the
  library — the same error an ordinary unsupplied read already produces
  (ref §7).

A demand is an expression and may be written wherever one may: as a call
argument, an array element, an operand of an arithmetic builtin (§1.9). It
does not need binding first. `sum(?ctx.s, 1)` and `@s = ?ctx.s` followed by
`sum($s, 1)` allocate the same symbol and build the same term; they differ
only in the `"binding"` the symbol table reports (§5.2).

### 1.4 Identity

> **Only a root program may allocate. A library MUST NOT**, because the root
> runs exactly once and a library does not.

`AllocationInLibrary` is raised when a program containing `?(k)` is loaded as
a library. The check is **lexical**: it is about where the `?` is written, not
where it is evaluated, so a closure created in the root and applied inside a
library still allocates in the root, which is where its `?` is written.

A `SymbolId` is a string, formed as follows and identical in every conforming
implementation:

| form | id |
|---|---|
| `?(k)`, the *n*-th `?` in the program's source | `#` *n* `:` canon(*k*) |
| `?ctx.a.b`, unsupplied at the root | `#ctx.a.b` |

* *n* is assigned by the parser: the `?(k)` occurrences of one program are
  numbered `0, 1, 2, …` in source order. It belongs to the core AST for the
  same reason a binding's name does — it *is* the variable's identity, not
  source trivia.
* **canon** is compact JSON with object keys sorted, numbers rendered by
  ref §6's `str` rule, and strings JSON-quoted. It agrees with `str` on arrays
  and objects and differs at the top level for strings, where `str` renders
  raw. The difference is required: canon MUST be injective, and `str(3)` and
  `str("3")` are the same characters. An integer and a float are two values
  (ref §3) and `str` keeps them apart, so canon does too: `?(1)` is `#0:1`
  and `?(1.0)` is `#0:1.0`.
* The two forms cannot collide: an allocation id continues with a digit, a
  demand id with `ctx`. A path segment cannot contain `.` (ref §5), so the
  demand form is unambiguous.

Identity is a function of the program text and of one value the author chose.
It does not depend on evaluation order, so two implementations agree on symbol
ids by construction rather than by agreeing on a traversal.

The site is part of the id, as well as the key, so that two independent
`?("replicas")` in different places are different variables. A key names a
distinction, not a variable.

### 1.5 What may be done with a symbol

> **Control flow and structure must be concrete. Only data may be symbolic.**

A symbol is data. It may be bound, passed to a lambda, returned from one,
stored in an array or object, and placed in an attribute, an action payload,
an element value slot or a text child. Everything that would require the
language to *know* something about it is an error:

| expression | result |
|---|---|
| `$s`, `[$s]`, `{k: $s}` | fine — a symbol is a value |
| `.p($s)`, `.div(class: $s)`, `action(e, k, {r: $s})` | fine — §5.2 carries it |
| `$s.field` | a projection (§1.6) — **the one exception** |
| `branch($s, …)` | `NotConcrete` — no arm can be selected |
| `map($s, f)`, `filter`, `scan`, `fold`, `sort-by`, `sort-by-descending` | `NotConcrete` — the spine has no length |
| `sort-by(xs, f)` where `f` gives a symbol as a key | `NotConcrete` — a sort inspects its keys; an array or an object as a key is a `TypeMismatch`, whatever it holds |
| `eq` on anything *containing* a symbol | `NotConcrete` — deep equality needs the whole value |
| `lt`, `lte`, `gt`, `gte` with a symbol as an operand | `NotConcrete`; an array or object operand is the `TypeMismatch` it always was, whatever it holds |
| `str` of anything *containing* a symbol, and so any interpolation of one | `NotConcrete` — §1.8 |
| `cardinality($s)`, `has($s, k)`, `lookup($s, k, d)` | `NotConcrete` |
| `format-number` with a symbol as any of its three arguments | `NotConcrete` — the result is text (§1.8); an array argument is a `TypeMismatch`, whatever it holds |
| `$s <> x` | `NotConcrete` |

`has` and `lookup` are called out because both are deliberately *tolerant*
today — `has` answers `false` for a wrong-shaped container and `lookup` never
errors. Neither may answer about a symbol: a tolerant `false` would be a lie,
and `lookup`'s fallback would silently discard the symbol.

Consequence worth stating: v3 can constrain the elements of a list whose
length is known, and cannot constrain a list whose length is symbolic. That is
the ceiling, and it is where a real symbolic evaluator would have to begin.
Declining to go there is what keeps `map` free of any `if value is Symbol`
branch — no evaluator rule in ref §6 changes, and no builtin learns a new
case beyond refusing. The ten arithmetic builtins are the one exception:
over a symbol they build a term (§1.9).

The two sorts and `format-number` (ref §11; decisions §20, not yet
implemented) follow the rule and only refuse. A sort builds no term, since a
term stands for a number and the result of a sort is an array: a list whose
order depends on an unsupplied value cannot be rendered, which is the ceiling
above. The elements themselves are not inspected, so
`sort-by([{k: 2, v: $a}, {k: 1, v: $b}], (o) => $o.k)` sorts. `format-number`
builds no term either, since its result is text. Its arguments are examined
left to right and the first that is not acceptable decides between
`NotConcrete` and `TypeMismatch` (ref §11); a sort's keys are examined in
index order in the same way.

A term is data in the same way. Every row above that refuses a symbol refuses
a term in the same position, and a row that says *containing* looks as deep
for a term as it does for a symbol. The one difference is projection, which a
term does not have (§1.9).

### 1.6 Projection

`$s.field` reads nothing. It produces a symbol with the same `id` and the path
extended:

```text
Symbol "#0:\"d\"" []            -- $d
Symbol "#0:\"d\"" ["replicas"]  -- $d.replicas
Symbol "#0:\"d\"" ["a","b"]     -- $d.a.b
```

A projection is never rejected. `PathNotFound` is for a concrete value that
demonstrably lacks a field; a symbol demonstrably lacks nothing, and whether
the thing it stands for has that field is a question for whoever owns its
meaning.

Projections do not appear in the symbol table (§5.2); they are references to
the allocation they project from.

### 1.7 Symbols in structures

**A concrete structure containing symbols is not special.** `[?("a"), ?("b")]`
is an ordinary two-element array that happens to hold symbols. The spine is
concrete, so everything structural works: `cardinality` counts, `map`
iterates, a field read returns the symbol it finds, `<>` merges. Only the
operations that *inspect* a value refuse.

```
@ports = map($ctx.services, (s) => ?($s.name))
!map($ports, (p) => constraint("gte", $p, 1024))
.ul(map($ports, (p) => .li($p)))
```

is legal end to end.

A concrete structure containing terms (§1.9) is not special either, and the
same operations work on it: `cardinality([sum($a, 1), 2])` is `2`.

**A symbol that is itself structured is the ceiling.** `$d.replicas` projects
fine; `map($d.items, f)` is `NotConcrete`, because the length is unknown. A
symbol may *have* structure as far as its host-side meaning is concerned; the
language cannot walk it.

Two cases fall out of the same rule: a symbol cannot be an object key, because
keys are static (ref §5) and nothing computes one; and a symbol inside an
import's parameters is an ordinary value being passed, so it crosses the
boundary with its identity intact, which is §2.4's mechanism.

### 1.8 Symbols in text

`str` refuses symbols, so `` "Deploy `$r` replicas" `` is `NotConcrete`. The
form to write instead:

```
.p("Deploy ", $r, " replicas")
```

Three children — two carrying strings, one carrying the symbol. This is what a
form renderer needs anyway: it must put an input where the symbol is, and it
cannot if the symbol has been flattened into the middle of a string. The
concrete case is unaffected: if `$r` is a number, the same element produces
the same three text children.

Reconstructing a string from those pieces, if a downstream consumer wants one,
is that consumer's job. It has them in order and knows what its target does
with them, which the language does not.

### 1.9 Terms

*Implemented in `tramaj/`, `tramaj-hs/` and `tramaj-rs/`, for the nine names other than
`round`; not yet in the other ports (decisions §18).* This section applies to an
implementation with the arithmetic profile (ref §11, §5.5).

```
!constraint("lte", sum($a, $b), 10)
```

A call to one of the ten arithmetic builtins whose flattened operands are all
numbers computes, by ref §11. If at least one operand is a symbol or a term,
the result is a `Term` with that `op` and **the flattened operands exactly as
written**: same order, nothing folded, nothing simplified, no nested term
spliced.

| expression | result |
|---|---|
| `sum(1, $s, 2)` | `sum(1, $s, 2)`, not `sum($s, 3)` |
| `sum(1, [$s, 2])` | `sum(1, $s, 2)` — arrays are flattened (ref §11) |
| `sum($a, sum($b, 1))` | a term whose second argument is a term |
| `inverse($s)` | `inverse($s)`, not `quotient(1.0, $s)` |
| `floor($s)`, `real($s)`, `round($s)` | terms; none is the identity over a symbol |

Preserving is required, not stylistic: `(1.0 + s) + 2.0` and `s + 3.0` are
different doubles for some `s`, and for integers one grouping can overflow
where the other does not. It gives the **residual law**:

> A host that evaluates a term by ref §11's concrete rules, after substituting
> numbers for its symbols, gets byte for byte what the program would have
> produced had those numbers been in the context, errors included.

Tramaj still solves nothing (§0). A term is the computation the language would
have performed had it known the operands, handed over undone, and its
vocabulary is closed: ten operations whose meaning ref §11 defines, so an
`op` is not host vocabulary the way a constraint name is.

* **A symbol operand stands for one number, of either type**, and a term
  carries no type. Concrete operands are checked as far as they can be without
  one: each MUST be a number, and those of one call MUST agree with each other
  and with what the builtin accepts. `sum("a", $s)`, `sum(1, $s, 2.0)` and
  `quotient(1, $s)` are `TypeMismatch`, and so is a wrong argument count.
* **An operand is a symbol or a term only when it is one itself.** The eight
  fixed-arity builtins do not flatten (ref §11), so an array given to one is
  a `TypeMismatch` whatever it holds: `negate([$s])` is a `TypeMismatch`,
  like `negate([1])`, and not a `NotConcrete`. Nothing looks inside the
  array. `sum` and `product` flatten first, and `sum({k: $s})` is a
  `TypeMismatch` for the same reason: an object is not a number.
* **Nothing is inferred through a symbol or a nested term.**
  `sum(real($s), 1)` is built, and fails when the host evaluates it, as the
  residual law says it should. `inverse($s)` is a term even if the host later
  supplies `0.0`; an author who cares writes `!constraint("ne", $s, 0.0)` in
  the host's vocabulary.
* **A term is data, exactly as a symbol is** (§1.5). It may be bound, passed,
  stored, placed in an attribute, a payload, a value slot or a text child,
  used as a constraint argument, and used as an operand.
* **Everything that inspects refuses, exactly where it refuses a symbol**
  (§1.5), with `NotConcrete`. There are two depths, as for a symbol:
  * `eq`, `str` and so interpolation, and an allocation key need the whole
    value, so they refuse anything *containing* a term: `eq([$t], [1])` and
    `str({k: $t})` are `NotConcrete`.
  * `branch`, the comparisons, `cardinality`, `has`, `lookup`, `<>`, the
    spine of `map`, `filter`, `scan`, `fold` and the two sorts, a sort key
    and an argument of `format-number` refuse a term given *as* the
    condition, the operand, the container, the collection, the key or the
    argument. A concrete
    structure that holds a term is not special (§1.7): `cardinality([$t])`
    is `1`, `[$t] <> [1]` has two elements, and `map([$t], f)` applies `f` to
    the term.

  The comparisons do **not** become symbolic: a boolean term could only feed
  `branch`, and control flow must be concrete.
* **A term has no projection.** `$t.field` is a `TypeMismatch`: a term stands
  for a number, and a number has no fields.
* A symbol standing for a whole array cannot be summed. It counts as one
  number; that is §1.7's ceiling, unchanged.
* **Equality of terms is structural**, for §4's deduplication: same `op`,
  equal arguments in the same order. `sum($a, 1)` and `sum(1, $a)` are two
  terms.
* A term does not emit and does not allocate. It has no id and no entry in
  the symbol table, so a library may build one from a symbolic parameter
  (§1.4 is about `?`).
* Concrete mode is untouched: no symbol can exist there (§5.1), so no term
  can.

---

## 2. Constraints

### 2.1 `constraint(...)`

```
constraint("gte", $d.replicas, 1)
```

A special form, not a builtin. The name MUST be a string literal with no
interpolation, like an action's event and key (ref §5) — that is what makes
§7's `constraintKinds` computable. The remaining arguments are ordinary
expressions, evaluated where they are written.

```text
Value
  = ...
  | Constraint  name: String, arguments: List<Value>
```

**The form is variadic and its arity is unbounded.** `constraint(name)` with
no arguments is legal, and so is any number beyond. The language fixes no
signature for any name, because the language knows no names: arity is part of
the host's vocabulary exactly as the name is, and a host that receives a
`"gte"` with four arguments rejects it the same way it rejects a kind it does
not implement. Nothing in §7 depends on arity — `constraintKinds` reports
names, not signatures.

This matters for **global constraints** in the MiniZinc sense, which are the
reason to have a constraint list at all rather than a pile of binary
comparisons. They are n-ary over whole collections, and they mix collections
with scalars:

```
!constraint("all-different", $replicas)
!constraint("cumulative", $starts, $durations, $demands, $capacity)
!constraint("global-cardinality", $zones, ["a", "b"], [$lo, $hi])
```

An argument may be an array (§1.7), so a global taking several arrays of
symbols is expressible without any special form of its own; combined with
unbounded arity, the whole family is reachable. **Argument order is
significant and preserved** — position is how a global distinguishes its
starts from its durations — and it is part of the canonical rendering §4
deduplicates on.

An argument may be any JSON value or any symbol. Anything else — a closure, a
builtin, a node, an import — is the `TypeMismatch` the JSON boundary already
raises, through the same code path.

Note what this does **not** do: there is no restricted constraint-expression
grammar and no quoting of argument syntax. `constraint("gt", $x,
$ctx.threshold)` stores `10` when the threshold is concrete and stores a
symbol when it is symbolic. Quoting the syntax instead would make every
constraint produced by a loop identical, since `$item.replicas` is the same
three words on every iteration.

A `Constraint` is **not data**. It MUST NOT cross a JSON boundary: not an
attribute, a payload, an element value slot, a text child, or an expression
program's root. The only construct that may consume one is `!`.

### 2.2 `!` — emission

`!` is a fourth leader character, joining `.`, `$` and `@`. A program is a
sequence of **statements** followed by a root expression:

```text
statement = "@" name "=" expr        -- binding, as today
          | "!" expr                 -- emission
program   = statement* expr
```

`!` is a statement leader only. It may not appear inside an expression.

```
@d   = ?("d")
@min = 1

!constraint("gte", $d.replicas, $min)
!constraint("lte", $d.replicas, 10)
!map($ctx.zones, (z) => constraint("allowed-zone", $d.zone, $z))

.Deployment(name: $d.name, replicas: $d.replicas)
```

`!expr` evaluates `expr` and collects from it by exactly the coercion table
children already use (ref §6):

| value | contributes |
|---|---|
| a constraint | itself, one |
| an array | each element, recursively |
| anything else | `TypeMismatch` |

which is why `!map(...)` reads naturally: an array *is* a sequence, in the
constraint set as much as in a child list.

* A statement sees earlier bindings and not later ones, exactly as a binding
  does.
* `!branch(c, …)` collects only from the selected arm. `Branch` is lazy in
  every position (ref §6) and the unselected arm's constraints do not exist.
* A `Constraint` value never reached by a `!` is discarded. That is the honest
  consequence of constraints being values, and the price of the
  `@cs = map(...)` / `!$cs` split that makes them worth having.

### 2.3 Constraints from libraries

A library's emissions are collected into the same flat list as the root's. A
library is where most constraints will be written, since it is the thing that
knows what its own parameters mean.

A library runs when a field is read off its import (ref §7), so its
constraints are collected at that point, not where the import is written.

### 2.4 Who supplies a symbol

Nothing bubbles at runtime. A library declares a demand; its caller decides
what to put there:

```
@a = ?("a")
@b = ?("b")
import("deployment", {replicas: $a})      -- this one
import("deployment", {replicas: $a})      -- and this one share a variable
import("deployment", {replicas: $b})      -- this one has its own
import("deployment", {replicas: 3})       -- and this one is concrete
```

Symbols are ordinary values, so passing one preserves its identity; no
mechanism beyond that is required. The *demand* bubbles statically instead,
through `deepSymbolDemands` (§7), which tells a root author how many symbols
to allocate and where to pass them without running anything.

---

## 3. Core AST

```text
Expr
  = ... as in ref §2 ...
  | Alloc      site: Int, key: Expr                 -- ?(k)
  | Demand     path: List<String>                   -- ?ctx.a.b
  | Constrain  name: String, arguments: List<Expr>  -- constraint(...)
  | Emit       constraint: Expr, body: Expr         -- !expr
```

`Emit` nests into the chain that bindings already lower to, so

```
@a=1
!c
root
```

is `Let "a" 1 (Emit c root)`. The "earlier bindings only" rule therefore needs
no separate statement machinery, and `Program` is unchanged from ref §2 —
still `DocumentProgram Expr | ExpressionProgram Expr`.

`Emit` is representable anywhere an expression is, but the parser produces it
only at statement position.

---

## 4. Evaluation

Evaluation produces a value **and** an emission record:

```text
Emissions
  symbols     : List<SymbolEntry>   -- allocations, first-occurrence order, deduplicated by id
  constraints : List<Constraint>    -- emission order, deduplicated
```

This is a monoidal output, not mutable state: it is deterministic, it is
threaded through evaluation rather than written to, and it gives `Branch` the
right behaviour for free.

**Evaluation order is prescribed.** ref §13 leaves evaluation order
implementation-defined beyond binding order and `Branch`. v3 removes that
freedom: every implementation MUST evaluate call arguments, array literal
elements, object literal fields and special-form arguments in **source
order**, in addition to the orders ref §6 already fixes for elements.

This is required, not stylistic. `laws.md` demands that evaluation be
deterministic in the result, and in v3 the emission list is part of the
result. It costs nothing: no conforming program could depend on the freedom
being removed, since ref §13 already forbade depending on it. It also makes
error reporting deterministic, which is a free improvement.

**Deduplication.** Two constraints with the same name and equal arguments are
one constraint, kept at the position of the first. Constraints are declarative
facts; asserting one twice says nothing more than asserting it once. This also
makes it unobservable whether an implementation runs a library once or twice
for two field reads on the same import, which ref §7 does not specify.

Allocations are deduplicated by `SymbolId` the same way, so `?("port")`
reached from every element of a `map` produces one symbol table entry.

---

## 5. Modes

An interpreter takes a **mode**. It is a host parameter, not a property of the
program: a host declares what it can read, rather than discovering it from
whichever template it was handed. Which mode a template *needs* is a static
question — `symbolSites` and `deepSymbolDemands` (§7) answer it without
running anything.

### 5.1 Concrete mode

Output is exactly what ref §1 describes: Node JSON for a document program, a
plain JSON value for an expression program. Byte for byte, unchanged. An
expression program still pipes into `jq`; a Node-JSON host still receives Node
JSON and nothing else.

In concrete mode a symbol cannot exist:

| form | concrete mode |
|---|---|
| `?(key)` | `SymbolsUnavailable` |
| `?ctx.path`, supplied | the value the caller supplied; no symbol involved |
| `?ctx.path`, unsupplied at the root | `SymbolsUnavailable` — that is the same minting |
| `!expr` | evaluated; the constraints are discarded |
| `{"$sym": …}` arriving in the context | rejected by the decoder (§5.3) |

Two of those rows are load-bearing:

* **A library written against `?ctx.path` runs in both modes.** Only *minting*
  needs symbolic mode; reading a demand the caller satisfied concretely is an
  ordinary read. That is what makes a constraint-annotated library dual-use
  rather than symbolic-only, and it is the reason the demand form is what
  libraries should be written with.
* **`!` is allowed and discarded**, not refused. A constraint over values the
  caller supplied concretely is a checkable fact about a document that is
  otherwise perfectly correct; refusing would make every annotated library
  unusable in the half of its settings that do not care. The host has said it
  does not consume constraints, and `deepConstraintKinds` (§7) is there for
  the host that would rather refuse the template up front.

So concrete mode is the language of `reference.md` exactly, plus one rule
about `!` and two refusals.

### 5.2 Symbolic mode

```json
{
  "format": "tramaj/symbolic/1",
  "kind": "document",
  "root": { "type": "element", "tag": "Deployment", "...": "..." },
  "symbols": [
    {"id": "#0:\"d\"",
     "origin": {"kind": "alloc", "site": 0, "key": "d"},
     "binding": "d"},
    {"id": "#2:\"web\"",
     "origin": {"kind": "alloc", "site": 2, "key": "web"},
     "binding": null},
    {"id": "#ctx.threshold",
     "origin": {"kind": "demand", "path": ["threshold"]},
     "binding": "t"}
  ],
  "constraints": [
    {"name": "gte",
     "arguments": [{"$sym": "#0:\"d\"", "path": ["replicas"]}, 1]},
    {"name": "allowed-zone",
     "arguments": [{"$sym": "#0:\"d\"", "path": ["zone"]}, "eu"]}
  ]
}
```

* `"kind"` is `"document"` or `"expression"`. `"root"` is Node JSON or a plain
  value accordingly, and is byte-identical to what concrete mode would have
  produced whenever the program uses no symbols.
* **Within a mode the shape is stable.** `"symbols"` and `"constraints"` are
  `[]` for a program that uses none, so a template growing its first `?` does
  not change the shape its host decodes. The shape changes when the host
  changes its mind, never when the template does.
* Only allocations appear in `"symbols"`, and every one of them was allocated
  by the root program, so the table is exactly as long as the author's
  declarations.
* A symbol the host seeded (§5.4) arrives as a value and is echoed wherever it
  was used; the language has nothing to add about it, so it is not listed.
* `"binding"` is the name the allocation was bound to, or `null`. It is a
  name only when the `?(k)` or `?ctx.path` is the whole right-hand side of an
  `@name = …` binding. Used inline it is `null`, and so it is in
  `@x = sum(?ctx.s, 1)`, where `x` names the term and not the symbol. It is
  provenance for humans. `"origin"` is the structured form of `"id"`, so a
  host never has to parse the id.
* A demand's origin `"path"` is the `Demand` path of §3: the segments after
  `ctx`, so `?ctx.a.b` has `["a", "b"]`. The `ctx` root is not repeated; it
  is what `"kind": "demand"` says.
* Every field is REQUIRED. A decoder MUST reject an object missing any of
  them, and MUST NOT infer one from a default — the discipline `node-json.md`
  already sets.
* Numbers are written by `node-json.md`'s rule everywhere in the envelope, so
  `1` and `1.0` stay distinct, inside a term in particular. The residual law
  (§1.9) depends on it, and a host that evaluates terms must read them with a
  parser that keeps the difference.
* A term (§1.9) is carried where it is used, as §5.3's shape. No list is
  added for terms, the envelope's own fields do not change and the format
  stays `tramaj/symbolic/1`. A term can reach a host only if that host
  enabled the arithmetic profile (§5.5), which is the host changing its mind,
  and `deepArithmeticOps` (ref §9) tells it beforehand which operations can
  appear.

A host fold may then: run a solver over `"constraints"`; render an input for
every symbol reachable in `"root"`; ask a user and re-run with the answers
seeded into the context; or compare `constraints[].name` against what it
implements and fail with an unsupported-kind error before doing anything else.

### 5.3 Telling a symbol from an object

`Value` in symbolic mode is JSON extended with tagged shapes, in the style
`node-json.md` already uses to discriminate nodes by `"type"` and attributes
by `"kind"`. A symbol:

```json
{"$sym": "#0:\"d\"", "path": ["replicas"]}
```

and a term (§1.9; not in every implementation yet), whose `op` is one of the ten names
of ref §11's *Arithmetic*, `round` among them:

```json
{"$term": "sum", "arguments": [1, {"$sym": "#0:\"s\"", "path": []}, 2]}
```

Both fields of each are required. `"$term"` is the `op`; `"arguments"` holds
the term's operands in order, each a number, a symbol or a term.

The ambiguity to rule out is a template, or a context, carrying a data object
whose key is `"$sym"` or `"$term"`. Neither can:

* **Object keys in Tramaj are always static.** An object key is a quoted
  string literal or a bare identifier, and ref §5 forbids interpolation there,
  so nothing computes one. `{"$sym": 1}` written in a program is a **parse
  error**, in the same family as ``import("lib-`$x`")``, and so is
  `{"$term": 1}`.
* **`"$sym"`, `"$type"` and `"$term"` are reserved in the value domain in
  both modes and in every profile**, in programs and in contexts alike. A
  context carrying one of these keys is rejected by the decoder: in symbolic
  mode unless it is a well-formed symbol reference or a well-formed term, and
  in concrete mode always. One rule, so a program's legality never depends on
  how a host runs it and a context does not change meaning when a host
  changes mode. Reserving `"$term"` rejects a context that carries that key
  as data, which implementations accept today.
* **The rejection is a `TypeMismatch`**, in both modes, for a reserved key
  and for a malformed symbol reference or term alike. The context is decoded
  whole before evaluation starts, so a context is rejected whether or not
  the program reads the offending part.
* **A well-formed term is one a call could have built** (§1.9). Its object
  has exactly the two keys `"$term"` and `"arguments"`; any other key beside
  them is rejected, as it is beside `"$sym"` and `"path"`. And:
  * `"$term"` is a string naming a known `op`, and `"arguments"` is an array
    with the argument count that builtin takes (one or more for `sum` and
    `product`);
  * each argument is a number, a well-formed symbol reference or a
    well-formed term. An array is not an argument: a term holds its operands
    already flattened;
  * at least one argument is a symbol reference or a term. A nested term is
    held to this whole rule itself, so every term contains a symbol at each
    level;
  * the arguments that are numbers pass the check a call makes (§1.9): they
    agree with each other in type and with what the builtin accepts. A `sum`
    over `1`, a symbol and `2.0` is rejected, and so is a `quotient` of `1`
    by a symbol;
  * each number is read by ref §3's rule, so an integer outside the
    implementation's range is rejected.

  An implementation without the arithmetic profile knows no `op`, so it
  rejects every term.
* Objects are otherwise built only by `<>`, which merges keys from objects
  that came from one of those two sources, so the sources are exhaustive.

`"$type"` is reserved by v3 but unused by it; it is v4's (`v4-types.md`).
Reserving it now costs a key name and avoids breaking the grammar later.

The cost is those three names. The benefit is that the tag sits where a reader
looks for it and plain JSON stays plain: `{"replicas": 3}` remains
`{"replicas": 3}`, rather than the
`{"k":"obj","v":{"replicas":{"k":"num","v":3}}}` that a fully tagged value
domain would cost every attribute of every document.

### 5.4 Seeding

In symbolic mode the input context accepts the same `{"$sym": …}` shape the
output emits, decoded recursively. A host that already knows about a variable
— because a user is filling a form, or because a solver resolved half of them
and the template is being re-run — supplies it as an ordinary context value,
and `?ctx.path` reads it with no allocation. This is what makes the
ask-a-user and re-solve loops work without the template changing.

A well-formed term (§5.3) is accepted the same way, and round-trips. A
malformed one, or one with no symbol inside, is rejected with a
`TypeMismatch`. A seeded number is read by ref §3's rule, like any other
context number.

### 5.5 Profiles

An implementation MAY implement the **core profile** only — the language of
`reference.md`, concrete output, no symbolic extension — and remain
conforming. It MUST reject `?` and `!` **at parse time** rather than ignore
them, so that a symbolic template fails on it instead of quietly losing its
holes and its constraints. §5.3's reserved-key rule belongs to the core
profile too, so that the two grammars agree.

An implementation of the **symbolic profile** implements both modes.

The **arithmetic profile** (ref §11; not in every implementation yet) is a third,
independent of both: either of the above may have it or not. It is not
refused at parse time, since its ten builtins are names and not syntax; a
program that uses one on an implementation without it fails with
`UnboundName`, and `deepArithmeticOps` (ref §9) detects that beforehand. Terms
(§1.9) exist only where the symbolic and arithmetic profiles meet. The two
number types (ref §3) and the reserved `"$term"` key (§5.3) belong to every
profile.

---

## 6. Errors

Three kinds join ref §12's table.

| error | when |
|---|---|
| `NotConcrete` | a symbolic value where the language requires a concrete one — §1.5's table, and a symbol used as an allocation key |
| `AllocationInLibrary` | a program containing `?(k)` is loaded as a library (§1.4) |
| `SymbolsUnavailable` | a symbol would have to be minted in concrete mode (§5.1) |

`TypeMismatch` covers the rest: a constraint value crossing a JSON boundary,
a `!` over something that is neither a constraint nor an array of them, a
projection of a term (§1.9), an array given to a fixed-arity arithmetic
builtin whatever it holds (§1.9), and a context the decoder rejects (§5.3).
A term is a symbolic value, so `NotConcrete` covers it wherever it covers a
symbol, and to the same depth. An
unsupplied `?ctx.path` inside a library is the existing `PathNotFound`,
`InLibrary`-wrapped.

`AllocationInLibrary` has a static counterpart: a program with a non-empty
`symbolSites` cannot serve as a library, and a host building its library table
SHOULD check that up front rather than discover it on whichever path happens
to reach the `?`.

Error message text remains implementation-defined (ref §13); the kinds are
stable.

---

## 7. Static analysis

Answered from the AST alone — no context, no library evaluation, no host code
— alongside ref §9's existing entries.

| function | answers |
|---|---|
| `symbolSites` | the `?(k)` allocation sites this program contains |
| `symbolDemands` / `deepSymbolDemands` | which context paths it declares symbolic with `?ctx.…` |
| `constraintKinds` / `deepConstraintKinds` | which constraint names it can emit |

The deep variants follow imports through the library table with the same
traversal and cycle cutting ref §9's deep analyses already use.

Two of these earn their keep immediately:

* `deepConstraintKinds` lets a host decide whether it supports a template
  before running it — possible only because a constraint's name is a static
  position.
* `deepSymbolDemands` is the counterpart of ref §9's `unsuppliedParams` for
  this feature. Since only the root allocates, knowing which paths the
  libraries beneath will discuss symbolically *is* the whole planning problem,
  and it is answered without running anything.

`symbolSites` reports sites, not keys, which are computed. The number of
symbols is a runtime fact; the number of sites is not, and a site inside a
`map` is exactly where a reader should look to see what distinguishes them.

Like the existing analyses, these over-approximate: a kind emitted only under
a `Branch` arm that no context will select is still reported.

Which operations a program's terms can carry is answered by ref §9's
`arithmeticOps` / `deepArithmeticOps`; terms have no analysis of their own.

---

## 8. Conformance

* `decode(encode(n))` on the envelope MUST preserve the semantic result,
  extending `node-json.md`'s round-trip invariant.
* Symbol ids are exact strings. Two conforming implementations MUST produce
  the same ids, the same symbol table order and the same constraint order for
  the same program and context — which is what §4's prescribed evaluation
  order and §1.4's structural identity exist to guarantee.
* **The residual law** (§1.9): evaluating a term by ref §11's rules, with
  numbers substituted for its symbols, MUST give byte for byte what the
  program gives with those numbers in the context, errors included. A term's
  `op`, its argument order and the type of each number in it are therefore
  exact, like a symbol id.
* The shared corpus `reference.md` §14 calls for is where that is proved. The
  astral-escape divergence recorded in `limitations` is the precedent for why
  neither implementation's own suite would find a disagreement on its own.

Suggested fixture families: allocation identity under `map`; a constant key
under `map`; demand supplied concretely vs. symbolically vs. not at all;
symbols in attributes, payloads, value slots and text children; `!` over a
single constraint, an array, a nested array, and a `branch`; constraint
deduplication; library-emitted constraints; concrete mode refusing a mint and
discarding an emission; every row of §1.5's table. For terms (§1.9): mixed
operands preserved in order; a nested term; a flattened array of symbols;
concrete operands of two types refused; an integer and a float operand each
surviving the envelope; a term in each position a symbol may take; every
refusal; deduplication over equal and over reordered terms; seeding; and the
residual law, as one program run symbolically, then concretely with the symbol
seeded as a number.

---

## 9. Not in v3

| left out | where it went |
|---|---|
| nominal types, declarations, `.types`, typed annotations | `v4-types.md` |
| any solver, domain or propagation | the host's, per §0 |
| a keyless `?` | §1.2 — a symbol always says what distinguishes it |
| allocation inside libraries, and any call-frame identity scheme | §1.4 — the root allocates, so identity is a site and a key |
| symbolic strings, symbolic control flow | §1.5, §1.8 |
| an envelope around concrete output | §5.1 — an expression program's result must still pipe into `jq` |
| inferring the mode from the program | §5 — a template growing its first `?` would silently change the shape its host decodes |

v3 can still express typing informally, because a constraint argument may be
any JSON value: `!constraint("has-type", $d, "Deployment")` is an ordinary
constraint carrying a string, and a host may give it whatever meaning it
likes. What v4 adds is nominal identity, library-exported declarations and a
namespace, so that two libraries' `Card` are distinguishable and a type
reference is resolved rather than spelled.

Recorded as considered and declined, to be revisited only if practice asks:

1. **A key on the demand form**, `?ctx.threshold($s.name)`. Seeding (§5.4)
   covers the case a host drives and `?(key)` the case a template drives; this
   is worth it only if something needs both at once.
2. **A `label` field on the symbol table entry.**
   `!constraint("label", $x, "Replicas")` already says it, and says it in the
   host's vocabulary rather than the language's.
3. **Symbolic strings.** §1.8 has the cost: the value domain would gain string
   terms, over a vocabulary that is not closed. Arithmetic took that step for
   numbers (§1.9) because numbers have no alternative and its ten operations
   are closed; text has one, separate children, which a form renderer wants
   anyway.
