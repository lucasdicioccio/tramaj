# Tramaj v4 — Types (draft)

Status: **draft, not frozen.** Split out of the v3 design so that
[`v3-symbols.md`](v3-symbols.md) could be frozen without waiting on the type
questions. Nothing here is settled and nothing is implemented.

v3 is complete without this document. A constraint argument may be any JSON
value, so a v3 program can already say `!constraint("has-type", $d,
"Deployment")` and a host may give that whatever meaning it likes. What v4
adds is everything that string cannot do: **resolution**, so a name means a
declaration rather than itself; **parameterisation**, so a library can export
a type it does not fully know; **an algebra**, so types can be built rather
than only named; and **identity**, so two spellings of the same type are the
same type.

The thesis is unchanged from v3 §0 — *Tramaj fixes positions and identity; the
host owns vocabulary and meaning.* So v4 still contains **no typechecker**. It
resolves references, normalises type expressions, collects declarations and
constraints, and refuses to leave a hole unfilled. It checks nothing against
anything. The phase order is the point:

```text
parse  ->  analyse  ->  evaluate  ->  someone else checks
           ^ types live entirely here      ^ a-priori accepted, may be rejected
```

A program that reaches evaluation has a complete, resolved, hole-free set of
types. Whether those types are *true* of the values is a question for a
checker that runs on the concrete output, and Tramaj never asks it.

---

## 0. Two realms

v3 gave values a leader for "supplied from outside": `?`. Types get their own,
`%`, and the two realms stay separate.

| | values | types |
|---|---|---|
| leader | `?` | `%` |
| supplied by | the **host**, after evaluation | the **caller**, before evaluation |
| identity | allocation site + key (v3 §1.4) | the normal form (§3) |
| may remain open | yes — that is the output | **no** — unfilled is an error (§4) |
| constraints | `!constraint(...)`, evaluated | `!type-constraint(...)`, static (§5) |
| lives until | the host resolves it | erased before evaluation (§7) |

The asymmetry in row three is the whole reason they are separate. A symbol is
*meant* to survive into the output — an unresolved symbol is the deliverable.
A type is not: it is scaffolding for a checker, and scaffolding with a gap in
it is a bug, not a product.

Unifying the two — symbolic types constrained the way symbolic values are, so
that a host could *choose* a type the way it chooses a value — is a research
direction, noted in §11 and deliberately not taken here.

---

## 1. The algebra

```text
TypeExpr
  = Prim     name: String                              -- string number bool null document
  | Array    element: TypeExpr                         -- [T]
  | Record   fields: Map<String, TypeExpr>             -- { a : T, b : U }
  | Union    arms:   Map<String, Optional<TypeExpr>>   -- | A T | B U | C
  | Ref      library: String, name: String,            -- a declaration, with its
             arguments: Map<String, TypeExpr>          --   type arguments
  | Var      path: List<String>                        -- %ctx.a.b  -- a hole
```

Six constructors, closed. There is no function type, no type-level
abstraction, and no way for a type to depend on a value.

**The primitives are exactly the value domain's own shapes** and nothing else.
`string`, `number`, `bool`, `null` and `document` are what ref §3 already
fixes, so Tramaj can be said to know them without learning anything new.
`Int` is deliberately absent: numbers are doubles and their precision past
2^53 is implementation-defined (ref §13), so an integer type is a host-side
refinement of `number`, not a language primitive. Building it in would oblige
both implementations to agree on a boundary the value domain does not have.

### 1.1 Declarations

```
type Point   = { x : number, y : number }
type Shape   = | Circle { r : number } | Square { s : number }
type UserId  = string
type Message = { to : string, payload : %ctx.payload }
```

* **Declarations are nominal.** `type UserId = string` does not make `UserId`
  and `string` the same type; it declares a new one whose definition is
  `string`. Newtyping is therefore not a separate feature — it is what a
  declaration *is*, and `type OrderId = string` is a different type from
  `UserId` for the reason a Haskeller expects.
