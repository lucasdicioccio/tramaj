# Final touches

Decisions **postponed or left unanswered** in shipping v3 (symbols and
constraints, frozen) and v4 (types, still a draft). Nothing here blocks
either release — v3-symbols.md and v4-types.md are both implemented,
byte-identically, in both hosts — this is the punch list for whoever
revisits either spec next, sourced from `specs/v3-symbols.md` §9,
`specs/v4-types.md` §11, and `roadmap-to-v4`.

Each item: what was considered, why it was set aside, and what would justify
picking it back up.

---

## v3-symbols — considered and declined (§9)

### 1. A key on the demand form: `?ctx.threshold($s.name)`
Lets a template drive a *keyed* context-demand in one form, instead of
choosing between `?(key)` (template-driven) and seeding (§5.4,
host-driven). Declined because the two existing forms already cover their
respective cases; a merged form is only worth it if something needs a
context-rooted demand *and* a computed key at the same call site, and
nothing has yet.

### 2. A `label` field on the symbol table entry
Would let the envelope carry a human-readable name for a symbol
(`"Replicas"`) alongside its id. Declined because
`!constraint("label", $x, "Replicas")` already expresses it — in the
host's vocabulary, not the language's, which is the same reasoning the
whole constraint-name design rests on. Revisit only if a host finds itself
reinventing this constraint identically often enough that it's worth
promoting.

### 3. Symbolic strings
Letting `?(...)` stand in for a *string*, with template-level operations
(concatenation, interpolation) staying symbolic instead of erroring
`NotConcrete`. Declined — §1.8's cost is real: the value domain would gain
terms, not just variables, which is a bigger step than a value symbol
currently is. Revisit only alongside a genuine use case that can't be
worked around by allocating the whole string as one opaque symbol.

---

## v4-types — open (§11)

### 4. `alias X = T`, transparent rather than nominal
Every `type X = ...` today is nominal (§1.1) — newtyping is the default,
not a separate feature. A transparent alias would let a host schema that's
genuinely structural skip the newtype boilerplate. Cheap to add, but
"cheap to add, easy to regret" — a second declaration form is a permanent
surface-area cost. Not until something needs it.

### 5. Application sugar: `%list.T[elem: number]`
Today `list:T[elem=number]` is spelled as an import plus a field read
(`import("list", {}).types.T`, with `elem` supplied through the params
record) — correct but verbose next to `List Int`. A sugar would be safe
to add later without breaking anything, since identity is structural: a
sugared and a spelled-out application normalise to the same canonical id.
Should follow a real complaint, not get built speculatively.

### 6. The `Program` breaking change
This is the one still-live fork in the road. v4 shipped as it did —
`type X = ...` declarations and `@x : T = e` annotations both folded into
the existing `Let`/`Emit` statement chain (decision #14) — specifically
*so that* `Program = DocumentProgram Expr | ExpressionProgram Expr` never
had to change, and every host that pattern-matches `Program` kept
compiling. A dedicated declaration block (closer to how most typed
languages actually look) would need a third `Program` constructor or an
added field — the only breaking AST change either spec has on the table.
Worth confirming exported types are actually wanted, by a real host, before
paying that cost.

### 7. Type-directed projection
With declarations resolvable, `$d.replicas` could carry `Deployment`'s
`replicas : number` field type into whatever constraint mentions the
projection, instead of computing nothing for it (v3 §1.6 is deliberate
about this). This is explicitly flagged as the first step toward the
typechecker both v3-symbols.md and v4-types.md refuse to build — so it's
not a small add, it's a stated boundary. Only cross it on purpose.

### 8. Unifying the two realms (`?` and `%`)
A *symbolic* type — a hole in the type realm that's constrained rather
than supplied, resolved by a host alongside ordinary value symbols —
would collapse §0's values/types table into one mechanism. Explicitly
research, not v4: it also breaks erasure (§7), since a type that survives
to the host can no longer be erased before evaluation, and it reopens
which realm resolves first. The most structurally invasive item on this
list.

### 9. Row polymorphism ("a record with at least these fields")
No mechanism for it today. Flagged as the shape `!type-constraint` is
likely to get abused into faking (a `has-fields` constraint name that
means the same thing informally). If that abuse becomes common in
practice, the honest fix is a real language former, not a constraint
name doing a smuggled job. Wait for the abuse before building the fix.

---

## Adjacent — open before v3/v4, still open (reference.md §14)

Not v3/v4-specific, but load-bearing context for anyone reading those specs
looking for gaps: three items were open in the language before symbols or
types existed and remain untouched by either extension.

- **Destructuring** (§8) — no binding-pattern sugar; every field read is an
  explicit path.
- **Calling a call's result directly** (§7) — `f(x)(y)` is a parse error;
  a call's result must be bound before it's called again.
- **Negative and exponent number literals** — `-1` and `1e5` don't parse.
  With no arithmetic in the language, such a value can currently only
  arrive through `$ctx` or a library, never be written inline.

---

## Not open — resolved, listed here only to head off re-litigating

- **Version bump.** v4 ships as a **minor** bump (decisions.md #14,
  reference.md §14) — see item 6 above for why, and what would flip it.
- **Canonical type id grammar** (quoted library key, bare `root`) and
  **`Ref` argument holes** — decisions.md #15 and #16, both settled during
  implementation, not left open.
