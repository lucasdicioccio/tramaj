Tramaj — Language Core

This document defines the current semantic core of Tramaj. It is intended to be sufficient for an independent implementation. Surface syntax may be richer than this AST; implementations should parse and desugar surface syntax into the core AST before evaluation.

The AST is a semantic representation, not a parser representation. It contains no source locations, comments, formatting information, or parser-recovery nodes.

Design principles
Tramaj is an expression-oriented language.
Expressions produce values.
Document nodes are values and can therefore be passed to functions/templates like any other value.
The core AST should be small and represent semantic constructs rather than syntactic conveniences.
Surface syntax may be richer and should be desugared into the core AST where possible.
Hosts may provide arbitrary builtins.
Document nodes are intentionally unrestricted by the language; hosts decide how to interpret/fold them.
Imports and action keys have intentionally restricted/static forms.
Types, domains, and constraints are not currently part of the AST. The language should remain open to a future constraint-oriented interpretation in which a value may have a known domain without having a concrete value.
Core AST
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
      parameter: Parameter
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
AST validity

The AST defines the shape of the semantic language. Additional rules define which ASTs are valid Tramaj programs.

Where practical, invalid semantic constructs should be impossible to represent directly in the AST. For example, an action key is a String, not an arbitrary Expr, and action adaptation contains only Identity or a static Prefix.

Other validity rules, such as identifier syntax and contextual restrictions, should be specified separately rather than encoded into the AST with numerous specialized types.

Values and expressions

Expressions evaluate to values.

Values may include ordinary JSON-like values, functions/closures, partials, and document nodes.

A function is a value. A lambda captures its lexical environment and accepts one parameter.

A Let expression introduces one lexical binding:

Let(
  Binding(name, value),
  body
)

The binding's value is evaluated and bound before evaluating the body. Nested Let expressions provide multiple sequential bindings.

Field access is dynamic and may be applied to any expression:

FieldAccess(target, ["foo", "bar"])

The AST does not constrain the shape of the resulting value. Validity and runtime semantics determine whether a particular field access succeeds.

Document expressions

Element and Fragment are expressions and therefore produce values.

An element contains:

a tag name;
zero or more attributes;
zero or more child expressions.

A fragment contains a sequence of child expressions.

A child expression may itself produce a document node or fragment. This allows document fragments to be passed into templates/components as ordinary values, similar to children in JSX, without introducing a separate runtime "template fragment" abstraction.

A partial is an executable/runtime value, whereas a fragment is an already-produced document value. Arbitrary runtime closures and partials are therefore not required to be JSON-serializable.

The language does not prescribe HTML or any other particular document model. Node is a generic host-interpreted document representation.

Actions

An action is an attribute-like document construct:

Action(
  event,
  key,
  payload
)

The action key is statically specified. It is not an arbitrary expression.

The payload remains a normal expression and may therefore be fully dynamic.

The language deliberately distinguishes the statically identifiable action key from the dynamically computed action payload.

Action adaptation

Action adaptation is restricted to two forms:

Identity
Prefix String

It is not an arbitrary function that rewrites action keys.

Applying:

AdaptActions(target, Prefix("foo:"))

recursively prefixes action keys in the resulting document tree.

For example:

save
delete

becomes:

foo:save
foo:delete

Action adaptation applies structurally to the entire resulting subtree, including actions contained in supplied document fragments and nested components.

Adaptations compose normally. Applying prefix a: and then prefix b: produces:

b:a:action

No special provenance or "already adapted" state is required.

This restriction ensures that the action vocabulary remains statically inspectable while retaining compositional namespacing.

Imports

Imports are statically named dependencies:

Import(name)

The imported name is not an arbitrary expression.

Import resolution is a host concern. The host determines what a given import name refers to.

PartialImport(name) similarly refers to a statically named reusable partial/component. The resulting partial is a runtime value and may be invoked or passed through the expression language.

Import cycles must be detected rather than causing unbounded recursive evaluation.

Builtins

The host may provide arbitrary builtin functions and values.

The core language does not prescribe the builtin vocabulary or require builtin semantics to be statically understood.

A builtin may perform operations involving external systems, databases, users, assets, or any other host capability.

This is an intentional host boundary.

Functional forms

The following are core language operations:

Map
Filter
Scan
Fold

