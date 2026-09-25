"""``Node``/``NodeAttribute`` and the strict ``specs/node-json.md`` encode/decode,
hand-written so the "a decoder MUST reject ... MUST NOT infer a missing field
from a default" rules are enforced exactly."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Union

from .jsonval import Json

Annotations = dict


def no_annotations() -> Annotations:
    return {}


@dataclass
class TextNode:
    value: Json
    annotations: Annotations = field(default_factory=dict)
    t: str = field(default="text", init=False)


@dataclass
class ElementNode:
    tag: str
    attributes: list["NodeAttribute"]
    value: Json
    children: list["Node"]
    annotations: Annotations = field(default_factory=dict)
    t: str = field(default="element", init=False)


@dataclass
class FragmentNode:
    children: list["Node"]
    annotations: Annotations = field(default_factory=dict)
    t: str = field(default="fragment", init=False)


Node = Union[TextNode, ElementNode, FragmentNode]


@dataclass
class AttributeAttr:
    name: str
    value: Json
    t: str = field(default="attribute", init=False)


@dataclass
class ActionAttr:
    event: str
    key: str
    payload: Json
    t: str = field(default="action", init=False)


NodeAttribute = Union[AttributeAttr, ActionAttr]


def text_node(value: Json, annotations: Annotations | None = None) -> Node:
    return TextNode(value, {} if annotations is None else annotations)


def element_node(
    tag: str,
    attributes: list[NodeAttribute],
    value: Json,
    children: list[Node],
    annotations: Annotations | None = None,
) -> Node:
    return ElementNode(tag, attributes, value, children, {} if annotations is None else annotations)


def fragment_node(children: list[Node], annotations: Annotations | None = None) -> Node:
    return FragmentNode(children, {} if annotations is None else annotations)


def node_to_json(n: Node) -> Json:
    if n.t == "text":
        return {"type": "text", "value": n.value, "annotations": dict(n.annotations)}
    if n.t == "element":
        return {
            "type": "element",
            "tag": n.tag,
            "attributes": [node_attribute_to_json(a) for a in n.attributes],
            "value": n.value,
            "children": [node_to_json(c) for c in n.children],
            "annotations": dict(n.annotations),
        }
    return {
        "type": "fragment",
        "children": [node_to_json(c) for c in n.children],
        "annotations": dict(n.annotations),
    }


def node_attribute_to_json(a: NodeAttribute) -> Json:
    if a.t == "attribute":
        return {"kind": "attribute", "name": a.name, "value": a.value}
    return {"kind": "action", "event": a.event, "key": a.key, "payload": a.payload}


class NodeDecodeError(Exception):
    pass


def _req(what: str, fieldname: str, obj: dict) -> Json:
    if fieldname not in obj:
        raise NodeDecodeError(f'{what}: missing required field "{fieldname}"')
    return obj[fieldname]


def _req_string(what: str, fieldname: str, obj: dict) -> str:
    v = _req(what, fieldname, obj)
    if not isinstance(v, str):
        raise NodeDecodeError(f'{what}: field "{fieldname}" must be a string')
    return v


def _req_array(what: str, fieldname: str, obj: dict) -> list:
    v = _req(what, fieldname, obj)
    if not isinstance(v, list):
        raise NodeDecodeError(f'{what}: field "{fieldname}" must be an array')
    return v


def _req_annotations(obj: dict) -> Annotations:
    v = _req("node", "annotations", obj)
    if not isinstance(v, dict):
        raise NodeDecodeError('node: field "annotations" must be an object')
    return dict(v)


def node_from_json(v: Json) -> Node:
    if not isinstance(v, dict):
        raise NodeDecodeError("expected a JSON object for a node")
    typ = _req_string("node", "type", v)
    if typ == "text":
        return TextNode(_req("text node", "value", v), _req_annotations(v))
    if typ == "element":
        return ElementNode(
            _req_string("element node", "tag", v),
            [node_attribute_from_json(a) for a in _req_array("element node", "attributes", v)],
            _req("element node", "value", v),
            [node_from_json(c) for c in _req_array("element node", "children", v)],
            _req_annotations(v),
        )
    if typ == "fragment":
        return FragmentNode(
            [node_from_json(c) for c in _req_array("fragment node", "children", v)],
            _req_annotations(v),
        )
    raise NodeDecodeError(f'unknown node type: "{typ}"')


def node_attribute_from_json(v: Json) -> NodeAttribute:
    if not isinstance(v, dict):
        raise NodeDecodeError("expected a JSON object for a node attribute")
    kind = _req_string("node attribute", "kind", v)
    if kind == "attribute":
        return AttributeAttr(_req_string("attribute", "name", v), _req("attribute", "value", v))
    if kind == "action":
        return ActionAttr(
            _req_string("action", "event", v),
            _req_string("action", "key", v),
            _req("action", "payload", v),
        )
    raise NodeDecodeError(f'unknown node attribute kind: "{kind}"')


def map_actions(n: Node, f: Callable[[str, str, Json], NodeAttribute]) -> Node:
    """Rewrites every action reachable in a tree, leaving everything else untouched."""
    if n.t == "text":
        return n
    if n.t == "element":
        return ElementNode(
            n.tag,
            [f(a.event, a.key, a.payload) if a.t == "action" else a for a in n.attributes],
            n.value,
            [map_actions(c, f) for c in n.children],
            n.annotations,
        )
    return FragmentNode([map_actions(c, f) for c in n.children], n.annotations)
