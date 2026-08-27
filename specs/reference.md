# Tramaj — Language Reference

This is the reference for the language **as implemented**. Where the earlier
drafts (`core.md`, `merged2.md`, `constraints.md`, `value.md`) disagree with
each other or with this document, this document wins; `decisions.md` records
which reading of those drafts was taken and why. `node-json.md` is normative
for the output wire format and is not repeated in full here.

Two implementations are held to this document: `tramaj/` (PureScript) and
`tramaj-hs/` (Haskell). Anything below marked *implementation-defined* is
where they are permitted to differ; everything else they must not.

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
  | NumberLit    Number
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
  | Concat       left: Expr, right: Expr
  | Import       name: String, parameters: List<(String, ParamValue)>
  | AdaptActions target: Expr, adaptation: ActionAdaptation,
                 function: Optional<Expr>

ParamValue
  = PExpr        Expr            -- supplied now
  | PFromContext path: List<String>   -- supplied at completion

Attribute
  = Attr         name: String, value: Expr
  | ActionAttr   event: String, key: String, payload: Expr

ActionAdaptation
  = Identity
  | Prefix       String
```

**Every static position is a `String`, not an `Expr`**: an import's name, an
action's event and key, an adaptation's prefix, a deferred parameter's path.
That is what makes §9's analyses possible, and the grammar refuses anything
else in those positions — the restriction is enforced at parse time, not
checked later at evaluation time.

There is no `PartialImport` constructor: an import is partial exactly when a
parameter is still `PFromContext`.

---

## 3. Values

```text
Value
  = Null | Boolean | Number | String
  | Array   List<Value>
  | Object  Map<String, Value>
  | Node                        -- a document
  | Closure                     -- a lambda, with its captured environment
  | Builtin                     -- a builtin, referenced but not yet called
  | ImportResult                -- {rendered, vals}
  | PartialImport               -- an import still awaiting context
