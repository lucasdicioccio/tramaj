"""Runs the shared cross-implementation corpus at ``corpus/cases`` (see
``corpus/README.md``), the Python counterpart of ``tramaj-js/test/corpus.test.ts``,
``tramaj-rs/tests/corpus.rs``, ``tramaj-hs/test/unit/Tramaj/CorpusSpec.hs`` and
``tramaj/test/Test/Corpus.purs``. A case here is JSON-value equality between
independently written implementations, not merely "this implementation agrees
with itself"."""

from __future__ import annotations

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tramaj.evaluator import EvalError, run_program  # noqa: E402
from tramaj.jsonval import compact_json, json_equal  # noqa: E402
from tramaj.parser import ParseError, parse_program  # noqa: E402


def find_corpus_root() -> str:
    """``corpus/cases`` lives at the repo root: walk upward until it is found."""
    d = HERE
    while True:
        candidate = os.path.join(d, "corpus", "cases")
        if os.path.isdir(candidate):
            return candidate
        parent = os.path.dirname(d)
        if parent == d:
            raise RuntimeError("could not locate corpus/cases above the test directory")
        d = parent


def read_json(path: str):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def read_text(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def read_libs(case_dir: str) -> dict:
    table = {}
    libs_dir = os.path.join(case_dir, "libs")
    if not os.path.isdir(libs_dir):
        return table
    for entry in sorted(os.listdir(libs_dir)):
        if entry.endswith(".tramaj"):
            table[entry[: -len(".tramaj")]] = parse_program(read_text(os.path.join(libs_dir, entry)))
    return table


def run_case(case_dir: str, meta: dict) -> None:
    mode = meta["mode"]
    if mode not in ("concrete", "symbolic"):
        raise AssertionError(f"unknown mode {mode}")
    src = read_text(os.path.join(case_dir, "template.tramaj"))
    expect = meta.get("expect", "success")

    if expect == "parse-error":
        try:
            parse_program(src)
        except ParseError:
            return
        raise AssertionError("expected a parse error, but the template parsed")

    libs = read_libs(case_dir)
    ctx = read_json(os.path.join(case_dir, "ctx.json"))
    prog = parse_program(src)

    if expect == "eval-error":
        error_kind = meta.get("errorKind")
        if error_kind is None:
            raise AssertionError("eval-error case needs errorKind")
        try:
            run_program(mode, libs, ctx, prog)
        except EvalError as e:
            if e.kind != error_kind:
                raise AssertionError(f"expected eval error {error_kind}, got {e.kind} ({e})") from e
            return
        raise AssertionError(f"expected eval error {error_kind}, but evaluation succeeded")

    if expect != "success":
        raise AssertionError(f"unknown expect {expect}")

    expected = read_json(os.path.join(case_dir, "expected.json"))
    actual = run_program(mode, libs, ctx, prog)
    if not json_equal(actual, expected):
        raise AssertionError(
            f"output mismatch\n  expected: {compact_json(expected)}\n  actual:   {compact_json(actual)}"
        )


class CorpusTest(unittest.TestCase):
    pass


def _install_cases() -> None:
    root = find_corpus_root()
    dirs = sorted(
        os.path.join(root, name) for name in os.listdir(root) if os.path.isdir(os.path.join(root, name))
    )
    assert dirs, "corpus has no cases"
    for case_dir in dirs:
        meta = read_json(os.path.join(case_dir, "meta.json"))
        slug = os.path.basename(case_dir).replace("-", "_")

        def test(self, case_dir=case_dir, meta=meta):
            run_case(case_dir, meta)

        test.__doc__ = meta.get("name")
        setattr(CorpusTest, f"test_{meta['mode']}_{slug}", test)


_install_cases()

if __name__ == "__main__":
    unittest.main()