* Nominal identity is **`(library, name)` plus arguments** (§3), where
  `library` is the host table key, not the binding. `@a=import("foo",{})` and
  `@b=import("foo",{})` give `$a.types.Card` and `$b.types.Card` the same
  identity, because they *are* the same type. Since import names are table
  keys, aliasing is impossible.
* Records and unions are **structural** where they appear anonymously, and get
  nominal identity only by being the definition of a declaration. `{x:
  number}` written in two annotations is one type; `Point` and `Vec2` with
  identical bodies are two.
* A union arm may carry a payload or not. `| Dev | Staging | Prod` is an
  enum — the case that matters most, because a hole of that type is a
  variable with a finite domain, which is precisely what a solver can search
  and a form renderer can render.

### 1.2 What Tramaj does not say about a union

Nothing about how a value inhabits an arm. Tramaj declares the arms; whether
the host reads a `"tag"` field, a wrapper object, or a discriminating shape is
the host's convention, on the same footing as what an action key means. This
is the one place the thesis has real teeth: the language could mandate a
discriminator field, but it could not enforce one — the values come from
`$ctx` or from a solver — so mandating it would buy an opinion without the
means to back it.

---

## 2. Type parameters are import parameters

This is the load-bearing decision. A library is parameterised over types the
same way it is parameterised over values: through its context.

```
-- library "message"
type Envelope = { to : string, payload : %ctx.payload }
```

`%ctx.payload` is a **type variable**: the type named `payload` in this
library's context. The importer supplies it in the ordinary params record,
marked with `%` because a type is not a value:

```
@msg = import("message", {payload: %Json})
@m : $msg.types.Envelope = ?("m")
```

Everything the import machinery already does applies unchanged:

* **Partial application** (ref §7c). `@msg = import("message", {})` is a
  partial import whose `Envelope` is a *partial* type. Saturating the import
  saturates the type. "Three partially-applied arguments for one and two for
  the other" falls out of a mechanism that already exists, rather than from a
  type-level arity discipline.
* **Deferral.** `import("inner", {payload: %ctx.payload})` forwards *this*
  library's type variable to the inner one — the exact type-level reading of
  `ctx(path)`, and the answer to §6's question.
* **`unsuppliedParams`** (ref §9) already computes what is missing; §9 below
  adds the type-side split.

So there is no new parameterisation mechanism, no type-level lambda, no arity
to check, and no second notion of "partially applied". There is also,
consequently, **no higher-kinded anything** — a library is not a type, it
cannot be passed, and `%ctx.f` cannot be applied to arguments. Tramaj is
about constructing values; this is the ceiling and it is a deliberate one.

### 2.1 The two channels share one record

Syntactically there is one params record; semantically there are two channels,
split statically by the `%`. An entry written `%T` is a type argument, and
`typeParams` (§9) — the `%ctx.*` paths a library's declarations mention — says
which keys those are. It is an error for the same key to be read as both, so
the two namespaces do not overlap in practice even though they share a
record.

The alternative, a second record on `import`, was rejected: it would duplicate
partial application, deferral and the unsupplied analysis at the type level,
and change the arity of the one form every program uses.

---

## 3. Identity is a canonical string

Two types are the same type iff their **canonical ids** are equal — that is,
type equality is string equality, and no unifier, subsumption order or
occurs-check exists anywhere in the language.

The normal form resolves every `Ref` to its `(library, name)` and every
argument recursively, sorts record fields, union arms and argument maps by
name, and **stops at declaration boundaries** — a `Ref` is rendered as its
name and arguments, never as its expansion. That last clause is what makes
`type Tree = | Leaf | Node { l : Tree, r : Tree }` terminate: recursion is
compared nominally, structure only within a body.

```text
id     ::= prim | "[" id "]" | record | union | ref | var
ref    ::= library ":" name  [ "[" name "=" id ("," name "=" id)* "]" ]
record ::= "{" name ":" id ("," name ":" id)* "}"
union  ::= "|" name [ " " id ] ("|" name [ " " id ])*
var    ::= "%" path
```

```text
number
[string]
{x:number,y:number}
message:Envelope[payload=json:Value]
list:T[elem=message:Envelope[payload=json:Value]]
message:Envelope[payload=%ctx.p]        -- partial
```