```

Arrays and objects hold `Value`s, **not** JSON — so a document can travel
inside a structure. That is what makes the JSX-children pattern work without a
separate "template value" category.

JSON is required only at the boundaries where a document would be meaningless:
an attribute value, an action payload, an element's value slot, and an
expression program's result. A closure, a builtin, an import result, a partial
import, or a document reaching one of those positions is an error, not a
silent serialization.

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
  `.td($ctx.count)` yields the number `3`, not `"3"`. How that becomes
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
| `123`, `1.5` | number literal — **no** leading `-` and **no** exponent |
| `true`, `false`, `null` | keyword literals |
| `[a, b]` | array literal |
| `{"k": v}`, `{k: v}`, `{foo}` | object literal; keys may be bare; `{foo}` is shorthand for `{"foo": $foo}` |
| `(x, y) => expr` | lambda |
| `(expr)` | grouping |
| `a <> b` | concat — the only infix operator, left-associative, lowest precedence |
| `.tag(...)` | element |
| `.(...)` | fragment |
| `value(expr)` | element value slot; at most one, attribute position |
| `action("event", "key", payload)` | action; attribute position, any number |
| `map/filter(coll, fn)`, `scan/fold(coll, init, fn)` | array primitives |
| `branch(fallback, p1, v1, …)` | conditional |
| `import("name", {k: expr, j: ctx(path)})` | import |
| `adapt-actions(node, prefix("ns:") \| identity [, fn])` | action adaptation |

Names — bindings, path segments, tags, bare keys — start with a letter and
may contain letters, digits, `_` and internal `-`. Whitespace is
insignificant except as a separator, with one exception: a field-access `.`
must directly follow the `)` it applies to, so `f()` on one line and
`.div(...)` on the next are two separate things. There are no comments.

**Attribute position before children.** Attributes, `action(...)` and
`value(...)` must all precede any child; a child first is a parse error.

**Static positions reject interpolation.** A backtick inside an import name,
action event/key, adaptation prefix or object key is a parse error rather than
a literal backtick — someone writing ``import("lib-`$x`")`` means
interpolation, and that position cannot be computed.

**A malformed special form is a parse error.** Name recognition backtracks;
the shape does not. `action("on-click", $computed, {})` fails to parse rather
than quietly becoming a call to an unbound function named `action`.

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
| a closure / builtin / import result / partial | an error |

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
| number | exactly as ECMAScript's `Number::toString` — `3`, `1.5`, `0.05`, `100000000000`, `1e+21`, `1e-7` |
| array / object | compact JSON, **keys sorted**, numbers by the same rule, strings JSON-quoted |

Keys are sorted because key order is not semantically significant, so it must
not be observable here either. Both implementations must produce these
character for character.

---

## 7. Imports

```
import("deployment", {
  name:     "web",              -- supplied now
  replicas: ctx(spec.replicas)  -- supplied at completion
})
```

(That one is *partial*, because of the `ctx(...)`, so it is a value to be
completed rather than a finished result — see below.)

`ctx(path)` states **provenance**, not absence: this parameter comes from the
context supplied when the import is completed. It is deliberately distinct
from `$ctx.spec.replicas`, which reads the *current* context now.

An import with no unresolved `ctx(...)` runs immediately. One with any is a
partial value, completed by calling it with a context object — and completion
is **progressive**: paths the context does not carry stay deferred.

```
@p=import("panel", {name: ctx(n), replicas: ctx(r)})
@half=$p({"n": "web"})
$half({"r": 2}).rendered
```

A completed import exposes `.rendered` (whatever its root evaluated to — a
document or an ordinary value) and `.vals` (its own top-level bindings).

A library is evaluated against its parameters as its own fresh `$ctx`. Import
names are resolved by a host-supplied table; where a library came from is not
the language's business. Re-entering a library already being evaluated is
reported as a cycle, not run.

Because partiality is *declared*, a parameter that is simply missing is a hard
error rather than being reinterpreted as partiality.

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

Escape sequences:

```
\n  \t  \r  \\  \"  \`  \0  \u{1F600}
```

`\u{...}` is braced, so an astral code point needs no surrogate pair.

*Deferred:* destructuring in `let` and lambda parameters. It is pure
desugaring and needs no change to the core AST.

---

## 9. Static analysis

All three answer from the AST alone — no context, no library evaluation, no
host code. Each has a deep variant that follows imports through a library
table and cuts cycles.

| function | answers |
|---|---|
| `staticImportNames` / `transitiveImportNames` | which libraries this program depends on |
| `staticActionKeys` / `deepActionKeys` | which action keys it can emit |
| `contextHoles` / `deepContextHoles` | which context values it still needs |

`staticActionKeys` **applies** adaptation rather than ignoring it, using the
same function the evaluator does: `adapt-actions(x, prefix("user:"))` over
`{save, delete}` yields `{user:save, user:delete}`. That is the payoff of
restricting adaptation to identity-or-prefix.

These are over-approximations: keys under a `Branch` arm that a given context
will never select are still reported. A name that is imported but missing from
the table is reported too — an unresolvable dependency is what a caller wants
to hear about.

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
gives `b:a:key` — with no "already adapted" state. Applied to a partial
import, the adaptation is queued and runs when the import completes.

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
| `eq(a, b)` | deep equality; no cross-type coercion, so `eq(1, "1")` is `false` |
| `lt`, `lte`, `gt`, `gte` | numbers only |
| `has(container, key)` | tolerant: a missing key, out-of-range index or wrong-shaped container answers `false` |
| `lookup(container, key, fallback)` | dynamic access; the fallback is mandatory, so this never errors |
| `map`, `filter`, `scan`, `fold` | also core constructors — see below |
| `concat(…)` | variadic array join; every argument must be an array |
| `append(arr, item)` | adds one element; an array item is added whole, not spliced |

`scan` is `scanl`, not `scanl1`: its output starts with the seed and is one
longer than the input. `fold` takes the same `(acc, item)` step and returns
only the final accumulator.

**There is no arithmetic.** No `+`, `-`, `*`, and no numeric builtins beyond
the comparisons above — a template compares and selects, it does not compute.
Numbers reach a program through `$ctx`, a literal, or a host-supplied library.

`map`/`filter`/`scan`/`fold` are core constructors rather than builtins
because their function argument needs a fresh binding per element. `branch` is
a core constructor because it must leave an arm unevaluated, which no builtin
can do.

---

## 12. Errors

| error | when |
|---|---|
| `UnboundName` | a name that is not bound and not a builtin |
| `PathNotFound` | a field the value does not have; carries the path as written |
| `TypeMismatch` | wrong type, wrong arity, a non-callable callee, a value that cannot cross a JSON boundary |
| `ConcatMismatch` | `<>` over two different types |
| `UnknownLibrary` | an import name the host table does not resolve |
| `ImportCycle` | a library re-entered while already being evaluated |

---

## 13. Implementation-defined

Programs must not depend on any of these.

- **Object key order**, in values and in the serialized `Node`. `str` is the
  exception: it sorts, so it is deterministic.
- **Evaluation order**, beyond binding order and `Branch`'s laziness.
- **Error message text.** The error *kinds* above are stable; their prose is
  not.
- **Number precision.** Numbers are doubles. Beyond 2^53 integers are not
  exact, and `str` renders whatever double survived.

---

## 14. Open

- Destructuring (§8).
- Calling a call's result directly (§7).
- Negative and exponent number literals — `-1` and `1e5` are parse errors
  today. With no arithmetic in the language (§11) there is no way to write
  such a value inline at all; it has to arrive through `$ctx` or a library.
- A shared cross-implementation conformance corpus. Both suites already assert
  against `node-json.md` and both fixture tables are template / context /
  expected-JSON triples, so the remaining step is one corpus file both runners
  read.
- Types, domains and constraints. The AST is built to accept them: node
  annotations are where derived type/domain information goes, and the
  semantics avoid equating "unknown" with `null`, so a constraint-aware
  evaluator can reuse this AST rather than forking the language.
