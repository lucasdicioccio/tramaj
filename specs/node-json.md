# Tramaj — Normative Node JSON representation

The evaluated `Node` AST is the portable interchange boundary between Tramaj
implementations and their hosts. This document defines its **normative** JSON
representation.

An implementation MAY use any internal representation of nodes, but a conforming
implementation MUST be able to produce and consume the representation below
without loss: `decode(encode(n))` MUST yield a node equal to `n`.

Object key ordering is not semantically significant and MUST NOT be relied upon.

## Node AST

```text
Annotations = Map<String, JSON>

Node
  = Text
      value: Value
      annotations: Annotations

  | Element
      tag: String
      attributes: List<NodeAttribute>
      value: Value
      children: List<Node>
      annotations: Annotations

  | Fragment
      children: List<Node>
      annotations: Annotations

NodeAttribute
  = Attribute
      name: String
      value: Value

  | Action
      event: String
      key: String
      payload: Value
```

`Value` is the ordinary JSON value domain — `null`, boolean, number, string,
array, object. It is *not* a `Node`: a document tree never nests through an
attribute value, an element value slot, or an action payload.

`Text` carries a `Value`, not a `String`, so scalars survive evaluation without
implicit conversion: `.p($ctx.count)` with `count = 3` produces a text node whose
value is the number `3`, not the string `"3"`. A host that wants a string renders
one; the interchange format does not decide that for it.

`Element` carries a `value` slot alongside its children, for hosts whose target
format attaches a body value to a tagged node (a scalar leaf in YAML/HCL, a
configuration value, an editor model). It defaults to `null` when a template does
not set one.

`Fragment` is an ordered sequence of siblings introducing no wrapper element. It
is a real node in this representation; a host MAY flatten fragments when folding
into its own target.

## JSON encoding

Every object carries a discriminator: `"type"` for nodes, `"kind"` for attributes.
Every field listed is REQUIRED — including `"annotations"`, which is `{}` when a
node has none, and `"value"`, which is `null` when an element has no value slot.
An encoder MUST emit all of them; a decoder MUST reject an object missing any.

### Text

```json
{"type": "text", "value": 3, "annotations": {}}
```

```json
{"type": "text", "value": "hello", "annotations": {}}
```

### Element

```json
{
  "type": "element",
  "tag": "button",
  "attributes": [
    {"kind": "attribute", "name": "class", "value": "primary"},
    {"kind": "action", "event": "on-click", "key": "deploy",
     "payload": {"deployment": "web"}}
  ],
  "value": null,
  "children": [
    {"type": "text", "value": "Deploy", "annotations": {}}
  ],
  "annotations": {}
}
```

`attributes` is an ordered list, not a map: an element may carry any number of
attributes and any number of actions, and their source order is preserved.
Ordinary attributes and actions share one list because both are attribute-position
constructs; a host reading only one kind filters on `"kind"`.

An attribute `name` may repeat. The representation does not deduplicate; a host
decides what a repeated name means for its target.

### Fragment

```json
{
  "type": "fragment",
  "children": [
    {"type": "text", "value": "one", "annotations": {}},
    {"type": "text", "value": "two", "annotations": {}}
  ],
  "annotations": {}
}
```

## Annotations

`annotations` is a JSON object mapping annotation keys to arbitrary JSON.

The core language assigns no meaning to any key or value. Annotations are the
extension point for types, domains and constraints, provenance, host metadata, and
optimization hints.

Unknown annotations MUST NOT affect core semantics, and implementations MUST
preserve them across every node-to-node transformation they perform —
`adapt-actions` in particular copies a node's annotations through unchanged.

## Decoding

A decoder MUST reject:

- an object with no `"type"`, or a `"type"` outside `{text, element, fragment}`;
- an attribute with no `"kind"`, or a `"kind"` outside `{attribute, action}`;
- any object missing a field required for its discriminator;
- a non-string `tag`, `name`, `event`, or `key`;
- a non-array `attributes` or `children`, or a non-object `annotations`.

A decoder MUST NOT infer a missing field from a default. Defaults are an encoder's
job; on the wire the representation is explicit, so that a missing field is a bug
rather than a silent `null`.
