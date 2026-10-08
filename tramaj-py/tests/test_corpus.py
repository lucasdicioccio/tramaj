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

from tramaj.analysis import (  # noqa: E402
    context_holes,
    context_reads,
    deep_action_keys,
    deep_context_holes,
    static_action_keys,
    static_import_names,
    transitive_import_names,
)
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


# The profiles (``profiles`` in ``meta.json``, see corpus/README.md) this port
# can provide. A case naming any other one is skipped. ``base`` is the language
# without any profile; this port has no other yet, and no integer range to name
# until it has the two number types (``int-float``).
PROVIDED_PROFILES: frozenset = frozenset({"base"})

# The static analyses (reference.md §9) this port provides to an
# ``"expect": "analysis"`` case, by the name ``analysis.json`` gives them. A
# case naming any other one is skipped.
PROVIDED_ANALYSES: dict = {
    "staticImportNames": lambda libs, prog: static_import_names(prog),
    "transitiveImportNames": transitive_import_names,
    "staticActionKeys": lambda libs, prog: static_action_keys(prog),
    "deepActionKeys": deep_action_keys,
    "contextHoles": lambda libs, prog: context_holes(prog),
    "deepContextHoles": deep_context_holes,
    "contextReads": lambda libs, prog: context_reads(prog),
}


def missing_profiles(meta: dict) -> list:
    """The profiles a case names that this port does not provide."""
    return [r for r in meta.get("profiles", []) if r not in PROVIDED_PROFILES]


def run_analysis_case(case_dir: str, missing: list) -> None:
    """An ``"expect": "analysis"`` case: no context and no evaluation. Each
    named analysis runs over the parsed template (and ``libs/``, for a deep
    variant) and its result is compared, as a set, with the array
    ``analysis.json`` gives. The names are the keys of ``analysis.json``,
    which holds no number, so reading it before deciding to skip is safe on
    every port."""
    expected = read_json(os.path.join(case_dir, "analysis.json"))
    missing = missing + [f"analysis {name}" for name in sorted(expected) if name not in PROVIDED_ANALYSES]
    if missing:
        raise unittest.SkipTest(f"not provided: {', '.join(missing)}")
    prog = parse_program(read_text(os.path.join(case_dir, "template.tramaj")))
    libs = read_libs(case_dir)

    def as_set(xs) -> list:
        # Each element as its JSON text, so names and paths compare the same way.
        return sorted({json.dumps(x) for x in xs})

    for name in sorted(expected):
        want = as_set(expected[name])
        if len(want) != len(expected[name]):
            # A repeated element is refused: the file is a set.
            raise AssertionError(f"analysis.json: {name} repeats an element")
        actual = as_set(PROVIDED_ANALYSES[name](libs, prog))
        if actual != want:
            raise AssertionError(f"{name} mismatch\n  expected: {want}\n  actual:   {actual}")


def run_case(case_dir: str, meta: dict) -> None:
    if "requires" in meta:
        raise AssertionError('"requires" was replaced by "profiles" (corpus/README.md)')
    missing = missing_profiles(meta)
    if meta.get("expect") == "analysis":
        run_analysis_case(case_dir, missing)
        return
    if missing:
        raise unittest.SkipTest(f"not provided: {', '.join(missing)}")
    if "mode" not in meta:
        raise AssertionError("meta.json has no mode")
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
        # An "expect": "analysis" case has no mode.
        group = meta.get("mode", meta.get("expect", "nomode"))
        setattr(CorpusTest, f"test_{group}_{slug}", test)


_install_cases()


class ProfilesTest(unittest.TestCase):
    def test_a_case_naming_a_profile_this_port_does_not_provide_is_skipped(self):
        # corpus/runner-checks/unsupported-profile would fail if it ran:
        # its expected.json does not match what the template evaluates to.
        case_dir = os.path.join(os.path.dirname(find_corpus_root()), "runner-checks", "unsupported-profile")
        meta = read_json(os.path.join(case_dir, "meta.json"))
        with self.assertRaises(unittest.SkipTest) as raised:
            run_case(case_dir, meta)
        self.assertEqual(str(raised.exception), "not provided: never-declared")


if __name__ == "__main__":
    unittest.main()
