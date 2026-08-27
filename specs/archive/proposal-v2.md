# Proposal — symbolic values, emitted constraints, and minimal typing

Status: proposal. `specs/reference.md` is the language as it stands; nothing
below is implemented. This document is deliberately narrower than
`plan-v2-full`, and §9 says what it drops and why.

**A note on the name.** This repository already spent an iteration calling the
current language v2 (`specs/decisions.md`, branch `tramaj-v2`), with v1 being
the two-AST template language. Calling this work "v2" as well will confuse the
next reader. The file is named as asked; inside, the feature set is called the
**symbolic extension**, and any version number it eventually needs should be
v3.

---

## 0. The thesis

Everything here follows from one rule the language already applies to actions
and to import names:

> **Tramaj fixes positions and identity. The host owns vocabulary and meaning.**

An action's event and key are static positions; what `"on-click"` *means* is
the host's business (§10). This proposal says the same thing about symbolic
variables, constraints and types:

| the language guarantees | the host decides |
|---|---|
| a symbolic variable exists, and *which* one it is | what its type name means |
| a constraint was emitted, with these arguments | what `"gte"` means, and how to solve it |
| the set of constraint kinds a program can emit, statically | whether it supports them |

So Tramaj never solves anything, never checks a type, and never has an opinion
about `Int`. It evaluates as far as it can, and serializes what it could not
resolve so that a host fold can run a solver, ask a user, render a form, or
refuse with an unsupported-kind error.

Three additions carry that: a `?` expression, a `!` statement, and an output
envelope that carries both, for the hosts that ask for it.

---

## 1. Symbolic values

### 1.1 `?`

`?` introduces a **symbol**: a value the language carries around but never
inspects. It has two forms, and neither of them is bare — a symbol always says
what makes it the symbol it is.

```
@replicas = ?("replicas")     -- mint one, here, under this key
@threshold = ?ctx.threshold   -- the one my caller gives me
```

`Value` gains one constructor:

```text
Value
  = ... as today ...
  | Symbol  id: SymbolId, path: List<String>
```

A symbol with an empty `path` is an *allocation*; a non-empty path is a
*projection* of one (§1.5).

### 1.2 What may be done with a symbol

The rule that keeps this from becoming a second evaluator:

> **Control flow and structure must be concrete. Only data may be symbolic.**

A symbol is data. It may be bound, passed to a lambda, returned, stored in an
array or object, placed in an attribute, an action payload, an element value
slot, or a text child. Everything that would require the language to *know*
something about it is an error:

| expression | result |
|---|---|
| `$sym`, `[$sym]`, `{k: $sym}` | fine — it is a value |
| `.p($sym)`, `.div(class: $sym)`, `action(e, k, {r: $sym})` | fine — §4's envelope carries it |
| `$sym.field` | a projection (§1.5) — **the one exception** |
| `branch($sym, …)` | `NotConcrete` — no arm can be selected |
| `map($sym, f)`, `filter`, `scan`, `fold` | `NotConcrete` — the spine has no length |
| `eq`, `lt`, `lte`, `gt`, `gte` on anything *containing* a symbol | `NotConcrete` |
| `str($sym)`, and so any interpolation of one | `NotConcrete` — see §1.7 |
| `cardinality($sym)`, `has($sym, k)`, `lookup($sym, k, d)` | `NotConcrete` |
| `$sym <> x` | `NotConcrete` |

`has` and `lookup` are singled out because both are deliberately *tolerant*
today — `has` answers `false` for a wrong-shaped container and `lookup` never
errors. Neither may answer about a symbol: a tolerant `false` would be a lie,
and `lookup`'s fallback would silently discard the symbol. They error.

Consequence worth stating: you can constrain the elements of a list whose
length is known, and you cannot constrain a list whose length is symbolic.
That is the ceiling this design buys, and it is where a real symbolic
evaluator would have to start. Deciding not to go there is what keeps `map`
free of any `if value is Symbol` branch.

### 1.3 Only the root program allocates

The governing rule, and the reason the identity scheme is three lines long:

> **A symbol is allocated only in the root program, because the root program
> runs exactly once. A library does not, so a library may not allocate.**

A library that wants a symbol *declares that it needs one* and its caller
supplies it (§1.4). Allocation never happens implicitly, never happens at a
depth, and is never keyed on anything the author did not write down.