They are distinct AST constructs rather than ordinary builtin calls because they have language-level evaluation semantics.

Ordinary host functions are represented through Call.

Conditional evaluation

Branch evaluates its condition and evaluates only the selected branch.

This is distinct from ordinary function application, where function arguments are evaluated before invocation.

The distinction is semantic and must be preserved by implementations.

Concatenation

Concat is a binary monoid operation.

Its operands must have the same supported type:

String × String → String
Array  × Array  → Array
Object × Object → Object

For strings, concatenation joins the strings.

For arrays, concatenation appends the elements of the right array to the left array.

For objects, concatenation is a right-biased merge: the result contains the keys from both operands, and when a key occurs in both operands, the value from the right operand is used.

Examples:

"foo" <> "bar"
→ "foobar"

[1, 2] <> [3, 4]
→ [1, 2, 3, 4]

{a: 1, b: 2} <> {b: 3, c: 4}
→ {a: 1, b: 3, c: 4}

Mixed-type concatenation is invalid.

The operation is associative and each supported type has its natural identity:

String → ""
Array  → []
Object → {}

Object key ordering is not part of the language semantics. Programs must not rely on it. Implementations may choose any ordering when representing or serializing objects. Implementations may, as a non-normative quality/security consideration, preserve a stable ordering where practical.

Surface syntax and desugaring

The core AST is deliberately smaller than the surface language.

The parser may support additional convenient syntax and should desugar it into the core AST rather than adding AST constructors merely to represent syntactic sugar.

Examples include:

Escaped strings

Surface syntax:

"hello\nworld"

produces:

StringLit("hello\nworld")

Escaping is lexical syntax and does not require a separate AST node.

Object shorthand

Surface syntax:

{foo, bar}

desugars to the equivalent of:

ObjectLit [
  ("foo", Path("foo", [])),
  ("bar", Path("bar", []))
]

Mixed shorthand and explicit fields are likewise lowered to ObjectLit:

{foo, bar: baz}

becomes equivalent to:

{
  foo: foo,
  bar: baz
}
Destructuring

Future/desirable destructuring syntax should similarly be lowered into existing Let, Lambda, and FieldAccess constructs where its semantics permit.

For example, a conceptual parameter:

{foo, bar}

may be lowered to a fresh parameter followed by bindings equivalent to:

let foo = parameter.foo in
let bar = parameter.bar in
...

No dedicated destructuring node is required unless future semantics make destructuring impossible to express through the existing core.

The general rule is:

Surface syntax may be rich; the semantic AST should remain small.

Node serialization

The Node AST is a normative part of the Tramaj specification. Every Node MUST have a lossless JSON serialization defined by the specification, and the JSON representation MUST contain all information necessary to reconstruct an equivalent Node.

Implementations MAY use any internal representation of nodes, but conforming implementations MUST be able to produce the specified JSON representation.

This JSON representation is the portable interchange boundary for document-oriented evaluation. An implementation may therefore focus on parsing and evaluating Tramaj into the specified Node representation, while hosts and other implementations may independently deserialize and fold that representation into HTML, UI trees, YAML, HCL, configuration formats, or other target systems.

Runtime values such as closures and arbitrary partials are not required to be JSON-serializable; the serialization contract applies to completed Node values.

The exact JSON schema for Node is normative and is specified separately from the language AST.

Future types and constraints

The core AST intentionally contains no type or constraint annotations.

The semantics should remain open to a future interpretation in which an expression may be associated with a type, domain, or set of constraints without necessarily having a concrete value.

In particular, the language should not equate:

unknown value

with:

null

or require every semantic interpretation of an expression to immediately produce a concrete value.

A future type/constraint system may be layered over the same AST:

              Tramaj AST
                   |
          +--------+--------+
          |                 |
          v                 v
 concrete semantics   constraint semantics
          |                 |
       values          domains/constraints

The current language does not otherwise prescribe such a system.

Implementation boundary

An implementation may use any internal parser AST, runtime representation, optimization strategy, source-location system, or memory representation.

Conformance is defined in terms of the semantic core:

surface syntax
      ↓
   desugaring
      ↓
   core AST
      ↓
   evaluation
      ↓
   values / Node
      ↓
Node JSON or host-specific fold

The parser and internal representation are implementation details. The core AST and its semantics are the portable language contract.
