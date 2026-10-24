"""``?shape(key, shape)`` and its ``~name`` markers (``v3-symbols.md`` section
1.2, decisions section 19), where the shared corpus has no shape for the check:
the AST the form lowers to, its site numbering, the parse errors one by one,
and ``symbol_sites``. The same cases are in tramaj-go's shape_test.go."""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tramaj import ast as A  # noqa: E402
from tramaj.analysis import symbol_sites  # noqa: E402
from tramaj.evaluator import run_program  # noqa: E402
from tramaj.parser import ParseError, parse_program  # noqa: E402


def marker_at(site: int, name: str, *key: A.Expr) -> A.Expr:
    return A.Alloc(site, A.ArrayLit([A.Path(A.SHAPE_KEY_NAME, []), A.StringLit(name), *key]))


class ShapeTest(unittest.TestCase):
    def test_lowers_to_a_hidden_binding(self) -> None:
        prog = parse_program('?shape("d", {~replicas, ports: [~http($x)]})')
        self.assertEqual(
            prog.root,
            A.Let(
                A.SHAPE_KEY_NAME,
                A.StringLit("d"),
                A.ObjectLit(
                    [
                        ("replicas", marker_at(0, "replicas")),
                        ("ports", A.ArrayLit([marker_at(0, "http", A.Path("x", []))])),
                    ]
                ),
            ),
        )

    def test_a_plain_alloc_takes_the_next_site(self) -> None:
        prog = parse_program('?shape("o", [~a, ?("p")])')
        self.assertEqual(
            prog.root,
            A.Let(
                A.SHAPE_KEY_NAME,
                A.StringLit("o"),
                A.ArrayLit([marker_at(0, "a"), A.Alloc(1, A.StringLit("p"))]),
            ),
        )

    def test_symbol_sites_counts_a_form_once(self) -> None:
        prog = parse_program('[?shape("o", {~a, b: [~b, ~c(1)], i: ?shape("i", {~d})}), ?("p")]')
        self.assertEqual(symbol_sites(prog), [0, 1, 2])

    def test_allocates_with_a_null_binding(self) -> None:
        prog = parse_program('@d = ?shape("d", {~a, b: map([1, 2], (x) => ~b($x))})\n$d')
        out = run_program("symbolic", {}, None, prog)
        self.assertEqual(
            out["symbols"],
            [
                {"id": '#0:["d","a"]', "origin": {"kind": "alloc", "site": 0, "key": ["d", "a"]}, "binding": None},
                {"id": '#0:["d","b",1]', "origin": {"kind": "alloc", "site": 0, "key": ["d", "b", 1]}, "binding": None},
                {"id": '#0:["d","b",2]', "origin": {"kind": "alloc", "site": 0, "key": ["d", "b", 2]}, "binding": None},
            ],
        )

    def test_leaves_dollar_shape_alone(self) -> None:
        self.assertEqual(run_program("concrete", {}, None, parse_program("@shape = 1\n$shape")), 1)

    def test_rejects(self) -> None:
        for what, src in [
            ("a marker outside any shape", "[~a]"),
            ("a marker in a ?shape's key", "?shape(~k, {~a})"),
            ("a marker in a nested ?shape's key", '?shape("o", {~a, i: ?shape(~k, {~b})})'),
            ("a bare marker under a lambda inside the shape", '?shape("d", map($xs, (x) => ~a))'),
            ("a bare shorthand marker under a lambda", '?shape("d", map($xs, (x) => {~a}))'),
            ("a duplicate marker name, bare and keyed", '?shape("d", [~a, map($xs, (x) => ~a($x))])'),
            ("a shape with no marker", '?shape("d", {a: 1})'),
            ("?shape with three arguments", '?shape("d", {~a}, 1)'),
            ("?shape with one argument", '?shape("d")'),
            ("a space after the marker leader", '?shape("d", ~ a)'),
            ("?(a, b)", '?("a", "b")'),
        ]:
            with self.subTest(what):
                with self.assertRaises(ParseError):
                    parse_program(src)

    def test_reports_the_broken_rule(self) -> None:
        """Past ``?shape(`` the parser commits, as it does for a special form,
        so a broken marker rule is reported as itself rather than as a failed
        alternative."""
        for src, msg in [
            ('?shape("d", {a: 1})', "a ?shape's shape must contain at least one marker of its own"),
            ('?shape("d", {~a, b: ~a})', "a marker name appears twice in one ?shape"),
            ("?shape(~k, {~a})", "a marker cannot be written in a ?shape's key"),
            (
                '?shape("d", map($xs, (x) => ~a))',
                "a marker under a lambda inside a ?shape must carry a key, as in ~name(key)",
            ),
            ("[~a]", "a marker ~name may only be written inside a ?shape's shape"),
        ]:
            with self.subTest(src):
                with self.assertRaises(ParseError) as cm:
                    parse_program(src)
                self.assertEqual(cm.exception.detail, msg)


if __name__ == "__main__":
    unittest.main()