`list:T[elem=number]` written in two libraries a thousand lines apart is one
string, hence one type. That is the whole of the equality story, and it is why
type arguments need no allocation the way symbols do: a symbol's two
instantiations are genuinely two variables, whereas `List[Int]` and
`List[Int]` are genuinely one type.

Canonicalisation must be **injective**, for the reason v3 §1.4 gives about
allocation keys: distinct types must not collide in one string. Sorting is
therefore total and the grammar above is unambiguous.

---

## 4. Partial types

A type is **partial** if its normal form contains a `Var`. Partial types are
entirely legal while they are being built — that is what a parameterised
library exports — and are an **error in the root program**:

```text
PartialType  the root's type <id> still contains the variable <path>
```

This is the exact type-level analogue of ref §7's rule that an import may be
partial but must be saturated before it runs, and it is reported the same
way — statically, by analysis, before anything is evaluated. It is what makes
`%` safe: unlike `?`, a `%` cannot leak into the output, because a program
with one left over does not run.

The consequence worth stating: no partial order over types is needed. Two
partial types are compared by the same string equality as any others, holes
included; nothing ever asks whether one type is *more* applied than another,
because nothing may ship a partial type to a host that would care.

---

## 5. Constraints on types

A template may constrain a type it does not define:

```
type Envelope = { to : string, payload : %ctx.payload }

!type-constraint("has-default", %ctx.payload)
!type-constraint("serializable", %ctx.payload, "json")
```

`!type-constraint` is the type realm's sibling of v3's `!constraint`, and it
means exactly what that means: *this fact is asserted; someone downstream
discharges it.* Tramaj checks nothing — it does not know what `has-default`
is, any more than it knows what an action key means. It takes a static name
and a list of arguments, each of which is a type expression (`%`-marked, §2)
or a literal scalar.

**It is variadic and its arity is unbounded**, for the reason v3 §2.1 gives:
the language fixes no signature because it knows no names, so arity belongs to
the host's vocabulary alongside the name. A zero-argument
`!type-constraint("closed-world")` is legal, and so is an n-ary relation over
many types at once — the type-level counterpart of a global constraint:

```
!type-constraint("disjoint", %ctx.a, %ctx.b, %ctx.c)
!type-constraint("coercible-to", %ctx.payload, %Json, "lossy")
```

Argument order is significant and preserved, and is part of the canonical
rendering the deduplication below compares on.

```text
statement = "@" name "=" expr           -- ref
          | "!" expr                    -- v3 §2.2, a value constraint
          | "!" "type-constraint" "(" ... ")"   -- v4, a type constraint
```

Instantiation follows substitution. When `message` is imported with
`{payload: %Json}`, the collected constraint is
`has-default(json:Value)` — the variable is gone, and the host is asked a
question about a concrete type. Constraints are deduplicated by their
canonical rendering, as v3 §4 deduplicates value constraints and for the same
reason.

### 5.1 One leader, two phases, told apart by the form name

`!` means *emit a fact*, and that is true of both forms. What differs is the
realm, and the realm is legible in the form name rather than in the leader —
which is the same trick `ctx(path)` plays in ref §7, where a static form sits
in the middle of an ordinary expression and is enumerable precisely because
the form name is a fixed word.

The consequences are worth stating, because they are not the ones a reader
would assume from the leader alone:

* **A `!type-constraint` is resolved, not evaluated.** Its arguments are type
  expressions in the static grammar. The analyser collects it by walking the
  AST; the evaluator never sees one, exactly as it never sees the type in an
  annotation (§7).
* **It is a statement, not a declaration.** It lives in the statement chain
  with the bindings and the value constraints, so the declaration block of §1
  stays purely declarative. It may be written anywhere a statement may.
* **Its position affects nothing but source order.** Since it is erased before
  evaluation, it cannot observe or affect a binding, and moving it up or down
  the statement list changes only where it lands in `"type-constraints"`
  before deduplication.