```
@a = ?("primary")
@b = ?("secondary")
@ports = map($ctx.services, (s) => ?($s.name))
```

`?(key)` allocates. Its identity is **the site and the key**: the site is the
occurrence's index in source order, assigned by the parser, and the key is any
concrete JSON value, rendered by the canonical form `str` already defines in
§6 — compact, keys sorted, numbers by ECMAScript's rule. A symbol as a key is
`NotConcrete`.

```text
?("primary")   at site 0  ->  #0:"primary"
?($s.name)     at site 2  ->  #2:"web",  #2:"api",  …
```

The site is in the id as well as the key so that two independent
`?("replicas")` in different parts of a template are different variables. A
key is a name for a distinction, not a global name for a variable.

Identity is a function of the program text and of one value the author chose.
It does not depend on evaluation order, which `specs/reference.md` §13 leaves
implementation-defined, so two implementations agree on symbol ids by
construction rather than by agreeing on a traversal.

**The key is the whole safety mechanism.** There is no keyless form, so the
question "did this `?` mean one variable or many?" is always answered in the
source:

```
map($ctx.services, (s) => ?($s.name))   -- one per service
map($ctx.services, (s) => ?("port"))    -- one, shared by every service
```

The second is legal and means exactly what it says. A constant key is a
constant symbol; that is what writing a constant is for. What has been removed
is the version where the author wrote nothing and the language guessed.

`branch` laziness applies as usual: an allocation in an unselected arm does not
happen, and one that is never reached simply does not appear in the output.

### 1.4 `?ctx.path` — declaring a demand, and letting the caller decide

```
-- library "deployment"
@r = ?ctx.replicas
!constraint("gte", $r, 1)
.Deployment(replicas: $r)
```

`?ctx.a.b` reads `$ctx.a.b` and declares *this value is one I will discuss
symbolically*. At runtime, in a library, it means exactly what `$ctx.a.b`
means: whatever the caller supplied — a number, a symbol, anything. The
distinction is entirely static, and that is the same trade `ctx(path)` already
makes for import parameters (§7): a path in a static position is a demand an
analyzer can enumerate, where the same read buried in an arbitrary expression
is not.

The caller decides what to put there, which is the whole mechanism:

```
@a = ?("a")
@b = ?("b")
import("deployment", {replicas: $a})      -- this one
import("deployment", {replicas: $a})      -- and this one share a variable
import("deployment", {replicas: $b})      -- this one has its own
import("deployment", {replicas: 3})       -- and this one is concrete
```

Nothing bubbles at runtime; the *demand* bubbles statically. A library that
reads a path nobody supplied fails with its own error, wrapped in `InLibrary`
naming it, exactly as §7 already specifies for ordinary reads — and §7's
`unsuppliedParams`, plus the new `deepSymbolDemands` (§7 below), tells the
root author how many symbols to allocate without running anything.

**At the root, an unsupplied demand allocates.** The root's caller is the host,
and the host may decline to supply, in which case `?ctx.threshold` becomes the
symbol `#ctx.threshold`. This is the same rule one level up, not an exception
to it: the frame that reads the demand is the root, the root runs once, so it
may allocate. In a library an unsupplied demand is an error, because the
library cannot know how many of itself there are.

**The host may seed symbols.** In symbolic mode the context accepts the same
`{"$sym": …}` form the output uses (§4), so a host that already knows about a variable — because
a user is filling a form, or because a solver resolved half of them and the
template is being re-run — supplies it as an ordinary context value.
`?ctx.path` then reads that symbol and no allocation happens at all. This is
what makes the ask-a-user and re-solve loops work without the template
changing.

### 1.5 Projection

`$sym.field` does not read anything. It produces a symbol with the same `id`
and the path extended:

```text
Symbol "#0:\"d\"" []            -- $d
Symbol "#0:\"d\"" ["replicas"]  -- $d.replicas
Symbol "#0:\"d\"" ["a","b"]     -- $d.a.b
```

Tramaj computes no type for a projection and rejects nothing: whether
`Deployment` has a `replicas` field is a question for whoever owns the type
vocabulary. `PathNotFound` is for concrete values that demonstrably lack a
field; a symbol demonstrably lacks nothing.

### 1.6 Symbols inside structures

Two different things get called "an array of symbols", and only one of them is
a problem.

