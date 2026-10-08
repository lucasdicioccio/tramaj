"""``sort-by``, ``sort-by-descending``, ``format-number`` and ``round``
(``specs/reference.md`` section 11, *Sorting* and *Number formatting*;
``specs/decisions.md`` section 20). The shared corpus states the language
rules case by case (cases 419 to 611). These tests cover what it cannot
state: how many times a key function runs, what the analyses see inside one,
what the parser lowers the two names to, and the rounding rule against an
independent exact computation on many doubles."""

from __future__ import annotations

import os
import random
import struct
import sys
import unittest
from decimal import ROUND_HALF_UP, Decimal, localcontext

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tramaj import ast as A  # noqa: E402
from tramaj import evaluator as E  # noqa: E402
from tramaj.analysis import (  # noqa: E402
    arithmetic_ops,
    constraint_kinds,
    context_holes,
    context_reads,
    deep_action_keys,
    deep_arithmetic_ops,
    deep_constraint_kinds,
    deep_context_holes,
    static_action_keys,
    static_import_names,
    symbol_demands,
    symbol_sites,
    transitive_import_names,
    unsupplied_params,
)
from tramaj.evaluator import EvalError, run_program  # noqa: E402
from tramaj.jsonval import json_equal  # noqa: E402
from tramaj.parser import ParseError, parse_program  # noqa: E402
from tramaj.typesys import erase_types  # noqa: E402

SORTS = ("sort-by", "sort-by-descending")


def run(src: str, ctx=None, mode: str = "concrete", arithmetic: bool = False):
    return run_program(mode, {}, ctx, parse_program(src), arithmetic=arithmetic)


def error_kind(src: str, ctx=None, mode: str = "concrete", arithmetic: bool = False) -> str:
    try:
        run(src, ctx, mode, arithmetic)
    except EvalError as e:
        return e.kind
    raise AssertionError(f"{src} evaluated")


class ParserTest(unittest.TestCase):
    def test_the_two_names_lower_to_one_constructor(self):
        for name, descending in (("sort-by", False), ("sort-by-descending", True)):
            for spelling in (name, "$" + name):
                with self.subTest(spelling=spelling):
                    root = parse_program(f"{spelling}($ctx.xs, (x) => $x.k)").root
                    self.assertEqual(
                        root,
                        A.SortBy(descending, A.Path("ctx", ["xs"]), A.Lambda(["x"], A.Path("x", ["k"]))),
                    )

    def test_the_key_function_may_be_a_reference(self):
        root = parse_program("sort-by($ctx.xs, $key-of)").root
        self.assertEqual(root, A.SortBy(False, A.Path("ctx", ["xs"]), A.Path("key-of", [])))

    def test_a_field_may_be_read_from_the_result(self):
        self.assertEqual(parse_program("sort-by($ctx.xs, $f).first").root.t, "FieldAccess")

    def test_an_argument_count_other_than_two_is_a_parse_error(self):
        for name in SORTS:
            for args in ("()", "($ctx.xs)", "($ctx.xs, (x) => $x, 1)"):
                with self.subTest(src=name + args), self.assertRaises(ParseError):
                    parse_program(name + args)

    def test_a_sort_name_passed_by_reference_is_a_parse_error(self):
        for name in SORTS:
            for src in (f"${name}", f"map($ctx.xs, ${name})", f"@f = ${name}\n1", f"[{name}]"):
                with self.subTest(src=src), self.assertRaises(ParseError):
                    parse_program(src)

    def test_a_sort_name_cannot_be_bound_and_called(self):
        # The name is a special form at the call, whatever is bound to it.
        with self.assertRaises(ParseError):
            parse_program("@sort-by = (a) => $a\nsort-by(1)")

    def test_format_number_and_round_are_names_not_syntax(self):
        self.assertEqual(parse_program("$format-number").root, A.Path("format-number", []))
        self.assertEqual(parse_program("$round").root, A.Path("round", []))
        self.assertEqual(run('@format-number = (a) => "mine"\nformat-number(1)'), "mine")
        self.assertEqual(run('@round = (a) => "mine"\nround(1)', arithmetic=True), "mine")

    def test_type_erasure_keeps_the_sort(self):
        prog = parse_program("sort-by-descending($ctx.xs, (x) => $x)")
        self.assertEqual(erase_types({}, prog).root, prog.root)


