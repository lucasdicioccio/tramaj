# tramaj — Language Poisitioning

1. Purpose

tramaj is a small expression language for constructing values and documents.

A program evaluates against a JSON-like environment and produces a value. Document-oriented programs produce a generic document tree (Node) which is interpreted by the host application.

The language deliberately keeps values and document construction expressive. It does not attempt to statically type or restrict the structures that programs may produce.

The language does, however, keep a small number of semantic names statically identifiable:

imports;
action keys;
action-key prefixes.

This makes dependencies and actions inspectable without requiring evaluation.

2. Evaluation model

The language is expression-oriented.

An expression evaluates to a runtime value. Values may represent:

JSON values;
functions/closures;
document nodes;
imported libraries or component-like values;
partially applied values.

The exact runtime representation is an implementation detail. Hosts may provide additional builtin operations and values.

Evaluation is generally strict: ordinary function arguments are evaluated before the function is invoked.

Language constructs which explicitly define control flow may evaluate only the branches they require.

3. Environments and paths

Variables are referenced with $:

$name
$ctx.user
$ctx.datasets.members

A path begins with a variable and may traverse object fields.

Field access may also be applied to the result of an expression:

$component.rendered
make-component(...).rendered

Field access is dynamically evaluated. The language does not require field names or resulting object shapes to be statically known.

Missing fields and invalid paths produce evaluation errors.

4. Values

The language works naturally with JSON-like values:

null
true
false
42
"hello"
[1, 2, 3]
{"name": "Alice", "age": 42}

Values may be bound and transformed:

@members = $ctx.members
@names = map($members, (member) => $member.name)

Bindings are lexical and are visible only after their declaration.

Functions are values:

@double = (x) => $x * 2

Functions capture their surrounding environment.

5. Functional operations

The language provides expression forms for common collection operations, including:

map(...)
filter(...)
scan(...)
fold(...)

These are language constructs rather than host-provided builtins.

They operate on values and produce values. Their results may subsequently be used anywhere an expression is accepted.

The builtin namespace is separate from these core language forms.

6. Builtins

Hosts may provide additional builtin functions.

The language does not restrict the builtin vocabulary or attempt to understand the semantics of host-provided builtins.

For example, a host may provide:

database-query(...)
translate(...)
asset-url(...)
current-user(...)

The language implementation is responsible only for evaluating the call according to the host-provided builtin definition.

This is intentional: tramaj is designed to be embeddable.

7. Documents

A document template constructs a generic Node tree.

The document syntax is structural:

.div(
  .h1("Hello"),
  .p("Welcome")
)

Attributes and children are expressed directly in the document syntax.

Expressions may be embedded wherever values are accepted:

.ul(
  map($items, (item) =>
    .li($item.name)
  )
)

The language does not define HTML as its document model.

A Node is an abstract document value. The host decides how to interpret or render it.

A host may render nodes as:

HTML;
a UI framework's virtual DOM;
another document representation;
or any other suitable target.

The language therefore places no artificial restriction on the document structures a program may construct.

8. Expression-rooted templates

A template may also have an expression as its root.

For example:

{
  "format": "json",
  "contents": {
    "name": $name,
    "members": $members
  }
}

Expression-rooted templates are useful when the desired result is structured data rather than a document.

The same expression language is used in both expression-rooted and document-rooted templates.

9. Imports

Imports are statically named dependencies.

An import identifies a library by a literal name:

import("components")

The library name is part of the program's static dependency information.

Import resolution is a host concern. The host determines what a library name refers to and supplies the corresponding library to the evaluator.

Imports may expose values and reusable document-producing functionality.

The language does not require the contents or results of an imported library to be statically known.

Import cycles

Implementations must detect import cycles rather than recursively evaluating them indefinitely.

10. Partial imports and reusable components

Libraries may provide reusable document-producing values.

A partial import may produce a value that is applied later:

@button = partial-import("button")
$button({
  "title": "Save"
})

Partial values may retain arguments or context until sufficient information is available to produce their final result.

This mechanism is intentionally compositional: reusable document-producing functionality is represented as a value and can be passed through the expression language.

11. Actions

Actions attach host-interpreted interaction metadata to document nodes.

An action has:

event
key
payload

For example:

action(
  "on-click",
  "save",
  {"id": $item.id}
)

The payload is an ordinary dynamically computed value.

The action key is different: it is a semantic identifier and must be statically known.

An action key therefore cannot be produced by an arbitrary runtime function.

This allows hosts and tooling to determine the vocabulary of actions a template may emit without executing the template.

12. Action adaptation

A component may adapt the action keys produced by a child component.

Action adaptation is deliberately restricted to either:

identity/no prefix;
adding a statically known prefix.

For example:

adapt-actions($component, "user:")

turns:

save
delete
open

into:

user:save
user:delete
user:open

No arbitrary key-rewriting function is permitted.

If a component produces the statically identifiable action-key set:

{a₁, a₂, ...}

then applying prefix p produces:

{p + a₁, p + a₂, ...}

This restriction preserves static action vocabulary while still allowing components to namespace their children's actions.

Action payloads remain fully dynamic.

13. Static names and dynamic values

The language intentionally distinguishes semantic names from computed values.

The following are statically identifiable:

import names;
action keys;
action-key prefixes.

The following remain dynamically evaluated:

JSON values;
function results;
field access;
builtin results;
document structure;
action payloads.

This is a deliberate design boundary.

The goal is not to make the entire language statically analyzable. The goal is to make important host-facing vocabularies inspectable while retaining an expressive dynamic language.

14. Control flow

Document templates may use conditional document construction.

A template-level branch evaluates only the selected branch rather than eagerly evaluating all alternatives.

This differs from an ordinary function call, whose arguments are evaluated before invocation.

This distinction is intentional and should be preserved by implementations.

15. Errors

Evaluation errors include, at minimum:

unbound variables;
unknown functions;
missing fields/paths;
type mismatches;
unknown libraries;
cyclic imports.

Implementations should report source locations where practical.

The exact diagnostic presentation is host-specific.

16. Host boundary

The language core does not prescribe:

how libraries are located;
how builtins are registered;
how Node values are rendered;
how actions are dispatched;
how document nodes are mapped to a UI framework;
how source files are loaded.

These are host responsibilities.

A host therefore supplies an environment around the language rather than changing the language itself.


17. Node serialization

The `Node` AST is a normative part of the Tramaj language specification. Every
`Node` MUST have a lossless JSON serialization defined by this specification,
and the JSON representation MUST contain all information necessary to
reconstruct an equivalent `Node`. Implementations MAY use any internal
representation of nodes, but conforming implementations MUST be able to produce
the specified JSON representation. This JSON format provides the portable
interchange boundary for document-oriented evaluation: an implementation may
therefore focus on parsing and evaluating Tramaj programs into the specified
`Node` representation, while hosts and other implementations may independently
deserialize and fold that representation into HTML, UI trees, configuration
formats, or other target systems. Runtime values such as closures and partial
templates are not required to be JSON-serializable; only completed `Node`
values are subject to this serialization contract.


18. Design principles

The language is intentionally small.

Its core principles are:

Expressions produce values.
Documents are values represented by a generic Node tree.
Document rendering is a host concern.
Functions and reusable document-producing values compose normally.
Values and document structures remain dynamically expressive.
Hosts may extend the builtin vocabulary.
Imports have statically known names.
Action keys have statically known names.
Action adaptation is limited to identity or static prefixing.
Static restrictions apply to host-facing semantic names, not to the language's general data and document model.

These principles are more important than any particular syntactic spelling. Syntax may evolve while preserving these semantics.