**A concrete structure containing symbols is not special.** `[?("a"), ?("b")]`
is an ordinary two-element array that happens to hold symbols; `{a: ?("a")}`
is an ordinary object. The spine is concrete, so everything structural works
normally — `cardinality` counts, `map` iterates, a field read returns the
symbol it finds, `<>` merges. In particular:

```
@ports = map($ctx.services, (s) => ?($s.name))
!map($ports, (p) => constraint("gte", $p, 1024))
.ul(map($ports, (p) => .li($p)))
```

is fine end to end: `map` never inspects an element, and `<>` merges keys
without comparing values. Only the operations that *inspect* a value refuse —
`eq` and the comparisons, if a symbol is reachable in either operand.

**A symbol that is itself structured is the ceiling.** `@d = ?("d")` then
`$d.replicas` projects fine, but `map($d.items, f)` is `NotConcrete`, because
the language does not know how long `$d.items` is. A symbol may *have*
structure as far as the host's type vocabulary is concerned; the language
cannot walk it. This is §1.2's rule and it is the deliberate limit.

So the answer to "what about arrays of symbols" is: build the array in the
language, out of symbols the author allocated with distinct keys, and there is
no problem. Ask the language to iterate a symbolic array and it says so
plainly. Two other cases fall out of the same rule:

* a symbol cannot be an object key — keys are static (§5), and nothing
  computes one;
* a symbol inside an import's parameters is just a value being passed, so it
  crosses the boundary preserving its identity, which is §1.4's mechanism.

### 1.7 Symbols in text

`str` refuses symbols, so `` "Deploy `$r` replicas" `` is `NotConcrete`. The
example to vet:

```
.p("Deploy ", $r, " replicas")
```

Three children — two text nodes carrying strings and one carrying the symbol —
which is what a form renderer wants anyway: it needs to put an input where the
symbol is, and it cannot do that if the symbol has been flattened into the
middle of a string. The concrete case is unaffected, because if `$r` is a
number the same element produces the same three text children and any host
that concatenates text gets the identical result.

Reconstructing a string, if a downstream consumer wants one, is that
consumer's job — it has the pieces in order and knows what its target does
with them, which the language does not.

The alternative is to let `str` produce a *symbolic string* — a value that is
neither a variable nor a literal but a term built from both. That is a much
larger design: the value domain gains expressions, the envelope has to
serialize them, and a solver has to interpret string concatenation. Refusing
is the small answer, and the workaround above is one character longer than the
interpolation it replaces.

---

## 2. Constraints

### 2.1 `constraint(...)` is a value

```
constraint("gte", $d.replicas, 1)
```

A special form, not a builtin, so the name sits in a static position exactly
like an action's key — that is what makes §7's `constraintKinds` computable.
Arguments are ordinary expressions, evaluated where they are written.

```text
Value
  = ...
  | Constraint  name: String, arguments: List<Value>
```

An argument may be any JSON value, any symbol, or a type reference (§3).
Anything else — a closure, a builtin, a node, an import — is the same
`TypeMismatch` the JSON boundary already raises, through the same code path.

Note what this deliberately does *not* do: there is no restricted
`ConstraintExpr` grammar, and no quoting of the argument syntax. Arguments are
evaluated like every other argument in the language. `constraint("gt", $x,
$ctx.threshold)` with a concrete threshold of `10` stores `10`; with a
symbolic one it stores that symbol. This is what makes the `map` case below
work at all — quoted syntax would make every constraint produced by a loop
identical, because `$item.replicas` is the same three words on every
iteration.

A `Constraint` is **not** data. It may not cross a JSON boundary, so it cannot
appear in an attribute, a payload, a value slot, a text child, or an
expression program's root. The only thing that may consume it is `!`.

### 2.2 `!` emits

A fourth leader character joins `.`, `$` and `@`:

```
@d = ?("d")
@min = 1

!constraint("gte", $d.replicas, $min)
!constraint("lte", $d.replicas, 10)
!map($ctx.zones, (z) => constraint("allowed-zone", $d.zone, $z))

.Deployment(name: $d.name, replicas: $d.replicas)
```

A program is now: type declarations (§3.2), then a sequence of statements —
each a binding `@name=expr` or an emission `!expr` — then the root expression.
A leader on every non-root line keeps the grammar unambiguous and keeps the
root "the one thing that starts with neither".

