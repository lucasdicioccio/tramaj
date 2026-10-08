"""The two number types (``specs/reference.md`` sections 3, 5, 6 and 13), the
integer range this port provides, and the arithmetic profile (section 11) as a
per-evaluation option. The shared corpus covers the language rules case by
case; these tests cover what is this port's own: the Python binding of the
two types, the range check on Python's unbounded integers, the option's
default, and the command line."""

from __future__ import annotations

import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tramaj.__main__ import main  # noqa: E402
from tramaj.evaluator import EvalError, run_program  # noqa: E402
from tramaj.jsonval import (  # noqa: E402
    MAX_INTEGER,
    MIN_INTEGER,
    compact_json,
    json_equal,
    parse_json,
    pretty_json,
)
from tramaj.parser import ParseError, parse_program  # noqa: E402


def run(src: str, ctx=None, mode: str = "concrete", arithmetic: bool = False):
    return run_program(mode, {}, ctx, parse_program(src), arithmetic=arithmetic)


def error_kind(src: str, ctx=None, mode: str = "concrete", arithmetic: bool = False) -> str:
    try:
        run(src, ctx, mode, arithmetic)
    except EvalError as e:
        return e.kind
    raise AssertionError(f"{src} evaluated")


class IntegerRangeTest(unittest.TestCase):
    """This port provides the signed 64-bit range (``int64``)."""

    def test_the_range_is_the_signed_64_bit_one(self):
        self.assertEqual(MIN_INTEGER, -(2**63))
        self.assertEqual(MAX_INTEGER, 2**63 - 1)

    def test_a_literal_at_either_end_is_held_exactly(self):
        self.assertEqual(run("9223372036854775807"), 2**63 - 1)
        self.assertEqual(run("-9223372036854775808"), -(2**63))
        self.assertEqual(run("str(9007199254740993)"), "9007199254740993")

    def test_a_literal_past_either_end_is_a_parse_error(self):
        for src in ("9223372036854775808", "-9223372036854775809", "1" + "0" * 30):
            with self.subTest(src=src), self.assertRaises(ParseError):
                parse_program(src)

    def test_a_context_integer_outside_the_range_is_refused_not_rounded(self):
        for n in (2**63, -(2**63) - 1, 10**40):
            with self.subTest(n=n):
                # Decoded whole: the program does not read the number.
                self.assertEqual(error_kind("1", {"deep": [{"n": n}]}), "TypeMismatch")
        self.assertEqual(run("$ctx.n", {"n": 2**63 - 1}), 2**63 - 1)

    def test_a_result_outside_the_range_is_not_representable(self):
        for src in (
            "sum(9223372036854775807, 1)",
            "sum(9223372036854775807, 1, -1)",
            "product(4294967296, 4294967296, 0)",
            "negate(-9223372036854775808)",
            "floor-quotient(-9223372036854775808, -1)",
            "floor(1e19)",
        ):
            with self.subTest(src=src):
                self.assertEqual(error_kind(src, arithmetic=True), "NotRepresentable")
        self.assertEqual(run("modulo(-9223372036854775808, -1)", arithmetic=True), 0)
        self.assertEqual(run("sum(9223372036854775806, 1)", arithmetic=True), 2**63 - 1)
        self.assertEqual(run("floor(1e16)", arithmetic=True), 10**16)

    def test_real_rounds_an_integer_beyond_2_53_to_nearest_ties_to_even(self):
        self.assertEqual(run("real(9007199254740993)", arithmetic=True), 9007199254740992.0)
        self.assertEqual(run("real(9007199254740995)", arithmetic=True), 9007199254740996.0)


