"""``specs/reference.md`` section 9's analyses, which the corpus never reaches:
it reaches only the ones an ``"expect": "analysis"`` case names. Plus the
number rendering of ``str`` and of JSON output, which keeps the type: an
integer as its digits, a float by ECMAScript's ``Number::toString`` with a
fraction or an exponent always present."""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tramaj.analysis import (  # noqa: E402
    ARITHMETIC_NAMES,
    arithmetic_ops,
    constraint_kinds,
    context_holes,
    context_reads,
    deep_action_keys,
    deep_arithmetic_ops,
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


class ArithmeticOpsTest(unittest.TestCase):
    def test_the_profile_has_ten_names_and_round_is_one(self):
        self.assertEqual(len(ARITHMETIC_NAMES), 10)
        self.assertIn("round", ARITHMETIC_NAMES)

    def test_called_and_passed_by_reference(self):
        prog = parse_program("[sum(1, 2), fold($ctx.xs, 1, $product), floor-quotient(7, 2)]")
        self.assertEqual(arithmetic_ops(prog), ["floor-quotient", "product", "sum"])

    def test_a_shadowed_name_is_not_reported(self):
        self.assertEqual(arithmetic_ops(parse_program("@sum=(a, b) => $a\nsum(1, 2)")), [])
        self.assertEqual(arithmetic_ops(parse_program("map($ctx.xs, (negate) => $negate)")), [])
        self.assertEqual(arithmetic_ops(parse_program("@{floor}=$ctx\n$floor")), [])

    def test_a_binding_is_out_of_scope_in_its_own_value(self):
        self.assertEqual(arithmetic_ops(parse_program("@sum=sum(1, 2)\n$sum")), ["sum"])

    def test_a_name_outside_the_profile_is_not_reported(self):
        self.assertEqual(arithmetic_ops(parse_program('[ceiling(1.5), eq(1, 2), format-number(1, 0, "")]')), [])

    def test_deep_follows_imports_and_a_library_has_its_own_scope(self):
        libs = {"lib": parse_program("real($ctx.n)"), "other": parse_program("modulo(1, 2)")}
        prog = parse_program('@real=1\n[negate(1), import("lib", {n: 1}).rendered]')
        self.assertEqual(arithmetic_ops(prog), ["negate"])
        self.assertEqual(deep_arithmetic_ops(libs, prog), ["negate", "real"])


class NumberFormatTest(unittest.TestCase):
    def test_an_integer_is_its_digits_and_a_float_keeps_a_fraction_or_an_exponent(self):
        cases = [
            (0, "0"), (1, "1"), (-7, "-7"), (100000000000, "100000000000"),
            (2**53, "9007199254740992"), (2**63 - 1, "9223372036854775807"), (-(2**63), "-9223372036854775808"),
            (0.0, "0.0"), (1.0, "1.0"), (-2.0, "-2.0"), (1.5, "1.5"), (0.1 + 0.2, "0.30000000000000004"),
            (100000000000.0, "100000000000.0"), (1e21, "1e+21"), (1e20, "100000000000000000000.0"),
            (1e-7, "1e-7"), (0.000001, "0.000001"), (0.05, "0.05"),
            (1.7976931348623157e308, "1.7976931348623157e+308"), (5e-324, "5e-324"), (-1.5e-9, "-1.5e-9"),
        ]
        for n, s in cases:
            with self.subTest(n=n):
                self.assertEqual(format_number(n), s)


if __name__ == "__main__":
    unittest.main()
