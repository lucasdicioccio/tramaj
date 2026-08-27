# Tramaj — Syntax and Core Semantic Examples

Tramaj is an expression-oriented templating language.

The language has a deliberately small semantic AST. Surface syntax may be
richer than the AST: syntactic conveniences are parsed and desugared into the
core AST rather than requiring dedicated AST constructors.

The three principal leader characters are:

    .    element / document construction
    $    lookup / expression evaluation
    @    binding (computation block)

---

## 1. Expressions

### Names and paths

A bound value is referenced with `$`:

    $name
    $name.field
    $name.field.field2

`$ctx` is the root input value:

    $ctx
    $ctx.items
    $ctx.user.name

Field access is static when written as a dotted path:

    $ctx.user.name

Dynamic access is available through `lookup`:

    lookup($ctx, $field, fallback)

Names may contain internal hyphens:

    $my-var
    $foo-bar.baz

---

## 2. Literals

Strings:

    "hello"
    "hello world"

String interpolation uses backticks:

    "hello `$name`"
    "count: `$cardinality($nums)`"

Interpolation is surface syntax. It is lowered to the core expression
semantics rather than represented by a special interpolated-string AST node.

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

---

## 3. Calls

Builtin functions are written:

    fn(arg1, arg2)

A builtin may alternatively be written with `$`:

    $fn(arg1, arg2)

These are equivalent:

    cardinality($items)
    $cardinality($items)

The builtin vocabulary is host-defined. Tramaj does not require a builtin
implementation to be part of the language runtime.

A call may also invoke a lambda value:

    $f($x)

A call result may immediately be field-accessed:

    import("foo", $ctx).rendered
    $partial({"name": "x"}).rendered

---

## 4. Lambdas

A lambda is a value:

    (x) => expr

or, with multiple parameters:

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

The lambda captures `threshold`.

A lambda can be passed to another lambda:

    @apply=(f, x) => $f($x)

    $apply($is-large, 42)

There is no recursion. A closure's captured environment is established before
its own binding is visible, so a lambda cannot call itself by its binding name.

A closure used where an ordinary value is required is an error. It must be
called first.

For example, this is invalid:

    ["text", $is-large]

whereas this is valid:

    ["text", $is-large(42)]

---

## 5. Bindings

A computation block may contain one binding per line:

    @name=expr
    @count=$cardinality($ctx.items)
    @label="items: `$count`"

Bindings are evaluated once before the template runs.

A binding may reference:

- `$ctx`;
- any earlier binding.

It may not reference a later binding.

Thus:

    @a=1
    @b=$a

is valid, while:

    @a=$b
    @b=1

is invalid.

A binding is an expression-level construct, so bindings may also be
represented by `let` in the core AST:

    let x = expr in body

The surface `@name=expr` computation block is syntactic sugar for establishing
bindings in the evaluation environment of the template.

---

## 6. Documents are expressions

An element is introduced with `.`:

    .div(...)

Nested elements are expressions:

    .div(
      .h1("Hello"),
      .p("World")
    )

An element may therefore be:

- returned from a lambda;
- assigned to a binding;
- passed as an argument;
- returned from a builtin;
- inserted into another element.

For example:

    @header=
      .header(
        .h1("`$ctx.title`")
      )

    .main(
      $header
    )

The value of `$header` is a document `Node`.

This is an important semantic property: there is no separate "template value"
category in the core language.

---

## 7. Document fragments

A fragment is a document value containing multiple sibling nodes.

Surface syntax:

    <>
      .p("one"),
      .p("two")
    </>

or an equivalent fragment syntax may be introduced by the parser.

The important semantic property is:

    Fragment([node1, node2])

is one document value containing two siblings, without introducing a wrapper
element.

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

A fragment can therefore play the role of JSX-like `children`.

A lambda may return a fragment:

    @buttons=(items) =>
      <>
        map($items, (item) =>
          .button(
            "Deploy `$item.name`"
          )
        )
      </>

The exact surface notation for fragments is not semantically important; it
must lower to the core `Fragment` expression.

---

## 8. Element arguments

An element is written:

    .tag(arg, arg, ...)

Arguments before the first child are attributes.

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

This is valid:

    .div(
      class: "panel",
      .h1("Title"),
      .p("Body")
    )

This is a parse error:

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

---

## 9. Template map

Inside an element, `map` may produce repeated child nodes:

    .ul(
      map($ctx.items, (item) =>
        .li(
          $item.name
        )
      )
    )

The lambda parameter is scoped to the lambda body.