def count_applications(descending: bool, keys: list) -> list:
    """Evaluates a sort whose key function emits ``constraint("seen", $x)``
    each time it runs, and returns the arguments of the emissions before equal
    ones are made one. No program can observe the count, so this goes through
    the evaluator's own entry point rather than ``run_program``."""
    key_fn = A.Lambda(
        ["x"],
        A.Emit(A.Constrain("seen", [A.Path("x", ["i"])]), A.Path("x", ["k"])),
    )
    expr = A.SortBy(descending, A.Path("ctx", ["xs"]), key_fn)
    ctx_val = E._checked_from_json("concrete", False, {"xs": [{"i": i, "k": k} for i, k in enumerate(keys)]})
    emissions = E.Emissions()
    eval_ctx = E.EvalCtx({}, frozenset(), "concrete", True, emissions, False)
    out = E._eval_expr(eval_ctx, E._initial_env(ctx_val, False), expr)
    assert len(out.items) == len(keys)
    return [E.to_json(c.args[0]) for c in emissions.constraints]


class OncePerElementTest(unittest.TestCase):
    def test_the_key_function_is_applied_once_per_element_in_index_order(self):
        rng = random.Random(20)
        shuffled = list(range(50))
        rng.shuffle(shuffled)
        lists = {
            "empty": [],
            "one": [7],
            "ordered": list(range(40)),
            "reversed": list(range(40, 0, -1)),
            "shuffled": shuffled,
            "all equal": [3] * 30,
            "duplicated": [rng.randrange(4) for _ in range(60)],
            "strings": ["b", "a", "b", "", "a"],
            "floats": [2.5, 1.5, 2.5, 0.5],
        }
        for label, keys in lists.items():
            for descending in (False, True):
                with self.subTest(list=label, descending=descending):
                    self.assertEqual(count_applications(descending, keys), list(range(len(keys))))

    def test_nothing_is_applied_after_the_first_bad_key(self):
        key_fn = A.Lambda(["x"], A.Emit(A.Constrain("seen", [A.Path("x", [])]), A.Path("x", [])))
        expr = A.SortBy(False, A.Path("ctx", ["xs"]), key_fn)
        ctx_val = E._checked_from_json("concrete", False, {"xs": [1, 2, "three", 4]})
        emissions = E.Emissions()
        eval_ctx = E.EvalCtx({}, frozenset(), "concrete", True, emissions, False)
        with self.assertRaises(EvalError) as raised:
            E._eval_expr(eval_ctx, E._initial_env(ctx_val, False), expr)
        self.assertEqual(raised.exception.kind, "TypeMismatch")
        self.assertEqual(len(emissions.constraints), 3)


