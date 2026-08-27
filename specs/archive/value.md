# Tramaj — Node AST

The evaluated document representation is a normative, JSON-serializable
abstract syntax tree. It is independent of any particular output format or
host system.

A `Node` is:

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


NodeAttribute
  = Attribute
      name: String
      value: Value

  | Action
      event: String
      key: String
      payload: Value
Semantics

Null, Boolean, Number, and Text represent scalar values without
implicit conversion.

Element represents a tagged document node. Its tag name, attributes, and
children have no intrinsic HTML-specific semantics. Their interpretation is
left to the host.

Fragment represents an ordered sequence of sibling nodes without introducing
a wrapper element.

Document-valued expressions evaluate to Node values. Consequently, a
fragment is an ordinary value and may be passed to, returned from, or bound
within functions and templates.

Hosts may fold a Node into any target representation, including HTML, UI
trees, YAML, HCL, JSON, or other structured output formats.

Annotations

Every Node constructor carries an Annotations map.

The core language assigns no semantics to annotation keys or values.

Annotations provide an explicit extension point for future language features,
including but not limited to:

types;
domains and constraints;
provenance;
host-specific metadata;
optimization hints;
additional semantic information.

Unknown annotations do not affect core Tramaj semantics.

Implementations SHOULD preserve annotations when copying or transforming nodes,
including annotations they do not understand.

The annotation representation is intentionally opaque to the current core
semantics. Future specifications may define particular annotation namespaces
or keys without requiring a change to the Node constructors.

JSON serialization

The complete Node AST is JSON-serializable. Its JSON representation is part
of the Tramaj specification and is the portable interchange representation
between implementations.

An implementation MAY use any internal representation, but MUST be able to
produce and consume the normative JSON representation without loss of
semantic information.

Object key ordering in the JSON representation is not semantically
significant and MUST NOT be relied upon by Tramaj programs.