* In the core AST it is `TypeEmit name: String, arguments: List<TypeExpr |
  Scalar>`, a sibling of v3's `Emit` that the evaluator's statement fold skips.

The one thing this costs is that `!` no longer implies "evaluated". That was
never load-bearing — `!` implies "this contributes to the output envelope",
which remains exactly true — and the form name is a static position, so a
reader and an analyser can both tell which realm a statement is in by looking
at one word.

---

## 6. Supplying versus asserting

How does a user force a type variable to be *replaced* rather than
symbolically equated? The two operations are already different things, and
only one of them is Tramaj's:

| | written | what Tramaj does | when |
|---|---|---|---|
| **supply** | `import("m", {payload: %Json})` | substitutes; the variable is gone | analysis |
| **forward** | `import("m", {payload: %ctx.payload})` | substitutes one variable for another; still a hole | analysis |
| **assert** | `!type-constraint("eq", %ctx.payload, %Json)` | collects the fact; the hole remains a hole | never |

Substitution is structural and Tramaj performs it. Assertion is a fact and
Tramaj only carries it. Tramaj will **never** solve an assertion into a
substitution — that would be a unifier, and a unifier is the beginning of the
checker both documents refuse to build. If you want the type replaced, supply
it; the `PartialType` error of §4 is what guarantees you cannot forget to.

The parallel to `ctx(path)` is exact: forwarding is deferral, supplying is the
literal. The syntax already distinguishes them, because `%ctx.p` and `%T` are
different expressions.

---

## 7. Annotations, and how types reach the value realm

```
@d : Deployment          = ?("d")
@n : string              = $ctx.name
@m : $msg.types.Envelope = ?("m")
```

`@x : T = e` is **sugar** for the binding plus a v3 emission:

```text
@x = e
!constraint("has-type", $x, {"$type": "<canonical id of T>"})
```

The type is **erased at analysis time** into the opaque tag v3 §5.3 already
reserved. By the time the evaluator runs there is no type left in the
program — only an inert object with a `"$type"` key, which is data like any
other. So:

* `Value` gains no constructor. `str`, `map`, `eq` and the whole `NotConcrete`
  table of v3 §1.5 are untouched.
* A type reference is still not a value, and cannot be computed, branched on,
  or built at runtime.
* The host looks the id up in the `"types"` table (§8) and has the definition
  in hand without parsing Tramaj source.

An annotation whose type is partial is the `PartialType` error of §4 — which
is why erasure is safe: nothing ambiguous can be erased.

A `has-type` on a symbol is the useful case: it tells the host the domain of a
hole it is about to fill, which for an enum union is a finite one. A
`has-type` on a concrete value is a claim a checker can verify against the
output. Tramaj distinguishes neither; both are emitted the same way.

---

## 8. Output

The v3 §5.2 envelope gains two lists, and the value domain gains the second
tagged shape v3 reserved.

```json
{
  "format": "tramaj/symbolic/1",
  "kind": "document",
  "root": { "...": "..." },
  "symbols": [
    {"id": "#0:\"m\"", "origin": {"kind": "alloc", "site": 0, "key": "m"}, "binding": "m"}
  ],
  "constraints": [
    {"name": "has-type",
     "arguments": [{"$sym": "#0:\"m\"", "path": []},
                   {"$type": "message:Envelope[payload=json:Value]"}]}
  ],
  "types": [
    {"id": "message:Envelope[payload=json:Value]",
     "definition": {"kind": "record",
                    "fields": [{"name": "payload", "type": {"kind": "ref", "id": "json:Value"}},
                               {"name": "to", "type": {"kind": "prim", "name": "string"}}]}},
    {"id": "json:Value", "definition": {"...": "..."}}
  ],
  "type-constraints": [
    {"name": "has-default", "arguments": [{"$type": "json:Value"}]}
  ]
}
```

* `"types"` is the **transitive closure** of every type the program
  references: a record's field types, a union's payloads, and theirs. The
  closure is what a host actually needs to interpret a `has-type`; the direct
  set is merely cheaper to compute. Cycles are cut by the ids, since a `Ref`
  is never expanded (§3).