`!expr` evaluates `expr` and collects, by exactly the coercion table children
already use:

| value | contributes |
|---|---|
| a constraint | itself, one |
| an array | each element, recursively |
| anything else | `TypeMismatch` |

which is why `!map(...)` reads naturally: an array *is* a sequence, in the
constraint set as much as in a child list.

* Collection is in source order, and within an array in element order. The
  emitted list is deterministic.
* A statement sees earlier bindings and not later ones, like every binding.
* `!branch(c, …)` emits only from the selected arm — `Branch` is lazy in every
  position (§6), and the unselected arm's constraints simply do not exist.
* Constraints emitted inside a library are collected too, and land in the same
  flat list as the root's. A library is where most constraints will be
  written, since it is the thing that knows what its own parameters mean.
* A `Constraint` value that is never reached by a `!` is discarded, silently.
  That is the honest consequence of constraints being values; the alternative
  is to make them un-bindable, which would cost the `@cs = map(...)` / `!$cs`
  split that makes them worth having.

### 2.3 Core AST

```text
Expr
  = ...
  | Alloc      site: Int, key: Expr                -- ?(k)
  | Demand     path: List<String>                  -- ?ctx.a.b
  | Constrain  name: String, arguments: List<Expr>
  | Emit       constraint: Expr, body: Expr
```

`Emit` nests into the same chain the bindings already lower to, so
`@a=1` `!c` `root` becomes `Let "a" 1 (Emit c root)` and the "earlier bindings
only" rule needs no separate statement.

Evaluation gains one output: an expression evaluates to a value **and** a
record of what it emitted and allocated, concatenated in evaluation order.
This is a monoidal output, not global mutable state — it does not fight value
semantics any more than a `Node` does, it is deterministic, and it gives
`Branch` the right behaviour for free.

---

## 3. Minimal typing

Two stages, and the first is three lines of desugaring.

### 3.1 Annotations are constraints

```
@d : Deployment = ?("d")
@n : string = $ctx.name
```

`@x : T = e` is **sugar** for the binding plus an emission:

```text
@x = e
!constraint("has-type", $x, T)
```

That is the whole typing feature. There is no separate judgment kind, no
second output list, and no in-language checker — a host that wants types
implements the `has-type` constraint, and a host that does not reports it as
an unsupported kind along with everything else it does not support.

A type reference is not a value and cannot be written anywhere else; it is
legal only in an annotation position, where it lowers into a constraint
argument.

```text
TypeRef
  = Named  library: Optional<String>, name: String
  | Array  element: TypeRef
```

`[string]` is the array form. **No type names are built in.** `string`,
`number`, `Int`, `Deployment` are all just names, and which of them mean
anything is the host's business — the same arrangement as action events. What
the language guarantees is that the *position* is static and the set of
referenced names is enumerable without evaluating (§7).

### 3.2 Declarations and `.types` — severable

Only needed when a library wants to export a type name to its importers.

```
type Deployment = {
  name:     string
  replicas: number
}

@d : Deployment = ?ctx.deployment
```

and across a library boundary:

```
@lib = import("deployment", {})
@d : $lib.types.Deployment = ?("d")
```

* Declarations sit before the statements. `Program` gains a declaration list —
  the one breaking change to the AST in this proposal, and only at this stage;
  §1 and §2 leave `Program` alone.
* Tramaj does not interpret a declaration. It resolves the *reference* —
  `$lib.types.X` must name a library the table resolves and a `type X` that
  library declares — and emits the declarations the program references, so a
  host can interpret them. Field types are not checked against anything.
* Nominal identity is `(library, name)` where `library` is the **host table
  key**, not the binding. `@a=import("foo",{})` and `@b=import("foo",{})` give
  `$a.types.Card` and `$b.types.Card` the *same* identity, because they are
  the same type. Since import names are table keys, aliasing is impossible.
* `$lib.types.X` is not a runtime field read. It is resolved statically, which
  means `lib` must be bound *directly* to an `import(...)` in the enclosing
  binding chain; an import reached through a lambda, an array or a later
  saturating call cannot be resolved and is an error at analysis.
* Resolution follows imports through the library table with the same cycle
  cutting §9's deep analyses already use. **No library is evaluated** to
  resolve a type: the table holds parsed `Program`s, so this is an AST walk.