class NumberSplitTest(unittest.TestCase):
    def test_the_form_of_a_literal_decides_its_type(self):
        for src, want in (("1", int), ("-7", int), ("1_000", int), ("-0", int), ("1.0", float), ("1e5", float)):
            with self.subTest(src=src):
                self.assertIs(type(run(src)), want)

    def test_there_is_no_negative_zero(self):
        self.assertEqual(repr(run("-0.0")), "0.0")
        self.assertEqual(repr(run("-1e-400")), "0.0")
        self.assertEqual(repr(run("$ctx", -0.0)), "0.0")
        self.assertEqual(repr(run("negate(0.0)", arithmetic=True)), "0.0")

    def test_a_float_literal_too_large_is_a_parse_error(self):
        with self.assertRaises(ParseError):
            parse_program("1e400")

    def test_a_context_number_has_the_type_of_its_python_value(self):
        self.assertEqual(run("[str($ctx.a), str($ctx.b)]", {"a": 3, "b": 3.0}), ["3", "3.0"])
        self.assertEqual(run("eq($ctx.a, $ctx.b)", {"a": 3, "b": 3.0}), False)

    def test_a_non_finite_context_float_is_refused(self):
        for x in (float("inf"), float("-inf"), float("nan")):
            with self.subTest(x=x):
                self.assertEqual(error_kind("1", [x]), "TypeMismatch")

    def test_a_bool_is_not_an_integer(self):
        self.assertIs(run("$ctx", True), True)
        self.assertEqual(error_kind("sum($ctx.b, 1)", {"b": True}, arithmetic=True), "TypeMismatch")

    def test_a_mixed_comparison_is_a_type_mismatch(self):
        self.assertEqual(error_kind("gt(1.5, 0)"), "TypeMismatch")
        self.assertIs(run("gt(1.5, 0.0)"), True)
        self.assertIs(run("lt(1, 2)"), True)

    def test_a_float_is_not_an_index(self):
        self.assertEqual(run('[has(["a"], 0), has(["a"], 0.0), lookup(["a"], 0.0, "no")]'), [True, False, "no"])

    def test_cardinality_is_an_integer(self):
        self.assertIs(type(run("cardinality([1, 2])")), int)

    def test_number_is_no_longer_a_primitive_type(self):
        self.assertEqual(error_kind("@x : number = 1\n$x"), "TypeErr")
        self.assertEqual(run("@x : int = 1\n@y : float = 1.0\n[$x, $y]"), [1, 1.0])

    def test_json_equal_keeps_the_two_types_apart(self):
        self.assertFalse(json_equal(1, 1.0))
        self.assertFalse(json_equal([{"n": 1}], [{"n": 1.0}]))
        self.assertTrue(json_equal(1.0, 1.0))
        self.assertFalse(json_equal(1, True))