* **A constraint goes in the list of its subject's realm.** `has-type` relates
  a *value* to a type, so it is a v3 constraint carrying an erased `$type`
  argument; `has-default` relates a type to nothing else, so it is a type
  constraint. That is the rule, not an accident of which syntax produced it.
* Both lists are `[]` for a program with no types, so a v3 consumer reading a
  v4 envelope sees nothing new, and the format version does not change.
* Concrete mode (v3 §5.1) emits plain JSON as before. Types are erased, so a
  concrete-mode run of a typed program is byte-identical to the same program
  with the annotations deleted — which is the honest meaning of erasure.

---

## 9. Static analysis

| function | answers |
|---|---|
| `typeDeclarations` | which types a program declares |
| `typeReferences` / `deepTypeReferences` | which it refers to, normalised |
| `typeParams` | which `%ctx.*` variables its declarations read — its type-level parameter list |
| `unsuppliedTypeParams` | per import, the type params its library needs that the import does not supply |
| `typeConstraints` / `deepTypeConstraints` | which type-level facts it asserts |

`typeParams` is to types what `contextReads` is to values, and
`unsuppliedTypeParams` is the type half of ref §9's `unsuppliedParams` — the
same subtraction, over the keys the `%` marks.

Resolution follows imports through the library table with the same cycle
cutting ref §9's deep analyses use, and **no library is evaluated**: the table
holds parsed programs, so all of this is an AST walk. Unresolvable references
are reported rather than passed through, on the same footing as an import name
the table does not resolve.

`$lib.types.X` is not a runtime field read. It is resolved statically, which
means `lib` must be bound *directly* to an `import(...)` in the enclosing
binding chain; an import reached through a lambda, an array, or a later
saturating call cannot be resolved, and that is an analysis error.

---

## 10. Errors

| error | when |
|---|---|
| `UnresolvedType` | a name resolves to no declaration and no primitive |
| `PartialType` | the root ships a type still containing a `%` variable (§4) |
| `TypeParamCollision` | a params key is read both as `$ctx.k` and as `%ctx.k` |
| `NotStaticallyResolvable` | `$lib.types.X` where `lib` is not bound directly to an import |
| `TypeCycle` | a declaration's *arguments* cycle (a recursive body does not) |

All five are analysis errors. No new evaluation error exists, because by
evaluation time there are no types.

---

## 11. Open

1. **`alias X = T`**, transparent rather than nominal. Nominal is the right
   default and gives newtyping for free (§1.1); transparency is occasionally
   what you want for a host schema that is structural. Cheap to add, easy to
   regret, so: not until something needs it.
2. **Application sugar.** `list:T[elem=number]` is spelled today as an import
   plus a field read, which is verbose for what a Haskeller writes `List Int`.
   A sugar `%list.T[elem: number]` desugaring to a fresh wiring would be safe
   — identity is structural, so a sugared and a spelled-out application are
   the same type — but it is sugar, and should follow a real complaint.
3. **The `Program` change.** Adding a declaration block breaks
   `DocumentProgram Expr | ExpressionProgram Expr` and every host that
   pattern-matches it. This remains the only breaking AST change across v3 and
   v4, and it is worth confirming exported types are wanted before paying it.
4. **Type-directed projection.** With declarations in hand, `$d.replicas`
   could carry a resolved field type into the constraint that mentions it. v3
   deliberately computes nothing for a projection (v3 §1.6), and moving that
   into the language is the first step toward the typechecker both documents
   refuse to build.
5. **Unifying the realms.** A *symbolic* type — a `?`-style hole in the type
   realm, constrained rather than supplied, that a host resolves alongside the
   symbols — would collapse §0's table into one mechanism. It also collapses
   the erasure of §7, since a type that survives to the host cannot be erased
   before evaluation, and it reopens the question of which realm is resolved
   first. Research, not v4.
6. **Row polymorphism**, for "a record with at least these fields". This is
   what `!type-constraint` is likely to be abused into expressing, and if that
   abuse becomes common the honest fix is a former, not a constraint name.