The same `map` function exists as an expression-level operation:

    map($ctx.items, (item) => $item.name)

The expression-level form produces an array.

The document/template form produces document children when its lambda returns
document nodes.

This distinction is semantic rather than requiring two different map
constructors in the core AST.

---

## 10. Template branch

The template-block form of `branch` selects a document node:

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

This differs from the expression-level `branch` function described below.

---

## 11. Expression branch

The expression-level form selects a value:

    branch(
      "unknown",
      $eq($status, "ready"), "ready",
      $eq($status, "error"), "error"
    )

Its arguments are evaluated eagerly before the winning branch is selected.

Therefore all predicates and all candidate values must be safe to evaluate.

The template-block branch and expression-level branch intentionally have
different evaluation semantics.

---

## 12. Actions

The current action syntax is:

    action(eventTypeExpr, keyExpr, payloadExpr)

For example:

    action(
      "on-click",
      "deploy",
      {"deployment": $ctx.deployment}
    )

The resulting node carries structured action information:

    {
      "eventType": "on-click",
      "key": "deploy",
      "payload": {
        "deployment": ...
      }
    }

The action is not encoded as a string.

### Intended restriction

The current implementation permits arbitrary expressions for the event type
and key. The language should be tightened so that action keys are statically
known.

The intended core representation is therefore:

    Action(
      event: String,
      key: String,
      payload: Expr
    )

rather than:

    Action(
      event: Expr,
      key: Expr,
      payload: Expr
    )

This restriction is intentional: implementations should be able to determine
the possible action keys statically.

The payload remains fully dynamic.

The exact host vocabulary for event types remains host-defined.

---

## 13. Action adaptation

The current implementation provides:

    remap-actions(nodeExpr, fnExpr)

which allows arbitrary rewriting of the action object.

The intended stabilized language should restrict this operation to the two
static forms:

    identity
    prefix("namespace:")

Conceptually:

    adapt-actions(node, prefix("deployment:"))

transforms:

    action("on-click", "deploy", payload)

into:

    action("on-click", "deployment:deploy", payload)

Only the action key changes.

The adaptation recursively traverses the complete rendered node tree,
including nodes reachable through imported values and supplied fragments.

This restriction means action adaptation does not require arbitrary action-key
functions and therefore preserves a statically knowable action vocabulary.

The exact surface spelling can remain compatible with the existing
`remap-actions` terminology if desired; the important point is that its
semantic argument becomes an `Identity | Prefix(String)` value rather than an
arbitrary closure.

---

## 14. Imports

The current syntax is:

    import(nameExpr, paramsExpr)

and:

    partial-import(nameExpr, paramsExpr)

An import result exposes:

    .rendered
    .vals

For example:

    @lib=import("components", $ctx.components)

    $lib.rendered
    $lib.vals.button

A library's `rendered` result may be an element/document node or an ordinary
expression value depending on the imported program.

`vals` exposes the imported program's top-level binding values.

### Partial imports

A partial import may be incomplete:

    @partial=partial-import(
      "component",
      {"title": $ctx.title}
    )

It can subsequently be completed:

    $partial({"items": $ctx.items})

and the result may be immediately field-accessed:

    $partial({"items": $ctx.items}).rendered

A partial may be curried across multiple parameters.

### Intended restriction

Imports are intended to become statically identifiable rather than arbitrary
dynamic computation.

The precise surface syntax can remain convenient, but the core import
representation should contain a statically specified import name.

This permits implementations to determine dependencies without executing
arbitrary expressions.

---

## 15. Field access

Static field access:

    $ctx.user.name

is represented directly in the AST.

Dynamic access:

    lookup($ctx, $key, fallback)

is an ordinary function.

Field access remains deliberately relatively unrestricted. In particular, it
should not be over-constrained merely to make the evaluator simpler.

This is useful both for host-defined values and for future type/domain
analysis.

A call result may also be immediately accessed:

    import("foo", $ctx).rendered

and access may continue through multiple segments:

    import("foo", $ctx).vals.config.image

---

## 16. Concat

`Concat` is a core binary operator:

    a <> b

It is a monoid operation over three supported types.

Strings:

    "hello " <> $name

Arrays:

    [1, 2] <> [3, 4]

Objects:

    {"a": 1, "b": 2} <> {"b": 3, "c": 4}

Object concatenation is a right-biased merge. If a key occurs in both
operands, the value from the right operand wins.

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

Object key ordering is not part of the Tramaj semantics.

---