class JsonTextTest(unittest.TestCase):
    def test_parse_json_types_a_number_by_its_text(self):
        v = parse_json('[3, 3.0, 3e0, -0, 9223372036854775807, 123456789012345678901234567890]')
        self.assertEqual([type(x) for x in v], [int, float, float, int, int, int])
        self.assertEqual(v[4], 2**63 - 1)
        self.assertEqual(v[5], 123456789012345678901234567890)

    def test_parse_json_refuses_what_is_not_json(self):
        for text in ("NaN", "[Infinity]", "-Infinity", "{"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_json(text)

    def test_a_number_too_large_is_refused_by_the_evaluator_not_the_reader(self):
        self.assertEqual(error_kind("1", parse_json('{"n": 1e400}')), "TypeMismatch")
        self.assertEqual(error_kind("1", parse_json('{"n": 9223372036854775808}')), "TypeMismatch")
        self.assertEqual(repr(run("$ctx.n", parse_json('{"n": 1e-400}'))), "0.0")

    def test_output_text_reads_back_with_its_types(self):
        out = run("[1, 1.0, 100000000000.0, 1e21, 0.1]")
        for text in (compact_json(out), pretty_json(out)):
            with self.subTest(text=text):
                self.assertTrue(json_equal(parse_json(text), out))
        self.assertEqual(compact_json(out), "[1,1.0,100000000000.0,1e+21,0.1]")


class ArithmeticProfileTest(unittest.TestCase):
    def test_the_profile_is_off_by_default(self):
        prog = parse_program("sum(1, 2)")
        with self.assertRaises(EvalError) as raised:
            run_program("concrete", {}, None, prog)
        self.assertEqual(raised.exception.kind, "UnboundName")
        self.assertEqual(run_program("concrete", {}, None, prog, arithmetic=True), 3)

    def test_the_option_is_per_evaluation(self):
        prog = parse_program("product(2, 3)")
        self.assertEqual(run_program("concrete", {}, None, prog, arithmetic=True), 6)
        with self.assertRaises(EvalError):
            run_program("concrete", {}, None, prog)

    def test_round_is_not_bound_by_the_profile(self):
        self.assertEqual(error_kind("round(1.5)", arithmetic=True), "UnboundName")

    def test_a_library_follows_the_option_of_the_evaluation(self):
        libs = {"lib": parse_program("sum($ctx.n, 1)")}
        prog = parse_program('import("lib", {n: 1}).rendered')
        self.assertEqual(run_program("concrete", libs, None, prog, arithmetic=True), 2)
        with self.assertRaises(EvalError) as raised:
            run_program("concrete", libs, None, prog)
        self.assertEqual(raised.exception.kind, "InLibrary")
        self.assertEqual(raised.exception.cause.kind, "UnboundName")

    def test_a_program_may_bind_one_of_the_names(self):
        self.assertEqual(run('@sum = "mine"\n$sum'), "mine")
        self.assertEqual(run('@sum = "mine"\n$sum', arithmetic=True), "mine")

    def test_floats_are_one_rounded_operation_at_a_time(self):
        self.assertEqual(run("sum(0.1, 0.2, 0.3)", arithmetic=True), 0.6000000000000001)
        self.assertEqual(run("product(49.0, inverse(49.0))", arithmetic=True), 0.9999999999999999)
        self.assertEqual(run("quotient(49.0, 49.0)", arithmetic=True), 1.0)

    def test_a_zero_divisor_is_not_representable(self):
        for src in ("inverse(0.0)", "quotient(1.0, 0.0)", "quotient(0.0, 0.0)", "floor-quotient(1, 0)", "modulo(1, 0)"):
            with self.subTest(src=src):
                self.assertEqual(error_kind(src, arithmetic=True), "NotRepresentable")

    def test_a_type_mismatch_takes_precedence(self):
        self.assertEqual(error_kind('sum(1e308, 1e308, "a")', arithmetic=True), "TypeMismatch")
        self.assertEqual(error_kind("sum(1e308, 1e308)", arithmetic=True), "NotRepresentable")

    def test_a_term_is_built_over_a_symbol_and_keeps_the_type_of_each_number(self):
        out = run('@s = ?("s")\nsum(1, [$s, 2])', mode="symbolic", arithmetic=True)
        sym = {"$sym": '#0:"s"', "path": []}
        self.assertTrue(json_equal(out["root"], {"$term": "sum", "arguments": [1, sym, 2]}))
        out = run('@s = ?("s")\nproduct(1.0, $s)', mode="symbolic", arithmetic=True)
        self.assertEqual(compact_json(out["root"]["arguments"][0]), "1.0")

    def test_a_seeded_term_needs_the_profile(self):
        term = {"t": {"$term": "sum", "arguments": [1, {"$sym": "#ctx.s", "path": []}]}}
        self.assertTrue(json_equal(run("$ctx.t", term, "symbolic", True)["root"], term["t"]))
        self.assertEqual(error_kind("1", term, "symbolic", False), "TypeMismatch")
        self.assertEqual(error_kind("1", term, "concrete", True), "TypeMismatch")
        rounded = {"$term": "round", "arguments": [{"$sym": "#ctx.s", "path": []}]}
        self.assertEqual(error_kind("1", rounded, "symbolic", True), "TypeMismatch")

    def test_the_residual_law_on_one_program(self):
        src = "floor-quotient(product(100, ?ctx.used), 7)"
        term = run(src, {}, "symbolic", True)["root"]
        self.assertEqual(term["$term"], "floor-quotient")
        self.assertEqual(run(src, {"used": 3}, "symbolic", True)["root"], 42)


class CommandLineTest(unittest.TestCase):
    def cli(self, template: str, context: str, *flags: str):
        with tempfile.TemporaryDirectory() as d:
            t, c = os.path.join(d, "t.tramaj"), os.path.join(d, "ctx.json")
            with open(t, "w", encoding="utf-8") as f:
                f.write(template)
            with open(c, "w", encoding="utf-8") as f:
                f.write(context)
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = main([*flags, t, c])
            return code, out.getvalue(), err.getvalue()

    def test_the_context_file_keeps_the_type_of_each_number(self):
        code, out, _ = self.cli("[$ctx.a, $ctx.b]", '{"a": 3, "b": 3.0}')
        self.assertEqual(code, 0)
        self.assertEqual(out, "[\n  3,\n  3.0\n]\n")

    def test_arithmetic_is_off_without_the_flag_and_the_error_says_so(self):
        code, _, err = self.cli("sum($ctx.a, 1)", '{"a": 3}')
        self.assertEqual(code, 1)
        self.assertIn("UnboundName", err)
        self.assertIn("--arithmetic", err)
        code, out, _ = self.cli("sum($ctx.a, 1)", '{"a": 3}', "--arithmetic")
        self.assertEqual((code, out), (0, "4\n"))

    def test_a_context_number_the_value_domain_does_not_hold_is_an_eval_error(self):
        code, _, err = self.cli("1", '{"n": 1e400}')
        self.assertEqual(code, 1)
        self.assertIn("TypeMismatch", err)

    def test_analyze_arithmetic(self):
        with tempfile.TemporaryDirectory() as d:
            t = os.path.join(d, "t.tramaj")
            with open(t, "w", encoding="utf-8") as f:
                f.write("sum(1, negate(2))")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = main(["analyze", "arithmetic", t])
        self.assertEqual(code, 0)
        self.assertEqual(parse_json(out.getvalue()), ["negate", "sum"])


if __name__ == "__main__":
    unittest.main()
