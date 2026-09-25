"""``specs/node-json.md``'s round-trip law and its explicit list of things a
decoder MUST reject. The corpus only ever exercises the encoder, since it
compares encoded output."""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tramaj.node import (  # noqa: E402
    ActionAttr,
    AttributeAttr,
    ElementNode,
    FragmentNode,
    NodeDecodeError,
    TextNode,
    node_from_json,
    node_to_json,
)

SAMPLE = ElementNode(
    "button",
    [
        AttributeAttr("class", "primary"),
        ActionAttr("on-click", "deploy", {"deployment": "web"}),
    ],
    None,
    [TextNode(3, {}), FragmentNode([TextNode("a", {})], {})],
    {"origin": "test"},
)

REJECTED = [
    ("no type", {"value": 1, "annotations": {}}),
    ("unknown type", {"type": "comment", "annotations": {}}),
    ("text with no value", {"type": "text", "annotations": {}}),
    ("text with no annotations", {"type": "text", "value": 1}),
    ("non-object annotations", {"type": "text", "value": 1, "annotations": []}),
    ("non-string tag", {"type": "element", "tag": 1, "attributes": [], "value": None, "children": [], "annotations": {}}),
    ("non-array attributes", {"type": "element", "tag": "p", "attributes": {}, "value": None, "children": [], "annotations": {}}),
    ("non-array children", {"type": "element", "tag": "p", "attributes": [], "value": None, "children": {}, "annotations": {}}),
    ("element with no value slot", {"type": "element", "tag": "p", "attributes": [], "children": [], "annotations": {}}),
    ("fragment with no children", {"type": "fragment", "annotations": {}}),
    ("attribute with no kind", {"type": "element", "tag": "p", "attributes": [{"name": "a", "value": 1}], "value": None, "children": [], "annotations": {}}),
    ("unknown attribute kind", {"type": "element", "tag": "p", "attributes": [{"kind": "prop", "name": "a", "value": 1}], "value": None, "children": [], "annotations": {}}),
    ("attribute with no value", {"type": "element", "tag": "p", "attributes": [{"kind": "attribute", "name": "a"}], "value": None, "children": [], "annotations": {}}),
    ("action with no payload", {"type": "element", "tag": "p", "attributes": [{"kind": "action", "event": "e", "key": "k"}], "value": None, "children": [], "annotations": {}}),
    ("non-string action key", {"type": "element", "tag": "p", "attributes": [{"kind": "action", "event": "e", "key": 1, "payload": None}], "value": None, "children": [], "annotations": {}}),
    ("not an object at all", "text"),
]


class NodeJsonTest(unittest.TestCase):
    def test_round_trip(self):
        self.assertEqual(node_from_json(node_to_json(SAMPLE)), SAMPLE)

    def test_encodes_every_required_field(self):
        self.assertEqual(
            node_to_json(ElementNode("p", [], None, [], {})),
            {"type": "element", "tag": "p", "attributes": [], "value": None, "children": [], "annotations": {}},
        )

    def test_rejects(self):
        for label, value in REJECTED:
            with self.subTest(label):
                with self.assertRaises(NodeDecodeError):
                    node_from_json(value)

    def test_does_not_infer_a_missing_field_from_a_default(self):
        with self.assertRaisesRegex(NodeDecodeError, "annotations"):
            node_from_json({"type": "text", "value": 1})
        with self.assertRaisesRegex(NodeDecodeError, "value"):
            node_from_json({"type": "element", "tag": "p", "attributes": [], "children": [], "annotations": {}})

    def test_preserves_duplicate_attribute_names_and_their_order(self):
        n = ElementNode("p", [AttributeAttr("data-x", 1), AttributeAttr("data-x", 2)], None, [], {})
        self.assertEqual(node_from_json(node_to_json(n)), n)


if __name__ == "__main__":
    unittest.main()