class SortTest(unittest.TestCase):
    def test_each_direction_is_stable_on_its_own_terms(self):
        rng = random.Random(21)
        rows = [{"i": i, "g": rng.randrange(5)} for i in range(200)]
        up = run("sort-by($ctx, (r) => $r.g)", rows)
        down = run("sort-by-descending($ctx, (r) => $r.g)", rows)
        self.assertEqual([(r["g"], r["i"]) for r in up], sorted((r["g"], r["i"]) for r in rows))
        self.assertEqual(
            [(r["g"], r["i"]) for r in down], sorted(((r["g"], r["i"]) for r in rows), key=lambda p: (-p[0], p[1]))
        )
        self.assertNotEqual(down, list(reversed(up)))

    def test_the_spec_example_of_ties(self):
        rows = [{"n": "a", "k": 2}, {"n": "b", "k": 1}, {"n": "c", "k": 2}]
        self.assertEqual(run("map(sort-by($ctx, (r) => $r.k), (r) => $r.n)", rows), ["b", "a", "c"])
        self.assertEqual(run("map(sort-by-descending($ctx, (r) => $r.k), (r) => $r.n)", rows), ["a", "c", "b"])

    def test_strings_sort_by_code_point_not_by_utf16_code_unit(self):
        # U+FF5E is one UTF-16 unit, 0xFF5E, and U+1F600 a surrogate pair
        # starting at 0xD83D: by code unit the second would come first.
        tilde, face = "～", "\U0001f600"
        self.assertEqual(run("sort-by($ctx, (s) => $s)", [face, tilde]), [tilde, face])
        self.assertEqual(run("sort-by-descending($ctx, (s) => $s)", [tilde, face]), [face, tilde])
        words = ["", "10", "9", "Zebra", "apple", "banana", "eclair", "éclair"]
        self.assertEqual(run("sort-by($ctx, (s) => $s)", list(reversed(words))), words)

    def test_the_input_list_is_not_reordered_in_place(self):
        src = "@xs = [3, 1, 2]\n@ys = sort-by($xs, (x) => $x)\n[$xs, $ys]"
        self.assertEqual(run(src), [[3, 1, 2], [1, 2, 3]])

    def test_the_elements_are_never_inspected(self):
        out = run(
            '@s = ?("s")\nsort-by([{k: 2, v: $s}, {k: 1, v: $s}], (r) => $r.k)', mode="symbolic"
        )
        self.assertEqual([r["k"] for r in out["root"]], [1, 2])

    def test_a_function_that_is_not_callable_is_refused_when_first_applied(self):
        self.assertEqual(error_kind("sort-by([1], 1)"), "TypeMismatch")
        self.assertEqual(run("sort-by([], 1)"), [])

    def test_keys_are_checked(self):
        self.assertEqual(error_kind("sort-by([1, 1.0], (x) => $x)"), "TypeMismatch")
        self.assertEqual(error_kind('sort-by([1, "a"], (x) => $x)'), "TypeMismatch")
        self.assertEqual(error_kind("sort-by([1], (x) => null)"), "TypeMismatch")
        self.assertEqual(error_kind("sort-by([true, false], (x) => $x)"), "TypeMismatch")
        self.assertEqual(error_kind('sort-by([?("s")], (x) => $x)', mode="symbolic"), "NotConcrete")
        self.assertEqual(error_kind('sort-by(?("s"), (x) => $x)', mode="symbolic"), "NotConcrete")
        self.assertEqual(error_kind("sort-by(1, (x) => $x)"), "TypeMismatch")