Products only. Sums are §9.

---

## 4. Output and modes

An interpreter takes a **mode**, and the mode decides the output shape. It is
a host parameter, not a property of the program: a host declares what it can
read, rather than discovering it from whichever template it was handed.

Which mode a template needs is a static question — `symbolSites` and
`deepSymbolDemands` (§7) answer it without running anything — so a host that
wants to choose per template can, and a host that only ever does one thing
never has to think about it.

### 4.1 Concrete mode — the default

Output is exactly what it is today: Node JSON for a document program, a plain
JSON value for an expression program. Byte for byte, unchanged, forever.
Piping an expression program into `jq` keeps working, and no host that does
not want symbols has to learn anything.

In concrete mode a symbol cannot exist at all:

| form | concrete mode |
|---|---|
| `?(key)` | error — minting a hole for a host that cannot represent one |
| `?ctx.path`, supplied | the value the caller supplied; no symbol involved |
| `?ctx.path`, unsupplied at the root | error — that is the same minting, refused |
| `!expr` | evaluated, constraints discarded |
| `{"$sym": …}` arriving in the context | error (§4.3) |

Two things in that table are load-bearing:

* **A library written against `?ctx.path` runs in both modes.** Only *minting*
  needs symbolic mode; reading a demand the caller satisfied concretely is an
  ordinary read. That is what makes a constraint-annotated library dual-use
  rather than symbolic-only, and it is the strongest argument for the demand
  form being the one libraries are written with.
* **`!` is allowed and discarded**, rather than refused. A constraint over
  values the caller supplied concretely is a checkable fact about a document
  that is otherwise perfectly correct, and refusing would make every annotated
  library unusable in the half of its settings that do not care. The host has
  said it does not consume constraints; `deepConstraintKinds` (§7) is there
  for the host that would rather refuse up front.

So concrete mode is today's language exactly, plus one rule about `!` and two
refusals. That is what a core-only implementation implements (§4.4).

