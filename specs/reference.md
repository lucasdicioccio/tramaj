# Tramaj — Language Reference

This is the reference for the language **as implemented**. Where the earlier
drafts disagree with each other or with this document, this document wins;
`decisions.md` records which reading of those drafts was taken and why, and
the drafts themselves are in [`archive/`](archive). `node-json.md` is
normative for the output wire format and is not repeated in full here.

Two implementations are held to this document: `tramaj/` (PureScript) and
`tramaj-hs/` (Haskell). Anything below marked *implementation-defined* is
where they are permitted to differ; everything else they must not.

**One part is not in every implementation yet.** The split of numbers into
integers and floats, and the arithmetic builtins, are accepted design
(decisions §18) and are normative here. `tramaj/` (PureScript, with the
guaranteed integer range) and `tramaj-hs/` (Haskell, with the 64-bit range)
implement both, the nine arithmetic names without `round`.
`tramaj-py/` (Python, with the 64-bit range) implements both as well.
The Rust, JavaScript and Go ports do not yet: there every number is a double,
`str(1.0)` is `1`, and the nine names of §11's *Arithmetic* are unbound. Each
passage this applies to is marked **[§18]**.

**A second part is specified ahead in the same way.** Sorting (`sort-by`,
`sort-by-descending`), `format-number` and `round` are accepted design
(decisions §20) and are normative here, but no implementation has them yet:
the two sort names parse as ordinary calls, and all four names are unbound.
Each passage this applies to is marked **[§20]**.

---

## 1. Shape of the language

Tramaj is expression-oriented. There is one expression language, and
**documents are values**: an element or a fragment is an ordinary expression
result that can be bound, passed to a lambda, returned from one, or stored in
an array.

```
  surface syntax
        │  parse + desugar
        ▼
    core AST  ──────────────┐
        │  evaluate         │  analyse (no evaluation)
        ▼                   ▼
      Value           imports / action keys / context holes
        │
        └── Node ──► normative JSON ──► host fold (HTML, YAML, HCL, UI, …)
```

The core AST is deliberately smaller than the surface. Conveniences are
lowered into it (§8) rather than given constructors of their own.

---

## 2. Core AST

```text
Program
  = DocumentProgram Expr
  | ExpressionProgram Expr

Expr
  = Path         root: String, fields: List<String>
  | FieldAccess  target: Expr, fields: List<String>
  | Call         function: Expr, arguments: List<Expr>
  | Lambda       parameters: List<String>, body: Expr
  | Let          name: String, value: Expr, body: Expr
  | StringLit    String
  | NumberLit    Number               -- an integer or a float (§3, §5)
  | BoolLit      Boolean
  | NullLit
  | ArrayLit     elements: List<Expr>
  | ObjectLit    fields: List<(String, Expr)>
  | Element      tag: String, attributes: List<Attribute>,
                 value: Expr, children: List<Expr>
  | Fragment     children: List<Expr>
  | Branch       condition: Expr, then: Expr, else: Expr
  | Map          collection: Expr, function: Expr
  | Filter       collection: Expr, function: Expr
  | Scan         collection: Expr, initial: Expr, function: Expr
  | Fold         collection: Expr, initial: Expr, function: Expr
  | SortBy       descending: Boolean,          -- [§20] sort-by and
                 collection: Expr, function: Expr  -- sort-by-descending
  | Concat       left: Expr, right: Expr
  | Import       name: String, parameters: List<(String, ParamValue)>
  | AdaptActions target: Expr, adaptation: ActionAdaptation,
                 function: Optional<Expr>

ParamValue
  = PExpr        Expr                 -- any expression, evaluated at the import
  | PFromContext path: List<String>   -- read from the importing program's $ctx

Attribute
  = Attr         name: String, value: Expr
  | ActionAttr   event: String, key: String, payload: Expr

ActionAdaptation
  = Identity
  | Prefix       String
```

**Every static position is a `String`, not an `Expr`**: an import's name, an
action's event and key, an adaptation's prefix, a `ctx(...)` parameter's path.
That is what makes §9's analyses possible, and the grammar refuses anything
else in those positions — the restriction is enforced at parse time, not
checked later at evaluation time.

There is no partial-import constructor, and partiality is not visible in the
syntax at all: an import is unsaturated when the library reads a parameter
nobody has supplied yet, which is a fact about two programs, not about this
one (§7).

---

## 3. Values

```text
Value
  = Null | Boolean | Integer | Float | String
  | Array   List<Value>
  | Object  Map<String, Value>
  | Node                        -- a document
  | Closure                     -- a lambda, with its captured environment
  | Builtin                     -- a builtin, referenced but not yet called
  | ImportResult                -- {rendered, vals}, once the library has run
  | Import                      -- an import wired up but not yet run
```

Arrays and objects hold `Value`s, **not** JSON — so a document can travel
inside a structure. That is what makes the JSX-children pattern work without a
separate "template value" category.

JSON is required only at the boundaries where a document would be meaningless:
an attribute value, an action payload, an element's value slot, and an
expression program's result. A closure, a builtin, an import result, an
import that has not run, or a document reaching one of those positions is an
error, not a silent serialization.

