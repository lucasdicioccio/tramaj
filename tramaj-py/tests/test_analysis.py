"""``specs/reference.md`` section 9's analyses, which the corpus never reaches:
it drives ``run_program`` only. Plus the ``str`` number rendering the language
pins to ECMAScript's ``Number::toString``."""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tramaj.analysis import (  # noqa: E402
    constraint_kinds,
    context_holes,
    context_reads,
    deep_action_keys,
    program_card,
    static_action_keys,
    static_import_names,
    symbol_sites,
    transitive_import_names,
    unsupplied_params,
)
from tramaj.jsonval import format_number  # noqa: E402
from tramaj.parser import parse_program  # noqa: E402


class AnalysisTest(unittest.TestCase):
    def test_action_keys_with_adaptation_applied(self):
        prog = parse_program(
            'adapt-actions(.div(action("on-click", "save", {}), action("on-click", "delete", {})), prefix("user:"))'
        )
        self.assertEqual(static_action_keys(prog), ["user:delete", "user:save"])

    def test_adaptations_compose(self):
        prog = parse_program(
            'adapt-actions(adapt-actions(.div(action("on-click", "k", {})), prefix("a:")), prefix("b:"))'
        )
        self.assertEqual(static_action_keys(prog), ["b:a:k"])

    def test_does_not_follow_a_binding_through_an_adaptation(self):
        prog = parse_program('@p=.div(action("on-click", "k", {}))\nadapt-actions($p, prefix("a:"))')
        self.assertEqual(static_action_keys(prog), ["k"])

    def test_deep_action_keys_follow_imports(self):
        libs = {"row": parse_program('.li(action("on-click", "pick", {}))')}
        prog = parse_program('.ul(import("row", {}).rendered, import("gone", {}).rendered)')
        self.assertEqual(deep_action_keys(libs, prog), ["pick"])
        self.assertEqual(static_import_names(prog), ["gone", "row"])
        self.assertEqual(transitive_import_names(libs, prog), ["gone", "row"])

    def test_context_holes_versus_reads(self):
        prog = parse_program('import("panel", {name: ctx(title), n: $ctx.count})')
        self.assertEqual(context_holes(prog), [["title"]])
        self.assertEqual(context_reads(prog), [["count"], ["title"]])

    def test_unsupplied_params(self):
        libs = {"panel": parse_program(".section(.h1($ctx.title), .p($ctx.body.text))")}
        prog = parse_program('import("panel", {"title": "x"}).rendered')
        self.assertEqual(unsupplied_params(libs, prog), [("panel", [["body", "text"]])])
        self.assertEqual(unsupplied_params({}, parse_program('import("gone", {}).rendered')), [("gone", [])])

    def test_constraint_kinds_and_allocation_sites(self):
        prog = parse_program('!constraint("positive", $ctx.n)\n[?("a"), ?("b")]')
        self.assertEqual(constraint_kinds(prog), ["positive"])
        self.assertEqual(symbol_sites(prog), [0, 1])

    def test_card(self):
        libs = {"row": parse_program('.li(action("on-click", "pick", $ctx.id))')}
        prog = parse_program('.ul(map($ctx.items, (i) => import("row", {}).rendered))')
        self.assertEqual(
            program_card(libs, prog),
            {
                "produces": "document",
                "requires": [["items"]],
                "imports": ["row"],
                "emits": ["pick"],
                "unsupplied": [("row", [["id"]])],
            },
        )


class NumberFormatTest(unittest.TestCase):
    def test_renders_like_ecmascript(self):
        cases = [
            (0, "0"), (1, "1"), (-2.0, "-2"), (1.5, "1.5"), (0.1 + 0.2, "0.30000000000000004"),
            (1e21, "1e+21"), (1e20, "100000000000000000000"), (1e-7, "1e-7"), (0.000001, "0.000001"),
            (123456789012345680000, "123456789012345680000"), (2**53, "9007199254740992"),
            (1.7976931348623157e308, "1.7976931348623157e+308"), (5e-324, "5e-324"), (-1.5e-9, "-1.5e-9"),
        ]
        for n, s in cases:
            with self.subTest(n=n):
                self.assertEqual(format_number(n), s)


if __name__ == "__main__":
    unittest.main()