class AnalysesTest(unittest.TestCase):
    """Every analysis goes through ``ast.sub_exprs``, which has the new
    constructor, so each of them sees the collection and the key function."""

    def test_they_see_inside_the_collection_and_the_key_function(self):
        for name in SORTS:
            with self.subTest(name=name):
                prog = parse_program(
                    f"{name}("
                    'import("rows", {count: ctx(count)}).vals.rows, '
                    "(r) => "
                    'lookup({a: .button(action("on-click", "pick", $ctx.id)), '
                    'c: constraint("ranked", ?ctx.weight), t: ?("t")}, '
                    'import("keys", {}).vals.name, sum($r.spend, $ctx.bonus)))'
                )
                libs = {
                    "rows": parse_program(
                        "@rows = [modulo($ctx.count, 2)]\n"
                        '.p(action("on-click", "deep", {}), import("leaf", {h: ctx(hole)}).rendered)'
                    ),
                    "keys": parse_program('!constraint("deep-kind", 1)\n@name = $ctx.missing\n1'),
                }
                self.assertEqual(static_import_names(prog), ["keys", "rows"])
                self.assertEqual(transitive_import_names(libs, prog), ["keys", "leaf", "rows"])
                self.assertEqual(static_action_keys(prog), ["pick"])
                self.assertEqual(deep_action_keys(libs, prog), ["deep", "pick"])
                self.assertEqual(context_holes(prog), [["count"]])
                self.assertEqual(deep_context_holes(libs, prog), [["count"], ["hole"]])
                self.assertEqual(context_reads(prog), [["bonus"], ["count"], ["id"]])
                self.assertEqual(arithmetic_ops(prog), ["sum"])
                self.assertEqual(deep_arithmetic_ops(libs, prog), ["modulo", "sum"])
                self.assertEqual(symbol_demands(prog), [["weight"]])
                self.assertEqual(symbol_sites(prog), [0])
                self.assertEqual(constraint_kinds(prog), ["ranked"])
                self.assertEqual(deep_constraint_kinds(libs, prog), ["deep-kind", "ranked"])
                self.assertEqual(
                    unsupplied_params(libs, prog), [("rows", [["hole"]]), ("keys", [["missing"]])]
                )

    def test_a_key_function_parameter_shadows_an_arithmetic_name(self):
        for name in SORTS:
            with self.subTest(name=name):
                self.assertEqual(arithmetic_ops(parse_program(f"{name}($ctx.xs, (round) => $round)")), [])
                self.assertEqual(
                    arithmetic_ops(parse_program(f"{name}(map($ctx.xs, $real), (x) => round($x))")),
                    ["real", "round"],
                )

    def test_round_is_reported_called_and_by_reference(self):
        self.assertEqual(arithmetic_ops(parse_program("[round(1.5), map($ctx.xs, $round)]")), ["round"])
        self.assertEqual(arithmetic_ops(parse_program('format-number(1, 0, "")')), [])


def exact_text(x, decimals: int) -> str:
    """The rule written independently of the evaluator, on ``decimal``:
    ``Decimal(x)`` is the exact value of a float, and ``ROUND_HALF_UP`` is
    that module's name for ties away from zero."""
    with localcontext() as c:
        c.prec = 2000
        q = Decimal(x).quantize(Decimal(1).scaleb(-decimals), rounding=ROUND_HALF_UP)
    text = format(q, "f")
    if q == 0:
        text = text.lstrip("-")
    return text


def random_doubles(rng: random.Random, n: int) -> list:
    out = []
    while len(out) < n:
        kind = rng.randrange(4)
        if kind == 0:
            # Any bit pattern: every magnitude, subnormals included.
            x = struct.unpack("<d", struct.pack("<Q", rng.getrandbits(64)))[0]
        elif kind == 1:
            x = rng.uniform(-1e7, 1e7)
        elif kind == 2:
            # Written with three decimals, as amounts are.
            x = rng.randrange(-10**7, 10**7) / 1000
        else:
            # An exact tie at some number of decimals up to 20 binary places.
            x = (2 * rng.randrange(-10**6, 10**6) + 1) / 2 ** rng.randrange(1, 21)
        if x == x and x not in (float("inf"), float("-inf")):
            out.append(0.0 if x == 0 else x)
    return out