**Numbers. [§18]** There are two number types, and nothing converts between
them unless the program says so (§11's `real` and `floor`).

- An **integer** is a signed whole number, held exactly. Every implementation
  MUST cover the *guaranteed range*, `-(2^53 - 1)` to `2^53 - 1`. It SHOULD
  cover the signed 64-bit range, `-2^63` to `2^63 - 1`, and MUST NOT go beyond
  it. Its range is one of those two (§13).
- A **float** is a finite IEEE 754 binary64. There is no NaN, no infinity and
  no negative zero.
- **A JSON number is read as the literal of the same text** (§5). One with
  neither a fraction nor an exponent is an integer, one with either is a
  float: `3` is an integer; `3.0` and `3e0` are floats. Whatever that literal
  denotes, the JSON number denotes: `-0.0` is `0.0`, `-0` is the integer `0`,
  and a float too small for a double rounds to zero. Whatever is a parse
  error as a literal is refused as a JSON number: an integer-form number
  outside the implementation's range, which is not rounded, and a float too
  large for a double (`1e400`). This holds for the context and for a seeded
  value (v3-symbols §5.4), at any depth.
- **A context with a refused number is a `TypeMismatch`** (§12), the kind a
  context carrying a reserved key already raises (v3-symbols §5.3). The
  context is decoded whole, before evaluation starts, so the error does not
  depend on whether the program reads the number.
- **A library parameter is not JSON text.** It is a value the importing
  program built (§7), and it crosses the import with the type it has:
  `import("lib", {n: 3.0})` passes a float and `{n: 3}` an integer. Nothing
  is typed again at the boundary, and `ctx(path)` passes what the context
  decoder made of the number.
- **Written as JSON, a number keeps its type**: `node-json.md` has the rule,
  and `str` (§6) follows it.

The type of a context number is therefore decided by whoever serialized it,
and a producer with one number type writes the float `3.0` as `3`. A template
that needs a float from a host it does not control normalizes at the point of
use, with `real`.

A host that passes native values rather than JSON text maps its own integer
and float types to these two. How it does so is that implementation's binding
and is not specified here.

---

## 4. Node (output)

```text
Node
  = Text      value: Value,  annotations: Annotations
  | Element   tag: String, attributes: List<NodeAttribute>,
              value: Value, children: List<Node>, annotations: Annotations
  | Fragment  children: List<Node>, annotations: Annotations

NodeAttribute
  = Attribute name: String, value: Value
  | Action    event: String, key: String, payload: Value

Annotations = Map<String, JSON>
```

- The text leaf carries a **`Value`**, so a scalar child keeps its type:
  `.td($ctx.count)` yields the integer `3`, not `"3"`. How that becomes
  characters is the host's decision.
- `Element` carries a **value slot** alongside its children, for targets that
  attach a body value to a tagged node. It is `null` unless set.
- `attributes` is an ordered list, so an element may carry **any number** of
  attributes and actions, and duplicate names are preserved, not merged.
- Annotations have no core meaning. They are the extension point for types,
  domains, provenance and host metadata, and every transformation must carry
  them through unchanged.

Serialization — including the strict decoding rules — is specified in
[`node-json.md`](node-json.md).

---

## 5. Surface syntax

Three leader characters: `.` builds a document, `$` reads a name, `@` defines
one.

```
@count=cardinality($ctx.items)          -- bindings, one per line
@panel=(title, kids) => .section(.h2($title), $kids)

.div(class: "panel",                    -- attribute position first
     action("on-click", "save", {"id": $ctx.id}),
     value($ctx.raw),
     .h1("Title"),                      -- then children
     .( .p("a"), .p("b") ),             -- a fragment: tagless element
     map($ctx.items, (i) => .li($i.name)),
     branch(.p("none"), gt($count, 0), .p("some")))
```

| Form | Meaning |
|---|---|
| `$name`, `$name.a.b` | read a binding, then static field access |
| `name(args)`, `$name(args)` | a call; the two spellings are identical |
| `$lib.vals.fn(1)` | the callee may be a dotted path |
| `f(x).rendered` | field access on a call's result |
| `"text"`, `` "n: `$x`" `` | string literal, backtick interpolation |
| `123`, `-1.5`, `1e5`, `1_000_000` | number literal, an integer or a float by its form; see *Number literals* below |
| `true`, `false`, `null` | keyword literals |
| `[a, b]` | array literal |
| `{"k": v}`, `{k: v}`, `{foo}` | object literal; keys may be bare; `{foo}` is shorthand for `{"foo": $foo}` |
| `(x, y) => expr` | lambda |
| `({a, b: c}, y) => expr` | lambda with an object pattern parameter; see *Binding patterns* in §8 |
| `@{a, b: c}=expr` | binding with an object pattern; see §8 |
| `(expr)` | grouping |
| `-- text` | a comment, to the end of the line |
| `a <> b` | concat — the only infix operator, left-associative, lowest precedence |
| `.tag(...)` | element |
| `.(...)` | fragment |
| `value(expr)` | element value slot; at most one, attribute position |
| `action("event", "key", payload)` | action; attribute position, any number |
| `map/filter(coll, fn)`, `scan/fold(coll, init, fn)` | array primitives |
| `sort-by(coll, fn)`, `sort-by-descending(coll, fn)` | **[§20]** a stable sort, by the key `fn` gives each element (§11) |
| `branch(fallback, p1, v1, …)` | conditional |
| `import("name", {k: expr, j: ctx(path)})` | import; a parameter may also be left out and supplied later |
| `adapt-actions(node, prefix("ns:") \| identity [, fn])` | action adaptation |

Names — bindings, path segments, tags, bare keys — start with a letter and
may contain letters, digits, `_` and internal `-`. *Internal* is enforced,
not merely advised: a hyphen belongs to the name only when another name
character follows it, so a name never ends in one and `$x-- note` reads as
`x` followed by a comment. Whitespace is insignificant except as a
separator, with one exception: a field-access `.` must directly follow the
`)` it applies to, so `f()` on one line and `.div(...)` on the next are two
separate things.

**Comments.** `--` begins a comment that runs to the end of the line. There
is no block form and no nesting, so a comment cannot be left unterminated
and a second `--` inside one is simply more comment. A comment is legal
wherever a space is — above the bindings, trailing one, between an element's
arguments, after the root — and is discarded together with the whitespace
around it, so it reaches neither the core AST nor §9's analyses. Inside a
string literal `--` is ordinary text: a string body is read character by
character and never passes through this rule.

Being whitespace, a comment does not join the lines it sits between:
`f() -- note` followed by `.div(...)` on the next line is two separate
things, exactly as the uncommented version is.

**Number literals.**

```
number = ["-"] digits ["." digits] [("e" | "E") ["+" | "-"] digits]
digits = digit { ["_"] digit }
```

- The `-` is part of the literal, not an operator (there are no arithmetic
  operators, §11), so it must touch the first digit: `- 1` is a parse error,
  and so is a leading `+`. `--1` is a comment, like any other `--`.
- A `_` separates digits for readability and means nothing: `1_000_000` is
  `1000000`. It is allowed only *between two digits* — `1_`, `1__0`, `1_.5`,
  `1._5` and `1e_5` are all parse errors — and may appear in the integer,
  fraction and exponent parts alike (`0.000_001`, `1e1_0`).
- Both parts around a `.` need at least one digit: `.5` and `5.` are not
  numbers.
- **[§18]** The form decides the type (§3), with no new syntax. A literal
  with neither a fraction nor an exponent is an **integer**: `1`, `-7`,
  `1_000_000`. One with either is a **float**: `1.0`, `-1.5`, `1e5`.
- An integer literal denotes exactly its value. One outside the
  implementation's integer range (§13) is a parse error. The sign is part of
  the literal, so `-9223372036854775808` is in the 64-bit range.
- A float literal denotes the double nearest to its decimal value (round to
  nearest, ties to even). One too large for a double (`1e400`) is a parse
  error rather than an infinity; one too small rounds to zero.
- There is no negative zero: a float literal that denotes zero is `0.0`
  whatever its sign, so `-0.0` and `-1e-400` both evaluate to `0.0`. `-0` is
  the integer `0`.

**Attribute position before children.** Attributes, `action(...)` and
`value(...)` must all precede any child; a child first is a parse error.

**Static positions reject interpolation.** A backtick inside an import name,
action event/key, adaptation prefix or object key is a parse error rather than
a literal backtick — someone writing ``import("lib-`$x`")`` means
interpolation, and that position cannot be computed.

**A malformed special form is a parse error.** Name recognition backtracks;
the shape does not. `action("on-click", $computed, {})` fails to parse rather
than quietly becoming a call to an unbound function named `action`.

**[§20]** `sort-by` and `sort-by-descending` are special-form names, as `map`
is. Each takes exactly two arguments, and any other count is a parse error.
Being recognized by the parser, neither can be shadowed by a binding, and
neither can be passed by reference.

### Program kind

A program is bindings followed by a root expression. `parseProgram` reports
`DocumentProgram` if the root is written as a document (`.tag(...)` or
`.(...)`) and `ExpressionProgram` otherwise. That is a syntactic classification;
what evaluation actually produces is decided at runtime (§6).

---

## 6. Evaluation

Evaluation is eager and deterministic, with exactly one exception (`Branch`).
Aside from binding order, no evaluation order is prescribed.

**Bindings.** `@name=expr` lines lower to nested `Let`s, so a binding may
reference `$ctx` and any earlier binding, never a later one. A binding's value
is inserted only *after* it is evaluated, which is why **there is no
recursion**: a lambda cannot call itself by its own binding name.

**Closures** capture the environment where the lambda is evaluated. Builtins
are ordinary values in the initial environment, so one can be passed by
reference: `map($ctx.flags, $not)`.

**Branch** evaluates its condition, then *only* the selected arm. Errors in an
unreached arm never surface. This holds in every position — there is no
separate eager form. The condition must be a boolean.

**Elements** evaluate attributes, then the value slot, then children, in
source order.

**Children coercion** is the one rule the document side adds:

| child value | contributes |
|---|---|
| a document | itself, as one child |
| an array | each element, recursively — this is how `map(...)` repeats children |
| anything else JSON-able | one text node carrying that value unconverted |
| a closure / builtin / import result / unrun import | an error |

So an array in child position is a *sibling sequence*, not one value. An array
wanted as data belongs in an attribute or the value slot.

**Concat** (`a <> b`) is a monoid over three types, with no coercion:

```
String × String → String      ""   identity
Array  × Array  → Array       []
Object × Object → Object      {}   right-biased on key collision
```

Mixed types are an error. Object key order is not semantically significant.

**`str`, and string interpolation.** `` "n: `$x`" `` lowers to `Concat` over
`str(...)`, so `str` decides what interpolation puts in the output. Its
rendering is normative:

| value | renders as |
|---|---|
| string | itself, raw |
| `null` | `""` |
| boolean | `true` / `false` |
| integer | its decimal digits, with a `-` when negative — `3`, `-7`, `100000000000` |
| float | the shortest round-trip text of ECMAScript's `Number::toString`, with `.0` appended when that text has neither a fraction nor an exponent — `1.0`, `1.5`, `0.05`, `100000000000.0`, `1e+21`, `1e-7` |
| array / object | compact JSON, **keys sorted**, numbers by the same two rules, strings JSON-quoted |

Keys are sorted because key order is not semantically significant, so it must
not be observable here either. Both implementations must produce these
character for character.

**[§18]** The two number rows are the serialization rule of `node-json.md`:
`str` renders what the value is, so `str(1)` is `1` and `str(1.0)` is `1.0`.
An implementation without the number split yet renders every number by
`Number::toString` alone, which differs for a whole-valued float and for
nothing else.

---

## 7. Imports

```
import("deployment", {
  name:     "web",              -- (a) an expression, evaluated here
  replicas: ctx(spec.replicas)  -- (b) this program's $ctx.spec.replicas
})                              -- (c) anything not listed: supplied later
```

Three ways to supply a parameter, and the third is not writing it down.

**(a)** Any expression. It is evaluated where the import is written, like
every other argument in the language.

**(b)** `ctx(path)` reads the *importing* program's own context, also where
the import is written. It means exactly what `$ctx.spec.replicas` means, and
a path the context lacks is the same `PathNotFound` — the two forms are
interchangeable at runtime and the evaluator makes no distinction between
them.

The distinction is entirely static. `ctx(path)` puts the path in a static
position in the AST, where §9's `contextHoles` can enumerate it directly;
the same read spelled `$ctx.spec.replicas` is an ordinary path buried in an
arbitrary expression, indistinguishable from every other read. Writing
`ctx(...)` is how an author says *this is a hole — count it*, and it costs
the ability to compute the value, which is the point.

**(c)** A parameter the import does not mention is supplied later, by calling
the import with an object of more parameters. Merging is right-biased, like
`<>` on objects, so a later call overrides an earlier value for the same
name.

```
@panel=import("panel", {})
@half=$panel({"name": "web"})
$half({"replicas": 2}).rendered
```

An import runs **when a field is read off it** — `.rendered` or `.vals` —
never where it is written. Everything before that is accumulation, which is
what lets one wired-up import serve a whole `map`, each iteration adding its
own parameter:

```
@row=import("row", {kind: ctx(row-kind)})
.ul(map($ctx.items, (item) => $row({"title": $item.title}).rendered))
```

A run import exposes `.rendered` (whatever its root evaluated to — a
document or an ordinary value) and `.vals` (its own top-level bindings).
Using the import itself where a value is expected is an error: it has not
run, so it has nothing to serialize.

A library is evaluated against its parameters as its own fresh `$ctx` — a
library's `$ctx` *is* its parameter object, which is why a library reads
`$ctx.title` for the parameter `title`, and why a `ctx(...)` hole inside a
library is a hole in what its importer must pass. Import names are resolved
by a host-supplied table; where a library came from is not the language's
business. Re-entering a library already being evaluated is reported as a
cycle, not run.

Nothing checks that the parameters are *enough* before running a library,
because nothing in the import knows what enough would be. A library that
reads a path nobody supplied fails with its own `PathNotFound`, wrapped in
an `InLibrary` naming the library that raised it:

```
import("panel", {"name": "web"}).rendered
  -- InLibrary "panel" (PathNotFound ["ctx", "replicas"])
```

The static counterpart is §9's `unsuppliedParams`, which answers the same
question without running anything.

**Known limitation:** an import or `adapt-actions` result cannot be called
directly — `import("x", {...})({...})` is a parse error. Bind it first, as the
examples above do. Only field access is available as a postfix on a call.

---

## 8. Desugaring

The parser lowers each of these; none has a core constructor.

| surface | core |
|---|---|
| `@a=1` `@b=$a` `root` | `Let "a" 1 (Let "b" $a root)` |
| `"n: ` + `` `$x` `` + `!"` | `Concat (Concat "n: " (str $x)) "!"` |
| `"a\nb"` | one `StringLit` with a real newline |
| `{foo, bar: 1}` | `ObjectLit [("foo", Path foo), ("bar", 1)]` |
| `branch(f, p1, v1, p2, v2)` | `Branch p1 v1 (Branch p2 v2 f)` |
| `a <> b <> c` | `Concat (Concat a b) c` |
| `.div()` | `Element "div" [] NullLit []` |
| `@{a, b: c}=$x.y` | `Let "a" $x.y.a (Let "c" $x.y.b …)` |
| `({a}, n) => e` | `Lambda ["#arg0", "n"] (Let "a" $#arg0.a e)` |

Escape sequences:

```
\n  \t  \r  \\  \"  \`  \0  \u{1F600}
```

`\u{...}` is braced, so an astral code point needs no surrogate pair.

**Binding patterns.** An `@` binding or a lambda parameter may be an object
pattern instead of a name (decisions §17):

```
pattern ::= name | "{" field { "," field } [","] "}"
field   ::= name | name ":" pattern
```

`{title, kind: k, meta: {owner}}` binds `title`, `k` (the field `kind`) and
`owner`, reading each field the way `$x.title` would: a missing field is
`PathNotFound`, a non-object is `TypeMismatch`, and extra fields are ignored.
A path source is read directly, so `@{a} = $ctx.item` is `@a=$ctx.item.a`; any
other source (a call, a literal) is evaluated once. A pattern parameter takes
one position, so arity is unchanged. Bindings are made left to right.

These are parse errors: a name bound twice in one pattern, a default
(`{a = 1}`), a rest element (`{...r}`), an array pattern (`@[a, b]`), an empty
pattern (`{}`) and an annotation on a pattern (`@{a} : T = e`). The parser
invents hidden names for the lowering (they start with `#`, which no surface
name can); they never appear as a symbol's `"binding"` or in a library's
`.vals`.

*Deferred:* array patterns, defaults and rest (see decisions §17 for why).

---

## 9. Static analysis

All of these answer from the AST alone — no context, no library evaluation,
no host code. The three the laws ask for each have a deep variant that
follows imports through a library table and cuts cycles.

| function | answers |
|---|---|
| `staticImportNames` / `transitiveImportNames` | which libraries this program depends on |
| `staticActionKeys` / `deepActionKeys` | which action keys it can emit |
| `contextHoles` / `deepContextHoles` | which context paths it declares as holes with `ctx(...)` |
| `contextReads` | every path it reads from its own context, `$ctx.a` and `ctx(a)` alike |
| `unsuppliedParams` | per import, the paths its library reads that the import does not supply |
| `arithmeticOps` / `deepArithmeticOps` | **[§18]** which of §11's ten arithmetic names it references free |

`contextReads` of a library is the shape of the parameter object it expects,
since a library's context is its parameters. `unsuppliedParams` is that set
minus what each import supplies — the parameters still to be saturated by a
later call (§7), computed without running anything. It attributes a read to a
parameter by the read's first segment, and stops at the library's own reads
rather than following that library's imports, whose parameters it supplies
itself.

`staticActionKeys` **applies** adaptation rather than ignoring it, using the
same function the evaluator does: `adapt-actions(x, prefix("user:"))` over
`{save, delete}` yields `{user:save, user:delete}`. That is the payoff of
restricting adaptation to identity-or-prefix.

These are over-approximations: keys under a `Branch` arm that a given context
will never select are still reported, and so is a parameter a library reads
only in such an arm. A name that is imported but missing from the table is
reported too — an unresolvable dependency is what a caller wants to hear
about — though it contributes no unsupplied parameters, since what it needs
is unknowable rather than nothing.

**[§20]** Every analysis traverses `SortBy` as it traverses `Map`: through
the collection and through the function. A read, an import, an action key or
an arithmetic name inside a key function is therefore reported. `round` is
one of the ten names `arithmeticOps` reports. `format-number` is not: it is
not part of the arithmetic profile.

`arithmeticOps` reports a name whether it is called or passed by reference
(`fold($xs, 0, $sum)`). It is scope-aware: a name shadowed by a binding, a
lambda parameter or a pattern name is not reported. A host without the
arithmetic profile (§11) refuses a program up front when `deepArithmeticOps`
is non-empty.

---

## 10. Actions and adaptation

```
action("on-click", "deploy", {"deployment": $ctx.name})
```

The event and key are literals; only the payload is computed. The language
assigns meaning to neither — the event *vocabulary* is the host's, and what is
fixed is the position, not the words allowed in it.

```
adapt-actions(node, prefix("deployment:"))
adapt-actions(node, identity)
adapt-actions(node, prefix("ns:"), fn)
```

Prefixes every action key in the subtree, reaching through imported programs
and supplied fragments. Adaptations compose the obvious way — `a:` then `b:`
gives `b:a:key` — with no "already adapted" state. Applied to an import that
has not run, the adaptation is queued and runs on its result.

The optional `fn` sees each *already-prefixed* action and may change only its
event type and payload; a `key` it returns is ignored. Letting it win would
put the action vocabulary back beyond static reach, which is the whole point
of the restriction.

---

## 11. Builtins

The vocabulary is fixed, not user-extensible.

| builtin | notes |
|---|---|
| `cardinality(x)`, `count(x)` | array or object size |
| `str(x)` | §6's rendering; what interpolation uses |
| `not(b)` | |
| `and(…)`, `or(…)` | variadic, including zero arguments (`and()` is `true`, `or()` is `false`) |
| `eq(a, b)` | deep equality; no cross-type coercion, so `eq(1, "1")` is `false`, and **[§18]** so is `eq(1, 1.0)` |
| `lt`, `lte`, `gt`, `gte` | numbers only; **[§18]** two integers or two floats, and a mixed pair is a `TypeMismatch`, so `gt(1.5, 0)` is written `gt(1.5, 0.0)` |
| `has(container, key)` | tolerant: a missing key, out-of-range index or wrong-shaped container answers `false` |
| `lookup(container, key, fallback)` | dynamic access; the fallback is mandatory, so this never errors |
| `map`, `filter`, `scan`, `fold` | also core constructors — see below |
| `sort-by(list, fn)`, `sort-by-descending(list, fn)` | **[§20]** core constructors too: a stable sort by key — see *Sorting* |
| `format-number(x, decimals, group)` | **[§20]** a number as positional decimal text — see *Number formatting* |
| `concat(…)` | variadic array join; every argument must be an array |
| `append(arr, item)` | adds one element; an array item is added whole, not spliced |

`scan` is `scanl`, not `scanl1`: its output starts with the seed and is one
longer than the input. `fold` takes the same `(acc, item)` step and returns
only the final accumulator.

**There are no arithmetic operators.** No `+`, `-`, `*` or `/`: `-` stays part
of a number literal, `--` a comment, and `<>` the only infix operator (§5).
Arithmetic is ten named builtins, below, in an optional profile. An
implementation without that profile has no numeric builtins beyond the
comparisons and `format-number`.

`map`/`filter`/`scan`/`fold` and the two sorts are core constructors rather
than builtins because their function argument needs a fresh binding per
element. `branch` is
a core constructor because it must leave an arm unevaluated, which no builtin
can do.

### Sorting

**[§20] Specified, not yet implemented.**

```
sort-by($rows, (r) => $r.spend)                 -- by a field
sort-by($rows, (r) => cardinality($r.members))  -- by a computed value
sort-by-descending($names, (n) => $n)           -- a list of scalars
sort-by($rows, $spend-of)                       -- a function by reference
```

`sort-by(list, fn)` applies `fn` to each element of `list` to get its **key**,
and returns the elements ordered by ascending key. `sort-by-descending`
orders them by descending key. Both lower to the one constructor `SortBy`
(§2). They belong to the core language: no profile is needed for them.

**The order.** Element `i` precedes element `j` when its key is smaller
(larger, for `sort-by-descending`), or when the two keys are equal and
`i < j`. Two keys are equal when they are the same number or the same
sequence of code points. That is a total order on positions, so there is
exactly one result, and an implementation may use any algorithm that produces
it.

Both sorts are therefore **stable**, each on its own terms.
`sort-by-descending` is not the reversal of `sort-by`, which would reverse
the ties as well. For elements `a`, `b`, `c` whose keys are `2`, `1`, `2`,
`sort-by` gives `b`, `a`, `c` and `sort-by-descending` gives `a`, `c`, `b`.

A sort on several columns is one sort per column, the least significant key
first:

```
@by-name = sort-by($rows, (r) => $r.name)
@ranked  = sort-by-descending($by-name, (r) => $r.spend)
-- highest spend first, equal spends in name order
```

**What a key may be.** The keys of one call are all integers, or all floats,
or all strings. Anything else is refused.

| keys | result |
|---|---|
| all integers | numeric order |
| all floats | numeric order; there is no NaN and no negative zero (§3), so the order is total |
| all strings | lexicographic by Unicode code point; a proper prefix sorts first |
| an integer and a float in one call | `TypeMismatch` |
| a number and a string in one call | `TypeMismatch` |
| `null`, a boolean, an array, an object, a document, a closure, a builtin, an import | `TypeMismatch` |
| a symbol or a term | `NotConcrete` (v3-symbols §1.5) |

- *Integers against floats* are not compared, here as in `lt`. Keys of
  unknown number type are normalized by the key function:
  `(r) => real($r.spend)`.
- *Strings* are compared by code point. That is the byte order of their UTF-8
  encoding, and it is **not** the order of UTF-16 code units: U+FF5E sorts
  before U+1F600. An implementation whose strings are UTF-16 MUST compare by
  code point. There is no case folding, no normalization, no numeric
  awareness and no collation:
  `["", "10", "9", "Zebra", "apple", "banana", "eclair", "éclair"]` is in
  order.
- *`null` and a missing value* have no place in the order. A `null` key is a
  `TypeMismatch`, and a missing field is whatever the key function makes of
  it: `$r.spend` fails with `PathNotFound`, and `lookup($r, "spend", 0)`
  supplies a default.
- *Booleans* are not ordered. `branch(1, $r.active, 0)` states the order the
  author wants.
- `lt` and its siblings are unchanged: they stay numbers-only.

**Checks, in this order**, all before anything is reordered:

1. An argument count other than two is a parse error (§5).
2. `list`: a symbol or a term is `NotConcrete`, as for `map`; any other
   non-array is a `TypeMismatch`.
3. `fn`: a value that is not callable is a `TypeMismatch`, when `map` would
   raise it.
4. For each element, in index order: `fn` is applied, and an error it raises
   is the error; then the key is checked. A symbol or a term is
   `NotConcrete`; a value of a kind that is never a key, or of a different
   type from the first key, is a `TypeMismatch`. The first element that fails
   decides.

`fn` is applied exactly once per element, in index order. Apart from that the
elements are never inspected, so a list of documents, of closures or of
objects holding a symbol sorts like any other. Every key is checked, even
when the list has one element: `sort-by([$a], (x) => null)` is a
`TypeMismatch` although nothing would move. An empty list gives `[]`, and
`fn` is not applied.

### Number formatting

**[§20] Specified, not yet implemented.**

`format-number(x, decimals, group)` writes a number in positional decimal
notation, with exactly `decimals` digits after the point, and `group` between
each group of three digits of the integer part. It is an ordinary builtin of
the core language. It needs no profile, it can be shadowed and passed by
reference, and it does not depend on the arithmetic builtins.

```
format-number(1234567.891, 2, ",")   -- "1,234,567.89"
format-number(1234567.891, 2, " ")   -- "1 234 567.89"
format-number(1234.5, 2, "")         -- "1234.50"
format-number(1234.5, 0, ",")        -- "1,235"
format-number(1234, 2, ",")          -- "1,234.00"
format-number(-1234567, 0, ",")      -- "-1,234,567"
format-number(999.995, 2, "")        -- "1000.00"
```

**The rounding rule.** Let `v` be the exact mathematical value of `x`. A float
is a binary fraction, so `v` has a finite decimal expansion: `0.1` is exactly
`0.1000000000000000055511151231257827021181583404541015625`. The result
denotes the multiple of `10^-decimals` nearest to `v`; when two are equally
near, the one farther from zero. Implementations MUST agree byte for byte.
No native formatter follows this rule in every case, so each implementation
writes it out.

- A tie exists only when `v` is exactly halfway, which happens for values a
  double holds exactly. Those round away from zero:
  `format-number(2.5, 0, "")` is `3`, `format-number(-2.5, 0, "")` is `-3`
  and `format-number(0.125, 2, "")` is `0.13`.
- The builtin rounds the number the program has, not the text it was written
  as. `format-number(1.005, 2, "")` is `1.00` and
  `format-number(2.675, 2, "")` is `2.67`, because the doubles nearest to
  those literals are `1.00499999999999989…` and `2.67499999999999982…`.

**The remaining rules.**

1. *Arguments.* `x` is an integer or a float. An integer is formatted from
   its exact value, so nothing is converted. `decimals` is an integer from
   `0` to `20`. `group` is a string. An argument count other than three is a
   `TypeMismatch`. The arguments are then examined left to right, and the
   first that is not acceptable decides the error: a symbol or a term is
   `NotConcrete`, anything else of the wrong type is a `TypeMismatch`. So is
   a float `decimals` (`2.0`), and so is one outside `0` to `20`.
2. *Shape of the text.* An optional `-`, the integer part, and, when
   `decimals` is not zero, a `.` and exactly `decimals` digits. The integer
   part has at least one digit and no leading zero beyond it (`0.50`, never
   `.50`). With zero decimals there is no point: `1235`, never `1235.`.
3. *Never an exponent.* Every float formats, however large:
   `format-number(1e21, 0, ",")` is `1,000,000,000,000,000,000,000`. The
   digits are those of the exact value, so `format-number(1e23, 0, "")` is
   `99999999999999991611392`.
4. *No negative zero.* A result whose digits are all zero carries no sign:
   `format-number(-0.001, 2, "")` is `0.00`. `format-number(-0.005, 2, "")`
   is `-0.01`, since `-0.005` is the double `-0.005000000000000000104…`.
5. *Grouping.* When `group` is not empty, it is inserted between groups of
   three digits of the integer part, counted from the point leftward. The
   fraction is never grouped, and the sign precedes the first group. `""`
   means no grouping. The string is inserted as it is, whatever it is;
   nothing validates it.
6. *The decimal mark is always `.`*, and there is no locale.

There is no prefix, suffix or percent option. `<>` and interpolation do the
first two, and the builtin does not multiply:

```
"$" <> format-number($x, 2, ",")
format-number(product(100.0, $ratio), 1, "") <> "%"
```

### Arithmetic

**[§18]** Implemented in `tramaj/` (PureScript) and `tramaj-hs/` (Haskell),
with the nine names other than `round`; not yet in the Rust, JavaScript
and Go ports.
`tramaj-py/` (Python) has the same nine names.
**[§20]** `round` is the tenth name, added to the
profile after the other nine, and no implementation has it yet.

**The arithmetic profile** is optional, and independent of v3-symbols §5.5's
core and symbolic profiles. The two number types of §3 are not part of it:
they belong to the value domain in every profile.

- An implementation with the profile puts the ten names below in the initial
  environment. One without it does not, and a program that uses one fails with
  `UnboundName`. Nothing is refused at parse time: these are names, not
  syntax.
- They are ordinary bindings (§6). A program that binds `sum`, `floor` or any
  other of them (a binding, a lambda parameter, a pattern name) shadows the
  builtin, and one may be passed by reference: `fold($xs, 0, $sum)`.
- `deepArithmeticOps` (§9) is how a host without the profile refuses a
  program before running it.

| builtin | arity | operands | result |
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
| `round(x)` | 1 | float or integer | **[§20]** the integer nearest to `x`, ties away from zero, as an integer |

```
@subtotal = sum($ctx.compute, $ctx.storage, negate($ctx.credit))
@share    = branch(0, gt($ctx.total, 0),
                   floor-quotient(product(100, $ctx.used), $ctx.total))
@stripe   = branch("odd", eq(modulo($i, 2), 0), "even")
@total    = sum(0.0, map($ctx.lines,
                         (l) => product(real($l.qty), real($l.price))))
```

- **`real` and `floor` are the conversions**, one in each direction. Each
  accepts both types, so that it can normalize a number of unknown type:
  `real` of a float and `floor` of an integer are the identity.
- **[§20] `round` is `floor`'s sibling.** It gives the integer nearest to the
  exact value of `x`, and when two are equally near, the one farther from
  zero: `round(2.5)` is `3`, `round(-2.5)` is `-3` and `round(-0.4)` is `0`.
  It accepts both types and is the identity on an integer.
  `floor(sum(x, 0.5))` only approximates it: for `0.49999999999999994` that
  sum is exactly `1.0`, where `round` gives `0`. The tie rule is the one
  `format-number` uses, so for a float `x` whose rounding is in range,
  `str(round(x))` and `format-number(x, 0, "")` are the same text.
- **There is no subtraction**: `sum(a, negate(b))`. Negation is exact, so for
  floats this is bit for bit `a - b`.
- **`quotient` is float division and `floor-quotient` integer division.**
  Neither accepts the other's type, so a result never depends on whether a
  producer wrote `1` or `1.0`. `floor-quotient` rounds toward negative
  infinity: `floor-quotient(-7, 2)` is `-4`.
- **`modulo` is its remainder**: `a` is always
  `b * floor-quotient(a, b) + modulo(a, b)`, and the result is zero or has the
  sign of the divisor. `modulo(-7, 2)` is `1` and `modulo(7, -2)` is `-1`. The
  table's formula is over the mathematical integers; the result is smaller in
  magnitude than `b`, so it is always in range.
- **`inverse` is `quotient(1.0, x)`**, and `product(a, inverse(b))` is not
  `quotient(a, b)`: it rounds twice. `product(49.0, inverse(49.0))` is
  `0.9999999999999999`, where `quotient(49.0, 49.0)` is `1.0`.
- `min`, `max`, `ceiling` and `truncate` are not provided. Neither is
  rounding to a number of decimals as a float: a rounded decimal is text, and
  `format-number` is the builtin that produces it.

**Arrays as arguments.** `sum` and `product` flatten their arguments by the
rule children use (§6): an array contributes each of its elements,
recursively, in order. `sum($xs)`, `sum(1, $xs, 2)` and `sum([1, [2, 3]])` are
all legal. The eight fixed-arity builtins do not flatten: `negate([1])` is a
`TypeMismatch`, whatever the array holds, and `map($xs, $negate)` is the way
to write it. `and`, `or` and `concat` are unchanged.

A `sum` or `product` with no operand after flattening has no type to take, so
it is a `TypeMismatch`: `sum()`, `sum([])` and `product([[]])` alike. A fold
over a list that may be empty is seeded with the identity of the intended
type: `sum(0, $xs)` or `sum(0.0, $xs)`.

**Semantics.** Implementations MUST agree byte for byte.

1. *No coercion and no promotion.* A `TypeMismatch` is raised by an operand
   that is not a number (`sum(1, "2")`, `sum(null)`, `negate(true)`), by a
   number of the wrong type (`sum(1, 1.5)`, `quotient(1, 2)`,
   `floor-quotient(1.0, 2.0)`, `inverse(2)`), by a wrong argument count for a
   fixed-arity builtin, and by an empty `sum` or `product`. All operands are
   checked, in flattened order, before anything is computed, so
   `sum(1e308, 1e308, "a")` is a `TypeMismatch` and not a `NotRepresentable`.
2. *Integer arithmetic is exact or it is an error.* `sum` and `product` are a
   left fold over the flattened operands, starting from the first:
   `sum(a, b, c)` is `(a + b) + c`. A step whose mathematical result is
   outside the implementation's integer range is a `NotRepresentable`; nothing
   wraps, saturates or rounds. The check is per step, so
   `product(4294967296, 4294967296, 0)` is an error on every implementation
   although its total is `0`: the first step is `2^64`. With the 64-bit
   range, `sum(9223372036854775807, 1, -1)` is an error for the same reason;
   with the guaranteed range only, that program does not parse (§5).
   `floor-quotient(x, 0)` and `modulo(x, 0)` are `NotRepresentable` too, and
   so are, with the 64-bit range, `negate(-9223372036854775808)` and
   `floor-quotient(-9223372036854775808, -1)`.
3. *Float arithmetic is one correctly rounded operation at a time*, round to
   nearest, ties to even, over the same left fold: `sum(0.1, 0.2, 0.3)` is
   `0.6000000000000001`. No pairwise or compensated summation, no reordering
   and no fused multiply-add.
4. *A non-finite float result is a `NotRepresentable`.* This covers
   `inverse(0.0)`, `quotient(x, 0.0)`, `quotient(0.0, 0.0)` and overflow
   (`sum(1e308, 1e308)`). Underflow is not an error: the result is the nearest
   double, which may be zero, as for a literal (§5).
5. *There is no negative zero.* A float result that is zero is `0.0`:
   `negate(0.0)` is `0.0`, and so is `product(-1.0, 0.0)`.
6. *The conversions.* `floor` of a float whose floor is outside the
   implementation's integer range is a `NotRepresentable`: `floor(1e19)`
   everywhere, `floor(1e16)` with the guaranteed range only. `round` follows
   the same rule for the integer it rounds to. `real` never
   fails. It is exact inside the guaranteed range; beyond it, with the 64-bit
   range, it rounds to nearest, ties to even.
7. *`str` renders what the value is* (§6): `sum(0.1, 0.2)` interpolates as
   `0.30000000000000004` and `sum(0.5, 0.5)` as `1.0`.

Division by a value that happens to be zero is an error, not `null` or `0`,
because either would reach the document as a plausible answer. The guard is
`branch`, whose unselected arm is never evaluated (§6), as in `@share` above.

Over a symbol these builtins do not compute; they build a term
(v3-symbols §1.9).

---

## 12. Errors

| error | when |
|---|---|
| `UnboundName` | a name that is not bound and not a builtin |
| `PathNotFound` | a field the value does not have; carries the path as written |
| `TypeMismatch` | wrong type, wrong arity, a non-callable callee, a value that cannot cross a JSON boundary, a context the decoder refuses (§3, v3-symbols §5.3) |
| `ConcatMismatch` | `<>` over two different types |
| `UnknownLibrary` | an import name the host table does not resolve |
| `ImportCycle` | a library re-entered while already being evaluated |
| `InLibrary` | wraps whatever an imported library failed with, naming that library; nests through a chain of imports |
| `NotRepresentable` | **[§18]** an arithmetic operation has no result in the type of its operands: integer overflow, a zero divisor, a non-finite float (§11) |

---

## 13. Implementation-defined

Programs must not depend on any of these.

- **Object key order**, in values and in the serialized `Node`. `str` is the
  exception: it sorts, so it is deterministic.
- **Evaluation order**, beyond binding order and `Branch`'s laziness.
- **Error message text.** The error *kinds* above are stable; their prose is
  not.
- **The place of an ill-formed string in a sort. [§20]** The string order of
  §11's *Sorting* is defined for well-formed strings. Whether a string may
  hold an unpaired surrogate is not specified, and neither is where one would
  sort.
- **Integer range. [§18]** Either the guaranteed range, `-(2^53 - 1)` to
  `2^53 - 1`, or the signed 64-bit range, `-2^63` to `2^63 - 1`; no other is
  permitted, and an implementation documents which it has (§3). Inside the
  guaranteed range all implementations agree. Between the two, one holds an
  integer exactly or refuses it (a parse error for a literal, a
  `TypeMismatch` for a JSON number in the context, a `NotRepresentable` for a
  result) and never rounds it.
  Outside 64 bits every implementation refuses. A value one implementation
  emits above the guaranteed range is therefore rejected by one that has only
  that range. In an implementation without the number split yet, numbers
  are doubles, integers beyond 2^53 are not exact, and `str` renders whatever
  double survived.

---

## 14. Open

- Array patterns, defaults and rest in binding patterns (§8).
- Calling a call's result directly (§7).
- Types, domains and constraints. The AST is built to accept them: node
  annotations are where derived type/domain information goes, and the
  semantics avoid equating "unknown" with `null`, so a constraint-aware
  evaluator can reuse this AST rather than forking the language. The symbolic
  and constraint half of that is specified in [`v3-symbols.md`](v3-symbols.md)
  and implemented in both hosts; nominal types are specified in
  [`v4-types.md`](v4-types.md) — still a draft, not frozen, but implemented in
  both hosts through roadmap-to-v4 Phase 15 (tooling included: both the CLI
  and the browser playground surface the `"types"`/`"type-constraints"`
  envelope fields). v4 shipped as a **minor** bump — `type X = ...`
  declarations and `@x : T = e` annotations both fit inside the existing
  `Let`/`Emit` chain, so `Program`'s own shape (`DocumentProgram |
  ExpressionProgram`) never changed and no host that pattern-matches it is
  affected (roadmap-to-v4 Phase 15's version decision).
