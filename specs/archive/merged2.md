# Tramaj — Syntax, Core AST, and Evaluation

Tramaj is an expression-oriented templating language.

The language has a deliberately small semantic AST. Surface syntax may be
richer than the AST: syntactic conveniences are parsed and desugared into
the core AST rather than requiring dedicated AST constructors.

The language has three principal leader characters:

    .    element / document construction
    $    lookup / expression evaluation
    @    binding (computation block)

---

# 1. Values and Documents

Tramaj distinguishes two related semantic domains.

`Value` is the computational value domain. It contains JSON-like values,
functions, and document nodes.

`Node` is the document/output domain.

```text
Value
  = Null
  | Boolean
  | Number
  | String
  | Array(List<Value>)
  | Object(Map<String, Value>)
  | Lambda(...)
  | Node

The precise runtime representation of Lambda is implementation-specific.

A Node is a document value. It is deliberately not a general JSON tree:

Node
  = Text
      value: String
      annotations: Annotations

  | Element
      tag: String
      attributes: List<NodeAttribute>
      children: List<Node>
      annotations: Annotations

  | Fragment
      children: List<Node>
      annotations: Annotations

A document can therefore contain structured computational values through
attributes or other host-defined mechanisms without requiring JSON Array
and Object constructors in the Node AST.

The distinction is important:

JSON-like computation        Document structure

Object(...)       ───────┐
Array(...)        ───────┤
Number(...)       ───────┤
String(...)       ───────┤
                         ▼
                       Value
                         │
                         │ used by
                         ▼
                      Element
                         │
                         ▼
                        Node

A host may fold a Node into JSON, HTML, HCL, YAML, a UI tree, or another
target representation.
2. Annotations

Every Node constructor carries an annotations map:

Annotations
  = Map<String, JSON>

The core language currently assigns no meaning to annotation keys or values.

Annotations provide an extension point for future information, including:

    types;

    domains and constraints;

    provenance;

    host-specific metadata;

    optimization hints;

    other semantic information.

Unknown annotations do not affect core Tramaj semantics.

Implementations SHOULD preserve annotations when copying or transforming
nodes where practical.

The annotation representation is deliberately opaque to the current core
semantics. Future specifications may define particular annotation keys or
namespaces without changing the Node constructors.

Annotations may eventually be used to carry type/domain information produced
by constraint-aware evaluation.
3. Node Attributes

NodeAttribute
  = Attribute
      name: String
      value: Value

  | Action
      event: String
      key: String
      payload: Value

Ordinary attributes contain arbitrary Values.

Action event types and action keys are strings. The intended stabilized
semantics make action keys statically known; see Actions below.
4. Names and Paths

A bound value is referenced with $:

$name
$name.field
$name.field.field2

$ctx is the root input value:

$ctx
$ctx.items
$ctx.user.name

Field access is static when written as a dotted path:

$ctx.user.name

Dynamic access is available through lookup:

lookup($ctx, $field, fallback)

Names may contain internal hyphens:

$my-var
$foo-bar.baz

Field access is intentionally not heavily restricted. In particular, static
field paths and dynamic lookup remain available for host-defined values and
future type/domain analysis.
5. Literals

Strings:

"hello"
"hello world"

String interpolation uses backticks:

"hello `$name`"
"count: `$cardinality($nums)`"

An interpolation may contain an arbitrary expression:

"count: `$cardinality($nums)`"

String interpolation is surface syntax. It is desugared into ordinary
expression operations and does not require a dedicated semantic AST node.

Numbers:

123
123.45

Booleans:

true
false

Null:

null

Arrays:

[1, 2, 3]
[$name, 42, "hello"]

Objects:

{"name": $name, "count": $count}

Object keys are quoted in the core surface syntax.

Object shorthand is a planned convenience syntax:

{name, count}

which desugars to:

{"name": $name, "count": $count}

6. Calls

Builtin functions are written:

fn(arg1, arg2)

A builtin may alternatively be written with $:

$fn(arg1, arg2)

These are equivalent:

cardinality($items)
$cardinality($items)

The builtin vocabulary is fixed for a given host/runtime. Tramaj does not
require custom function definitions in the builtin namespace.

A call may invoke a lambda value:

$f($x)

A call result may immediately be field-accessed:

import("foo", $ctx).rendered
$partial({"name": "x"}).rendered

Field access may continue through multiple segments:

import("foo", $ctx).vals.config.image

7. Lambdas

A lambda is a value:

(x) => expr

or:

(x, y) => expr

A lambda may be passed inline:

map($ctx.items, (item) => $item.name)

or bound:

@is-large=(x) => $gt($x, 10)

and subsequently called:

$is-large(42)

A bound lambda may also be passed by reference:

map($ctx.items, $is-large)

Lambdas are closures. They capture the lexical environment in which they are
created.

For example:

@threshold=10
@is-large=(x) => $gt($x, $threshold)

The lambda captures threshold.

A closure can itself be passed to another function:

@apply=(f, x) => $f($x)

$apply($is-large, 42)

There is no recursion. A closure's captured environment is established
before its own binding is visible, so a lambda cannot call itself by its
binding name.

A closure used where an ordinary value is expected is an error. It must be
called first.

For example:

[$is-large, "text"]

is invalid if the lambda is being used as a plain value, whereas:

[$is-large(42), "text"]

is valid.
8. Computation Blocks and Bindings

A computation block appears above the template:

@name=expr
@count=$cardinality($ctx.items)
@label="items: `$count`"

One binding occurs per line.

Bindings are evaluated once against $ctx before the template runs.

A binding may reference:

    $ctx;

    any earlier binding.

It may not reference a later binding.

Thus:

@a=1
@b=$a

is valid.

But:

@a=$b
@b=1

is invalid.

A binding establishes an ordinary value. That value may be:

    a scalar;

    an array;

    an object;

    a lambda;

    a document Node;

    another supported value.

For example:

@count=$cardinality($ctx.items)

or:

@header=.header(
  .h1("`$ctx.title`")
)

The second binding contains a document value.

At the core AST level, bindings are represented by ordinary expression-level
Let semantics:

let x = expr in body

The @name=expr computation-block syntax is surface syntax for establishing
these bindings in the template's evaluation environment.
9. Documents Are Expressions

An element is introduced with .:

.div(...)

Nested elements are expressions:

.div(
  .h1("Hello"),
  .p("World")
)

An element can therefore be:

    returned from a lambda;

    assigned to a binding;

    passed as an argument;

    returned from a builtin;

    inserted into another element.

For example:

@header=.header(
  .h1("`$ctx.title`")
)

.main(
  $header
)

$header is an ordinary bound value whose value is a Node.

There is no separate "template value" category in the core language.
10. Document Fragments

A fragment is a document value containing multiple sibling nodes.

Conceptually:

Fragment([
  .p("one"),
  .p("two")
])

The surface syntax may be written using a fragment delimiter:

<>
  .p("one"),
  .p("two")
</>

The exact delimiter is surface syntax and may evolve independently of the
core AST.

A fragment does not introduce a wrapper element.

Fragments can be bound:

@children=
  <>
    .p("one"),
    .p("two")
  </>

and passed to another lambda:

@panel=(title, children) =>
  .section(
    .h2($title),
    $children
  )

$panel(
  "Deployment",
  $children
)

A fragment is therefore suitable for the JSX-like children use case.

A lambda may return a fragment:

@buttons=(items) =>
  <>
    map($items, (item) =>
      .button(
        "Deploy `$item.name`"
      )
    )
  </>

11. Element Syntax

An element is:

.tag(arg, arg, ...)

Named attributes must occur before children.

A named attribute is:

key: value

The key may be a bare identifier:

.div(class: "panel")

or a quoted string:

.div("data-id": $ctx.id)

Attribute values are arbitrary expressions:

.div(
  class: $ctx.className,
  count: $cardinality($ctx.items)
)

All attributes must occur before children.

Valid:

.div(
  class: "panel",
  .h1("Title"),
  .p("Body")
)

Invalid:

.div(
  .h1("Title"),
  class: "panel"
)

Children are expressions and may therefore be:

"text"
$value
.element(...)
$document
map(...)
branch(...)
$component(...)
...

12. Template Map

Inside an element, map may produce repeated child nodes:

.ul(
  map($ctx.items, (item) =>
    .li(
      $item.name
    )
  )
)

The lambda parameter is scoped to the lambda body.

The same map operation exists as an expression-level operation:

map($ctx.items, (item) => $item.name)

The expression-level form produces an array.

The document form produces document children when its lambda returns document
nodes.

This does not require separate core AST constructors for the two cases.
13. Template Branch

The template-block form of branch selects a document node:

branch(
  .p("fallback"),
  $eq($ctx.status, "ready"), .Status("Ready"),
  $eq($ctx.status, "error"), .Status("Error")
)

It means:

if predicate1 then node1
else if predicate2 then node2
else fallback

Only the selected node is evaluated.

Therefore errors inside unreachable nodes do not surface.
14. Expression Branch

The expression-level form selects a value:

branch(
  "unknown",
  $eq($status, "ready"), "ready",
  $eq($status, "error"), "error"
)

Its arguments are evaluated eagerly before the winning branch is selected.

There is therefore no short-circuiting between its predicates and candidate
values.

The template-block branch and expression-level branch intentionally have
different evaluation semantics.
15. Actions

The current surface form is:

action(eventTypeExpr, keyExpr, payloadExpr)

For example:

action(
  "on-click",
  "deploy",
  {
    "deployment": $ctx.deployment
  }
)

The resulting node carries structured action information:

{
  "eventType": "on-click",
  "key": "deploy",
  "payload": ...
}

The action is not encoded as a string.
Stabilized action semantics

The language should restrict action keys so that the set of possible keys is
statically knowable.

The intended semantic representation is therefore:

Action(
  event: String,
  key: String,
  payload: Value
)

rather than an action whose key is an arbitrary runtime expression.

The payload remains fully dynamic.

Event vocabulary remains host-defined. A host may recognize "on-click",
for example, while another host may recognize another event vocabulary.

The important static property concerns the action key, not the host's event
vocabulary.
16. Action Adaptation

The existing implementation supports:

remap-actions(nodeExpr, fnExpr)

where an arbitrary closure rewrites actions.

The stabilized language should restrict this operation to static adaptation
forms.

Conceptually:

adapt-actions(node, identity)

and:

adapt-actions(node, prefix("deployment:"))

The latter transforms:

action("on-click", "deploy", payload)

into:

action("on-click", "deployment:deploy", payload)

Only the action key changes.

The adaptation recursively traverses the complete rendered node tree,
including nodes reachable through imported values and supplied fragments.

Repeated adaptations compose normally.

The language should not require arbitrary action-rewriting functions. This
restriction keeps the set of possible action keys statically discoverable.

The exact surface spelling may remain compatible with the existing
remap-actions name if desired; the semantic operation is an
Identity | Prefix(String) adaptation rather than an arbitrary lambda.

17. Imports

Imports reuse another Tramaj template as a library or component.

There is a single import operation:

    import(name, parameters)

The import name is statically specified. `parameters` describes the values
already supplied to the imported template and any values that should be
obtained from the context when the import is completed.

An import may therefore be either immediately complete or partially applied.
Partiality is not a separate language construct and is not discovered by
analyzing the imported template.

## Parameter values

Each import parameter is one of:

    Expr(expr)

or:

    FromContext(path)

`Expr(expr)` supplies an ordinary value, evaluated when the import is
evaluated.

`FromContext(path)` declares that the value is to be obtained from the
context supplied when the import is completed.

For example:

    import("deployment", {
      name: "web",
      replicas: ctx(spec.replicas),
      image: "nginx"
    })

means:

    name     ← "web"
    replicas ← completion context's .spec.replicas
    image    ← "nginx"

The context path is explicit. An implementation does not need to inspect the
imported template's AST to determine where a missing parameter comes from.

The `ctx(path)` syntax is intentionally distinct from `$ctx.path`:

    $ctx.spec.replicas

means "read `spec.replicas` from the current evaluation context now."

    ctx(spec.replicas)

means "when this import is completed, obtain `spec.replicas` from the
completion context."

The path in `FromContext` is a static path, using the same path semantics as
ordinary field access.

## Complete imports

An import with no unresolved `FromContext` parameters is complete:

    import("deployment", {
      name: "web",
      replicas: 3
    })

Its result can be used directly:

    import("deployment", {
      name: "web",
      replicas: 3
    }).rendered

## Partially applied imports

An import containing one or more `FromContext` parameters is a partial import:

    @deployment=import("deployment", {
      name: "web",
      replicas: ctx(spec.replicas)
    })

The partial value can later be completed by supplying a context:

    $deployment({
      spec: {
        replicas: 3
      }
    })

The result is equivalent to an import in which the context-wired parameter
had been supplied explicitly:

    import("deployment", {
      name: "web",
      replicas: 3
    })

Completion may therefore be viewed as resolving each `FromContext(path)`
against the supplied context.

A completed import exposes:

    .rendered
    .vals

For example:

    $deployment({
      spec: {"replicas": 3}
    }).rendered

or:

    $deployment({
      spec: {"replicas": 3}
    }).vals.button

The `.rendered` value is whatever the imported program's root evaluates to.
It may be a `Node` or an ordinary `Value`.

`.vals` exposes the imported program's top-level bindings, with ordinary
field access available on the resulting object.

## Composition and currying

A partial import may itself be passed around, stored in bindings, or supplied
to other expressions.

Completion does not require all deferred parameters to be resolved at once.
A partial may be completed progressively when the language's parameter
structure permits it.

For example, conceptually:

    @component=import("component", {
      title: ctx(title),
      item: ctx(item)
    })

A completion operation may resolve the required context values and produce
the same result as supplying those values directly.

The important invariant is that `FromContext(path)` describes **provenance**,
not merely absence of a value: it explicitly states that the value comes from
the context at completion time.

## Core representation

The core AST contains one import constructor:

    Import
      name: String
      parameters: List<Parameter>

    Parameter
      name: String
      value: ParameterValue

    ParameterValue
      = Expr(Expr)
      | FromContext(Path)

There is deliberately no `PartialImport` AST constructor.

Whether an `Import` is complete or partial is determined solely by whether
its parameter specification contains unresolved `FromContext` values.

This makes import dependencies and context wiring statically inspectable
without requiring whole-template AST analysis.

18. Concat

Concat is a core binary operator:

a <> b

It is a monoid operation over three supported types.

Strings:

"hello " <> $name

Arrays:

[1, 2] <> [3, 4]

Objects:

{"a": 1, "b": 2} <> {"b": 3, "c": 4}

Object concatenation is right-biased. If a key occurs in both operands, the
value from the right operand wins.

The supported combinations are:

String × String → String
Array  × Array  → Array
Object × Object → Object

Mixed types are invalid.

The operation is associative and has the natural identity for each supported
type:

""
[]
{}

Object key ordering is not semantically significant.
19. Destructuring

Destructuring is planned as surface syntax rather than a core AST feature.

For example:

let {foo, bar} = $object in
  ...

desugars into ordinary bindings and field accesses, conceptually:

let foo = $object.foo in
let bar = $object.bar in
  ...

Likewise:

({foo, bar}) => expr

desugars to a lambda taking one ordinary parameter followed by the
corresponding field bindings.

Object shorthand:

{foo, bar}

desugars to:

{
  "foo": $foo,
  "bar": $bar
}

The parser therefore becomes responsible for convenient destructuring and
shorthand syntax while the evaluator sees only the core expression AST.
20. Evaluation

Expressions evaluate to Value.

A document-valued expression evaluates to a Node.

The principal evaluation relationship is:

Expr
  │
  ▼
Value
  │
  └── Node
        │
        ▼
     Node AST

Element evaluation:

    Evaluate each attribute value.

    Evaluate each child expression.

    Each child in a document context must produce a document Node.

    Construct an Element containing the resulting attributes and children
    in source order.

Fragment evaluation:

    Evaluate each child expression.

    Each child must produce a document Node.

    Construct a Fragment containing those nodes in source order.

A fragment remains a real Fragment in the normative Node AST.

A host may flatten fragments when folding the Node AST into its target
representation.

Branch evaluation:

    expression-level branch evaluates all of its arguments eagerly;

    template-block branch evaluates only the selected node.

Let/binding evaluation:

let x = expr in body

evaluates expr before body, extending the environment visible to body.

Lambda evaluation creates a closure over the lexical environment at the point
where the lambda is created.
21. Node JSON Representation

The evaluated Node AST is JSON-serializable.

Its JSON representation is part of the Tramaj specification and provides the
portable interchange format between independent implementations.

The Node AST itself is intentionally document-oriented:

Node
  = Text
  | Element
  | Fragment

It is not a general JSON AST.

Computational JSON-like structures remain Values:

Null
Boolean
Number
String
Array
Object

An implementation may therefore independently implement the semantic
evaluation/folding layer while using the normative Node JSON representation
as its interchange boundary.

For example, a host may fold:

Element(
  "Deployment",
  [
    Attribute("replicas", someValue),
    Attribute("image", someValue)
  ],
  []
)

into Kubernetes YAML, Terraform/HCL, HTML, a UI tree, or another target
representation.

The Tramaj specification does not prescribe the final rendering.
22. Future Constraint Evaluation

The current concrete evaluator reduces expressions to concrete values where
possible.

The AST is deliberately designed so that a future implementation can instead
interpret expressions using symbolic values with types, domains, and
constraints.

For example:

@replicas=...

could eventually produce a symbolic value:

type   = Integer
domain = 1..10
value  = unknown

This is distinct from:

null

and from an unconstrained unknown value.

The same semantic AST can therefore support both:

concrete evaluation

and:

constraint-aware evaluation

without introducing a second template language.

For example:

.Deployment(
  replicas: $replicas
)

can produce a Node whose attribute value contains a symbolic value.

A constraint solver could propagate information through expressions such as:

$gt($replicas, 3)

or:

$eq($replicas, 3)

and through structured values such as:

{
  "replicas": $replicas,
  "image": $image
}

without requiring those values to be concretized first.

Annotations on Nodes provide a future place to expose derived type/domain
information when appropriate, while the underlying Value representation
continues to carry the actual symbolic values.

The current specification does not define the constraint system. It only
requires that the core AST not preclude it.
23. Core AST

After parsing and surface-syntax desugaring, an implementation produces a
small semantic AST.

Program
  = DocumentProgram(Expr)
  | ExpressionProgram(Expr)


Expr
  = Path
      root: String
      fields: List<String>

  | FieldAccess
      target: Expr
      fields: List<String>

  | Call
      function: Expr
      arguments: List<Expr>

  | Lambda
      parameters: List<Parameter>
      body: Expr

  | Let
      binding: Binding
      body: Expr

  | StringLit
      value: String

  | NumberLit
      value: Number

  | BoolLit
      value: Boolean

  | NullLit

  | ArrayLit
      elements: List<Expr>

  | ObjectLit
      fields: List<(String, Expr)>

  | Element
      tag: String
      attributes: List<Attribute>
      children: List<Expr>

  | Fragment
      children: List<Expr>

  | Branch
      condition: Expr
      thenBranch: Expr
      elseBranch: Expr

  | Map
      collection: Expr
      function: Expr

  | Filter
      collection: Expr
      function: Expr

  | Scan
      collection: Expr
      initial: Expr
      function: Expr

  | Fold
      collection: Expr
      initial: Expr
      function: Expr

  | Concat
      left: Expr
      right: Expr

  | Import
      name: String
      parameters: Expr

  | PartialImport
      name: String
      parameters: Expr

  | AdaptActions
      target: Expr
      adaptation: ActionAdaptation


Binding
  = Binding
      name: String
      value: Expr


Parameter
  = Parameter
      name: String


Attribute
  = Attribute
      name: String
      value: Expr

  | Action
      event: String
      key: String
      payload: Expr


ActionAdaptation
  = Identity
  | Prefix
      prefix: String

The exact treatment of builtins may instead use a dedicated Builtin or
BuiltinCall constructor if that makes implementations simpler. The
important semantic property is that the builtin vocabulary is fixed rather
than user-extensible.

The parser may have additional internal nodes before desugaring. Those are
not part of the normative core AST.
24. Design Boundary

The intended architecture is:

         Surface syntax
      rich + convenient
              │
           parser
              │
         desugaring
              ▼
         Core Expr AST
              │
      ┌───────┴────────┐
      │                │
      ▼                ▼

concrete evaluator constraint
│ evaluator
▼ │
Value │
│ │
└───────┬────────┘
▼
Node AST
│
▼
normative Node JSON
│
┌───────┼────────┐
▼ ▼ ▼
HTML YAML/HCL UI


Surface syntax should remain pleasant and extensible.

The core AST should remain small and semantic.

In particular, new surface conveniences such as:

- escaped strings;
- object shorthand;
- destructuring;
- alternative lambda syntax;
- additional interpolation syntax;

should normally desugar into existing core constructors.

Conversely, operations with independent semantic meaning should have explicit
core representation where necessary, such as:

- `Let`;
- `Lambda`;
- `Element`;
- `Fragment`;
- `Branch`;
- `Concat`;
- `Import`;
- `PartialImport`;
- `AdaptActions`.

This keeps the implementation boundary stable while leaving the surface
language room to evolve.