# 17. Complete example

The following combines computation, values, lambdas, document-valued
bindings, fragments, actions, mapping, object shorthand, interpolation,
imports, field access, and concatenation.

    import("deployment", $ctx.deployment)

    @app=$ctx.app
    @version=$ctx.version

    @labels={
      app: $app,
      version: $version
    }

    @is-large=(deployment) =>
      $gt($deployment.replicas, 3)

    @button=(label, key) =>
      .button(
        class: "action",
        action(
          "on-click",
          $key,
          {
            "app": $app,
            "version": $version
          }
        ),
        $label
      )

    @buttons=
      <>
        map($ctx.deployments, (deployment) =>
          $button(
            "Deploy `$deployment.name`",
            "deploy"
          )
        )
      </>

    @panel=(title, children) =>
      .section(
        class: "panel",
        .h2($title),
        $children
      )

    @config=
      {
        "metadata": $labels,
        "replicas": $ctx.replicas,
        "image": "registry.example.com/`$app`:`$version`"
      }

    .main(
      class: "deployment",
      .h1("`$app` — `$version`"),

      $panel(
        "Deployments",
        $buttons
      ),

      branch(
        .p("No deployments"),
        $cardinality($ctx.deployments),
        map($ctx.deployments, (deployment) =>
          .Deployment(
            name: $deployment.name,
            replicas: $deployment.replicas
          )
        )
      )
    )

---

# 18. Core AST correspondence

The parser is free to represent the surface syntax differently internally.
After parsing and desugaring, the implementation produces the semantic AST.

Important examples:

    "hello `$name`"

does not require an interpolation-specific semantic node.

    {foo, bar}

desugars to the equivalent object literal:

    {
      "foo": $foo,
      "bar": $bar
    }

A destructured binding such as:

    let {foo, bar} = $object ...

can eventually desugar to ordinary bindings and field accesses.

A lambda returning a document:

    (x) => .div($x)

is simply a `Lambda` whose body is an `Element`.

A document binding:

    @node=.div("hello")

is simply a binding whose expression evaluates to a `Node`.

A fragment passed as `children` is likewise just a value.

The semantic AST therefore does not distinguish:

    "expression returning JSON"

from:

    "expression returning a document"

until evaluation produces the corresponding value.

---

# 19. Core AST

The current semantic AST is:

    Program
      = DocumentProgram Expr
      | ExpressionProgram Expr

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

      | StringLit String
      | NumberLit Number
      | BoolLit Boolean
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

      | PartialImport
          name: String

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
      | Prefix String

The exact parameter representation may use a list, even if the language
eventually chooses to make multi-argument lambdas syntactic sugar for nested
unary lambdas.

---

# 20. Evaluated Node AST

Evaluation of document-valued expressions produces the normative `Node` AST:

    Node
      = Null
          annotations: Annotations

      | Boolean
          value: Boolean
          annotations: Annotations

      | Number
          value: Number
          annotations: Annotations

      | Text
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


    Annotations
      = Map<String, JSON>

The annotations map is present on every constructor.

The core language currently assigns no meaning to annotation keys. It is an
extension point for future information such as types, domains, constraints,
provenance, and host-specific metadata.

Unknown annotations do not affect core semantics.

Implementations should preserve annotations when copying or transforming
nodes where practical.

---

# 21. Future constraint semantics

The current AST does not contain types, domains, or constraints.

This is intentional.

The same AST should eventually admit another interpretation in which an
expression denotes a value whose concrete value is not yet known.

For example, a future constraint layer might know:

    replicas : Integer
    replicas ∈ 1..10

without choosing a concrete value.

The distinction is:

    null
    unknown
    known domain but unknown concrete value

These must not be conflated.

The current AST should therefore not assume that every expression is
immediately reduced to a concrete primitive value.

For example:

    @replicas=...

    .Deployment(
      replicas: $replicas
    )

can eventually be evaluated by a constraint-aware implementation as a node
annotated with information about the domain of `replicas`.

Likewise, a future constraint evaluator may be able to propagate information
through operations such as:

    $gt($replicas, 3)

or:

    $replicas <> $other

without requiring concrete values.

The concrete evaluator and constraint evaluator operate on the same semantic
AST:

             Tramaj AST
                 |
          +------+------+
          |             |
          v             v
     concrete       constraints
     evaluation     / domains
          |             |
          v             v
       values       symbolic values
          |
          v
       Node AST

Types and domains are therefore a future semantic layer, not a reason to
expand the core AST prematurely.
