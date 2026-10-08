"""``specs/node-json.md``'s round-trip law and its explicit list of things a
decoder MUST reject. The corpus only ever exercises the encoder, since it
compares encoded output."""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tramaj.jsonval import compact_json, json_equal, parse_json  # noqa: E402
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


class NumbersTest(unittest.TestCase):
    """node-json.md, *Numbers*: the encoding keeps the type of a number, and a
    decoder refuses the numbers the value domain does not hold."""

    @staticmethod
    def text(value):
        return {"type": "text", "value": value, "annotations": {}}

    def test_an_integer_and_a_float_are_two_nodes(self):
        three = node_from_json(self.text(3))
        three_float = node_from_json(self.text(3.0))
        self.assertIs(type(three.value), int)
        self.assertIs(type(three_float.value), float)
        self.assertFalse(json_equal(node_to_json(three), node_to_json(three_float)))
        self.assertEqual(compact_json(node_to_json(three_float)), '{"annotations":{},"type":"text","value":3.0}')

    def test_round_trips_through_text_with_the_types_kept(self):
        node = ElementNode("p", [AttributeAttr("n", [1, 1.0, 1e21, 2**63 - 1])], 0.5, [TextNode(-7)], {})
        text = compact_json(node_to_json(node))
        self.assertIn("[1,1.0,1e+21,9223372036854775807]", text)
        back = node_to_json(node_from_json(parse_json(text)))
        self.assertTrue(json_equal(back, node_to_json(node)))

    def test_an_integer_outside_the_64_bit_range_is_rejected_not_rounded(self):
        for n in (2**63, -(2**63) - 1):
            with self.subTest(n=n), self.assertRaises(NodeDecodeError):
                node_from_json(self.text({"deep": [n]}))
        self.assertEqual(node_from_json(self.text(2**63 - 1)).value, 2**63 - 1)
        self.assertEqual(node_from_json(self.text(-(2**63))).value, -(2**63))

    def test_a_float_too_large_for_a_double_is_rejected(self):
        with self.assertRaises(NodeDecodeError):
            node_from_json(parse_json('{"type": "text", "value": 1e400, "annotations": {}}'))

    def test_a_negative_zero_float_decodes_as_zero(self):
        value = node_from_json(parse_json('{"type": "text", "value": -0.0, "annotations": {}}')).value
        self.assertEqual(repr(value), "0.0")

    def test_numbers_are_checked_in_every_value_position(self):
        big = 2**64
        attribute = {"kind": "attribute", "name": "a", "value": big}
        action = {"kind": "action", "event": "e", "key": "k", "payload": {"n": big}}
        for attr in (attribute, action):
            with self.subTest(kind=attr["kind"]), self.assertRaises(NodeDecodeError):
                node_from_json(
                    {"type": "element", "tag": "p", "attributes": [attr], "value": None, "children": [], "annotations": {}}
                )
        with self.assertRaises(NodeDecodeError):
            node_from_json(
                {"type": "element", "tag": "p", "attributes": [], "value": big, "children": [], "annotations": {}}
            )


if __name__ == "__main__":
    unittest.main()