class FormatNumberTest(unittest.TestCase):
    def fmt(self, x, decimals, group=""):
        return run("format-number($ctx.x, $ctx.d, $ctx.g)", {"x": x, "d": decimals, "g": group})

    def test_the_examples_of_the_reference(self):
        for x, d, g, want in (
            (1234567.891, 2, ",", "1,234,567.89"),
            (1234567.891, 2, " ", "1 234 567.89"),
            (1234.5, 2, "", "1234.50"),
            (1234.5, 0, ",", "1,235"),
            (1234, 2, ",", "1,234.00"),
            (-1234567, 0, ",", "-1,234,567"),
            (999.995, 2, "", "1000.00"),
            (2.5, 0, "", "3"),
            (-2.5, 0, "", "-3"),
            (0.125, 2, "", "0.13"),
            (1.005, 2, "", "1.00"),
            (2.675, 2, "", "2.67"),
            (1e21, 0, ",", "1,000,000,000,000,000,000,000"),
            (1e23, 0, "", "99999999999999991611392"),
            (-0.001, 2, "", "0.00"),
            (-0.005, 2, "", "-0.01"),
            (0.5, 2, "", "0.50"),
        ):
            with self.subTest(x=x, d=d, g=g):
                self.assertEqual(self.fmt(x, d, g), want)

    def test_it_is_not_python_s_own_rounding(self):
        # round() and "%.0f" round ties to even: 0.5 -> 0, 2.5 -> 2.
        self.assertEqual("%.0f" % 2.5, "2")
        self.assertEqual(self.fmt(0.5, 0), "1")
        self.assertEqual(self.fmt(2.5, 0), "3")
        self.assertEqual(self.fmt(-0.5, 0), "-1")
        self.assertEqual(self.fmt(0.375, 2), "0.38")

    def test_against_an_exact_computation_on_many_doubles(self):
        rng = random.Random(22)
        prog = parse_program("format-number($ctx.x, $ctx.d, \"\")")
        for x in random_doubles(rng, 20000):
            d = rng.randrange(21)
            got = run_program("concrete", {}, {"x": x, "d": d}, prog)
            if got != exact_text(x, d):
                self.fail(f"format-number({x!r}, {d}): {got} is not {exact_text(x, d)}")

    def test_integers_are_formatted_from_their_exact_value(self):
        self.assertEqual(self.fmt(2**63 - 1, 0, ","), "9,223,372,036,854,775,807")
        self.assertEqual(self.fmt(-(2**63), 2, "_"), "-9_223_372_036_854_775_808.00")
        self.assertEqual(self.fmt(9007199254740993, 20), "9007199254740993." + "0" * 20)
        self.assertEqual(self.fmt(0, 0), "0")

    def test_the_largest_and_the_smallest_floats_format_without_an_exponent(self):
        big = self.fmt(1.7976931348623157e308, 20)
        self.assertEqual(len(big), 309 + 1 + 20)
        self.assertNotIn("e", big)
        self.assertEqual(self.fmt(5e-324, 20), "0." + "0" * 20)
        self.assertEqual(self.fmt(-5e-324, 20), "0." + "0" * 20)

    def test_grouping_never_changes_a_digit(self):
        rng = random.Random(23)
        for x in random_doubles(rng, 2000):
            d = rng.randrange(21)
            plain = self.fmt(x, d)
            for g in (",", " ", "''", "."):
                grouped = self.fmt(x, d, g)
                whole, _, fraction = plain.partition(".")
                sign = "-" if whole.startswith("-") else ""
                digits = whole.lstrip("-")
                parts = grouped[len(sign) : len(grouped) - (len(fraction) + 1 if d else 0)].split(g)
                self.assertEqual("".join(parts), digits)
                self.assertTrue(all(len(p) == 3 for p in parts[1:]) and 1 <= len(parts[0]) <= 3)
                self.assertTrue(grouped.startswith(sign) and grouped.endswith(plain[len(whole):]))

    def test_the_arguments_are_examined_left_to_right(self):
        sym = {"$sym": "#ctx.s", "path": []}
        for x, d, g, mode, want in (
            ("a", sym, 1, "symbolic", "TypeMismatch"),
            (sym, "a", 1, "symbolic", "NotConcrete"),
            (1, sym, 1, "symbolic", "NotConcrete"),
            (1, 2.0, sym, "symbolic", "TypeMismatch"),
            (1, 21, sym, "symbolic", "TypeMismatch"),
            (1, -1, "", "concrete", "TypeMismatch"),
            (1, 2, sym, "symbolic", "NotConcrete"),
            (1, 2, None, "concrete", "TypeMismatch"),
            (True, 2, "", "concrete", "TypeMismatch"),
        ):
            with self.subTest(x=x, d=d, g=g):
                ctx = {"x": x, "d": d, "g": g}
                self.assertEqual(error_kind("format-number($ctx.x, $ctx.d, $ctx.g)", ctx, mode), want)

    def test_a_wrong_argument_count_is_a_type_mismatch(self):
        self.assertEqual(error_kind("format-number(1, 2)"), "TypeMismatch")
        self.assertEqual(error_kind('format-number(1, 2, "", 3)'), "TypeMismatch")

    def test_it_needs_no_profile_and_may_be_passed_by_reference(self):
        self.assertEqual(run('map([1.5], (x) => format-number($x, 0, ""))'), ["2"])
        self.assertEqual(run("@f = $format-number\n$f(1234, 1, \",\")"), "1,234.0")