### 4.2 Symbolic mode — the envelope

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
     "origin": {"kind": "demand", "path": ["ctx", "threshold"]},
     "binding": "t"}
  ],
  "constraints": [
    {"name": "has-type",
     "arguments": [{"$sym": "#0:\"d\"", "path": []},
                   {"$type": {"kind": "named", "library": null,
                              "name": "Deployment"}}]},
    {"name": "gte",
     "arguments": [{"$sym": "#0:\"d\"", "path": ["replicas"]}, 1]}
  ],
  "types": []
}
```

* `"kind"` is `"document"` or `"expression"`; `"root"` is Node JSON or a plain
  value accordingly, and is byte-identical to what concrete mode would have
  produced whenever the program uses no symbols.
* **Within symbolic mode the shape is stable.** The three lists are `[]` for a
  program that uses none, so a template that grows its first `?` does not
  change the shape its host decodes. The shape changes when the *host* changes
  its mind, never when the template does.
* Only *allocations* appear in `symbols`, and every one of them was allocated
  by the root program, so the table is exactly as long as the author's
  declarations. A projection is a reference with a non-empty `path`; the host
  resolves its type from the root's declared type and `"types"`.
* A symbol the host seeded arrives as a value and is echoed wherever it was
  used; the language has nothing to add about it, so it does not appear in
  `symbols`.
* `"binding"` is provenance for humans and may be `null`. `"origin"` is the
  structured form of `"id"`, so a host never has to parse it.
* Every field is REQUIRED and a decoder must reject an object missing one,
  matching the discipline `node-json.md` already sets.

What a host fold can then do, which is the point of the exercise: run a solver
over `constraints`; render an input for every symbol reachable in `root`; ask
a user and re-run with the answers seeded into the context; or compare
`constraints[].name` against what it implements and fail with an
unsupported-kind error before doing anything else.

### 4.3 How a symbol is told apart from an object

`Value` in symbolic mode is JSON extended with two tagged shapes, in the same
style `node-json.md` already uses to discriminate nodes by `"type"` and
attributes by `"kind"`:

```json
{"$sym": "#0:\"d\"", "path": ["replicas"]}
{"$type": {"kind": "named", "library": null, "name": "Deployment"}}
```

The ambiguity to worry about is a template, or a context, carrying a data
object whose key is `"$sym"`. Neither can:

* **Object keys in Tramaj are always static.** `objectKey` is a quoted string
  literal or a bare identifier (`Parser.hs:269`), and §5 already forbids
  interpolation there, so nothing computes a key. `{"$sym": 1}` written in a
  program is therefore a **parse error**, in the same family as
  ``import("lib-`$x`")``.
* **`"$sym"` and `"$type"` are reserved in the value domain in both modes** —
  in programs and in contexts alike. A context carrying either key is rejected
  by the decoder: in symbolic mode because it must be a well-formed symbol or
  type reference, in concrete mode because no such thing can exist there. One
  rule, so a program's legality never depends on how a host runs it, and a
  context does not change meaning when a host changes mode.
* Objects can also be built by `<>`, which merges keys from objects that came
  from one of those two sources. So the sources are exhaustive.

The cost is two reserved key names, stated plainly. The benefit is that the
tag lives where a reader will look for it and the plain JSON stays plain —
`{"replicas": 3}` is still `{"replicas": 3}`, not
`{"k":"obj","v":{"replicas":{"k":"num","v":3}}}`, which is what a fully tagged
union would cost every value in every attribute of every document.

### 4.4 Profiles

An implementation MAY implement the **core profile** only — the language as
`specs/reference.md` describes it, concrete mode, no symbolic extension — and
remain conforming. It MUST reject `?`, `!`, `:` annotations and `type`
declarations **at parse time** rather than ignore them, so that a symbolic
template fails on a core implementation instead of quietly losing its holes
and its constraints. The reserved-key rule of §4.3 belongs to the core profile
too, so that the two grammars agree.

An implementation of the **symbolic profile** implements both modes.

---

## 5. Errors

Two new kinds join §12's table:

| error | when |
|---|---|
| `NotConcrete` | a symbolic value where the language needs a concrete one — §1.2's table, and a symbol used as an allocation key |
| `AllocationOutsideRoot` | `?(k)` evaluated inside a library (§1.3); `InLibrary`-wrapped like any other library failure |
| `SymbolsUnavailable` | a symbol would have to be minted in concrete mode — `?(k)`, or an unsupplied `?ctx.path` at the root (§4.1) |

`TypeMismatch` covers the rest: a constraint value outside `!`, and a `!` over
a non-constraint. An unsupplied `?ctx.path` inside a library is the existing
`PathNotFound`, also `InLibrary`-wrapped — the same error an ordinary
unsupplied read already produces.

`AllocationOutsideRoot` also has a static counterpart: a program with a
non-empty `symbolSites` (§7) cannot be used as a library, and a host building
its library table can check that up front rather than discovering it on
whichever path happens to reach the `?`.

---

## 6. Worked example

The root allocates, the library discusses.

```
-- library "deployment"
type Deployment = {
  name:     string
  replicas: number
  zone:     string
}

@d : Deployment = ?ctx.deployment

!constraint("gte", $d.replicas, 1)
!constraint("lte", $d.replicas, $ctx.max-replicas)
!map($ctx.zones, (z) => constraint("allowed-zone", $d.zone, $z))
!constraint("label", $d.replicas, "Replicas")

.Deployment(
  name:     $d.name,
  replicas: $d.replicas,
  action("on-submit", "deploy", {"deployment": $d}))
```

```
-- root
@dep = import("deployment", {max-replicas: ctx(max-replicas),
                             zones:        ctx(zones)})

.main(map($ctx.services,
          (s) => $dep({"deployment": ?($s.name)}).rendered))
```

One symbol per service name, allocated at one site in the root, with the key
saying what makes them distinct. The library emits five constraints per
service against whichever symbol it was handed, and none of them depend on
knowing how many there are. Change `?($s.name)` to `?("one")` and every
service shares one variable — legal, and now a thing the author wrote down.

The `label` constraint is the point of §0 in miniature: the language does not
know what a label is, a form-rendering host does, and a YAML host ignores it
alongside every other kind it has no use for. Anything that would otherwise
want a new field on the symbol table can be said this way first.

---

## 7. Static analysis

Following §9's existing shape, answered from the AST with no evaluation:

| function | answers |
|---|---|
| `symbolSites` | the `?(k)` allocations this program contains |
| `symbolDemands` / `deepSymbolDemands` | which context paths it declares symbolic with `?ctx.…` |
| `constraintKinds` / `deepConstraintKinds` | which constraint names it can emit |
| `typeReferences` / `deepTypeReferences` | which type names it refers to |
| `typeDeclarations` | which it declares |

Two of these earn their keep immediately:

* `deepConstraintKinds` lets a host decide whether it supports a template
  *before* running it, which is only possible because `constraint`'s name is a
  static position.
* `deepSymbolDemands` is the counterpart of §9's `unsuppliedParams` for this
  feature: it tells the root author which paths the libraries beneath it will
  discuss symbolically, and therefore how many symbols to allocate and where
  to pass them. Since only the root allocates, that is the whole planning
  problem, and it is answered without running anything.

`symbolSites` reports the allocation sites but not the keys, which are
computed. The count of symbols is a runtime fact; the count of *sites* is not,
and a site inside a `map` is exactly where a reader should look to see what
distinguishes them.

Like the existing analyses these over-approximate: a kind emitted only under a
`Branch` arm no context will select is still reported.

---

## 8. Staging

Each stage is independently shippable and each leaves the language usable.
Existing hosts are untouched throughout: they stay in concrete mode, where the
output is byte-identical to today's.

1. **Symbols.** The mode flag, `?(key)`, `?ctx.path`, `Symbol` in `Value`,
   root-only allocation, §1.2's concreteness rule, projection, the envelope,
   the `$sym` shape in and out, and the reserved-key rule.
   `NotConcrete` / `AllocationOutsideRoot` / `SymbolsUnavailable`. Useful
   alone: a host can render a form from a template full of holes.
2. **Constraints.** `constraint(...)`, `!`, the collection output, the
   envelope's `constraints`, `constraintKinds`, and `!`-discards in concrete
   mode.
3. **Annotations.** `@x : T = e` and `TypeRef`, as sugar over `has-type`.
   Small.
4. **Declarations.** `type` declarations, `$lib.types.X`, static resolution
   through the table, the `Program` change. Severable — stages 1–3 are
   complete without it, with type names owned entirely by the host.

Cross-implementation conformance is not a stage. Symbol ids are exact strings,
so the corpus `specs/reference.md` §14 already asks for is the thing that
proves the identity scheme agrees between PureScript and Haskell — the astral
escape bug in `limitations` is the precedent for why neither suite alone would
find a disagreement.

---

## 9. Deliberately out

| dropped | why |
|---|---|
| any solver, domains, interval propagation | the host's job, per §0 |
| any type *checking* | likewise |
| built-in type names, `Int` in particular | numbers are doubles (§13); an integer type is a host refinement, not a language primitive |
| discriminated sums | products cover the annotation case; add them when a host needs them |
| a restricted `ConstraintExpr` grammar | arguments are evaluated, so what is rejectable is a *value* — which `toJson` already decides |
| `require(e : T)` as its own form | it is `!constraint("has-type", e, T)`; add it as sugar if it earns its place |
| bare `?` | a symbol always says what distinguishes it (§1.3); without a key the language would have to guess, which is the failure mode this design exists to remove |
| allocation inside libraries, and any call-frame identity scheme | §1.3 — the root allocates, so identity is a site and a key and nothing has to be keyed on a call tree |
| symbolic strings and symbolic control flow | §1.2, §1.7 |
| an envelope around concrete output | §4.1 — an expression program's result must still pipe into `jq`, and a Node-JSON host must still get Node JSON |
| inferring the mode from the program | §4 — a template that grew its first `?` would silently change the shape its host decodes; the host declares what it can read |

---

## 10. Suggestions, if practice asks for them

Not proposed. Recorded so the next reader knows they were considered and what
would justify them.

1. **A key on the demand form**, `?ctx.threshold($s.name)`, for a host-fillable
   per-item hole. Seeding (§1.4) covers the case a host drives and `?(key)`
   covers the case the template drives, so this is only worth it if something
   needs both at once.
2. **A `label` field on the symbol table entry.** `!constraint("label", …)`
   says it already (§6). Promote it only if hosts converge on wanting it and
   the constraint list turns out to be the wrong place to look for it.
3. **Symbolic strings**, so interpolation can span a hole. §1.7 has the
   example and the cost: the value domain would gain terms, not just
   variables.
4. **Discriminated sums** in type declarations, when a host has a use for the
   discriminator that products cannot express.