class RoundTest(unittest.TestCase):
    def round(self, x):
        return run("round($ctx.x)", {"x": x}, arithmetic=True)

    def test_ties_go_away_from_zero(self):
        for x, want in (
            (2.5, 3), (-2.5, -3), (0.5, 1), (-0.5, -1), (1.5, 2), (-0.4, 0), (0.4, 0),
            (0.49999999999999994, 0), (-0.49999999999999994, 0), (4503599627370497.5, 4503599627370498),
            (0.0, 0), (7, 7), (-7, -7),
        ):
            with self.subTest(x=x):
                got = self.round(x)
                self.assertTrue(json_equal(got, want), f"{got!r}")

    def test_the_result_is_an_integer(self):
        self.assertIsInstance(self.round(2.0), int)

    def test_both_ends_of_the_integer_range(self):
        self.assertEqual(self.round(-9223372036854775808.0), -(2**63))
        self.assertEqual(self.round(9223372036854774784.0), 9223372036854774784)
        self.assertEqual(self.round(2**63 - 1), 2**63 - 1)
        for x in (9223372036854775808.0, -9223372036854777856.0, 1e300, -1e300):
            with self.subTest(x=x):
                self.assertEqual(error_kind("round($ctx.x)", {"x": x}, arithmetic=True), "NotRepresentable")

    def test_operands_are_checked(self):
        self.assertEqual(error_kind('round("a")', arithmetic=True), "TypeMismatch")
        self.assertEqual(error_kind("round([1.5])", arithmetic=True), "TypeMismatch")
        self.assertEqual(error_kind("round(1.5, 2.5)", arithmetic=True), "TypeMismatch")
        self.assertEqual(error_kind("round()", arithmetic=True), "TypeMismatch")

    def test_a_term_is_built_over_a_symbol_and_a_seeded_one_is_accepted(self):
        out = run('round(?("s"))', mode="symbolic", arithmetic=True)
        sym = {"$sym": '#0:"s"', "path": []}
        self.assertTrue(json_equal(out["root"], {"$term": "round", "arguments": [sym]}))
        seeded = {"t": {"$term": "round", "arguments": [{"$sym": "#ctx.s", "path": []}]}}
        self.assertTrue(json_equal(run("$ctx.t", seeded, "symbolic", True)["root"], seeded["t"]))
        self.assertTrue(
            json_equal(
                run("sum(1, round($ctx.t))", seeded, "symbolic", True)["root"],
                {"$term": "sum", "arguments": [1, {"$term": "round", "arguments": [seeded["t"]]}]},
            )
        )
        self.assertEqual(error_kind("1", seeded, "symbolic", False), "TypeMismatch")
        two = {"$term": "round", "arguments": [{"$sym": "#ctx.s", "path": []}, 1]}
        self.assertEqual(error_kind("1", two, "symbolic", True), "TypeMismatch")
        concrete = {"$term": "round", "arguments": [1.5]}
        self.assertEqual(error_kind("1", concrete, "symbolic", True), "TypeMismatch")

    def test_str_of_round_is_format_number_with_no_decimals(self):
        rng = random.Random(24)
        prog = parse_program('[str(round($ctx.x)), format-number($ctx.x, 0, "")]')
        n = 0
        while n < 5000:
            if rng.randrange(4) == 0:
                x = rng.randrange(-10**9, 10**9) + 0.5
            else:
                x = rng.uniform(-1e15, 1e15) if rng.randrange(2) else rng.uniform(-100.0, 100.0)
            a, b = run_program("concrete", {}, {"x": x}, prog, arithmetic=True)
            self.assertEqual(a, b, f"{x!r}")
            n += 1


if __name__ == "__main__":
    unittest.main()
