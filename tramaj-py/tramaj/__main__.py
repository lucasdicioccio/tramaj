"""Command line over the port, mirroring ``tramaj-cli-rs``::

    python -m tramaj [evaluate] [--lib name=path ...] [--mode concrete|symbolic] <template-file> <context-json-file>
    python -m tramaj analyze <imports|actions|holes|unsupplied|constraints|symbols|types|card|all> <template-file> [--lib name=path ...]

Evaluation prints the result JSON (the node-json document, the plain value, or
the symbolic envelope) on stdout. A parse error exits 2, an evaluation error 1,
each with the error on stderr, leading with its kind.
"""

from __future__ import annotations

import json
import sys

from . import analysis as AN
from . import typesys as TY
from .evaluator import EvalError, run_program
from .jsonval import pretty_json
from .parser import ParseError, parse_program

USAGE = (
    "usage: python -m tramaj [evaluate] [--lib name=path ...] [--mode concrete|symbolic] <template-file> <context-json-file>\n"
    "       python -m tramaj analyze <imports|actions|holes|unsupplied|constraints|symbols|types|card|all> <template-file> [--lib name=path ...]"
)

ANALYSES = ("imports", "actions", "holes", "unsupplied", "constraints", "symbols", "types", "card", "all")


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def _split_args(argv: list[str]):
    libs: list[tuple[str, str]] = []
    mode = "concrete"
    positional: list[str] = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--lib":
            if i + 1 >= len(argv) or "=" not in argv[i + 1]:
                raise SystemExit("--lib expects name=path\n" + USAGE)
            name, path = argv[i + 1].split("=", 1)
            libs.append((name, path))
            i += 2
        elif a.startswith("--lib="):
            name, path = a[len("--lib="):].split("=", 1)
            libs.append((name, path))
            i += 1
        elif a == "--mode":
            if i + 1 >= len(argv):
                raise SystemExit("--mode expects concrete or symbolic\n" + USAGE)
            mode = argv[i + 1]
            i += 2
        elif a.startswith("--mode="):
            mode = a[len("--mode="):]
            i += 1
        elif a in ("-h", "--help"):
            print(USAGE)
            raise SystemExit(0)
        else:
            positional.append(a)
            i += 1
    if mode not in ("concrete", "symbolic"):
        raise SystemExit(f"unknown mode {mode!r}: expected concrete or symbolic\n" + USAGE)
    return libs, mode, positional


def _load_libs(pairs: list[tuple[str, str]]) -> dict:
    table = {}
    for name, path in pairs:
        try:
            table[name] = parse_program(_read(path))
        except ParseError as e:
            print(f"library {name!r} ({path}): parse error: {e}", file=sys.stderr)
            raise SystemExit(2)
    return table


def _analyze(what: str, libs: dict, prog) -> dict:
    def imports():
        return AN.transitive_import_names(libs, prog)

    def actions():
        return AN.deep_action_keys(libs, prog)

    def holes():
        return AN.deep_context_holes(libs, prog)

    def unsupplied():
        value_params = dict(AN.unsupplied_params(libs, prog))
        type_params = dict(AN.unsupplied_type_params(libs, prog))
        names = []
        for n, _ in AN.unsupplied_params(libs, prog):
            if n not in names:
                names.append(n)
        return [
            {"name": n, "valueParams": value_params.get(n, []), "typeParams": type_params.get(n, [])}
            for n in names
        ]

    def constraints():
        return {
            "kinds": AN.deep_constraint_kinds(libs, prog),
            "typeConstraints": [
                {"name": name, "arguments": _constraint_args(args)}
                for name, args in TY.deep_type_constraints(libs, prog)
            ],
        }

    def symbols():
        return {"sites": AN.symbol_sites(prog), "demands": AN.deep_symbol_demands(libs, prog)}

    def types():
        return {
            "declarations": AN.type_declarations(prog),
            "params": AN.type_params(prog),
            "references": TY.deep_type_references(libs, prog),
            "constraints": [
                {"name": name, "arguments": _constraint_args(args)}
                for name, args in TY.deep_type_constraints(libs, prog)
            ],
        }

    def card():
        c = AN.program_card(libs, prog)
        c["unsupplied"] = [{"name": n, "paths": ps} for n, ps in c["unsupplied"]]
        return c

    table = {
        "imports": imports,
        "actions": actions,
        "holes": holes,
        "unsupplied": unsupplied,
        "constraints": constraints,
        "symbols": symbols,
        "types": types,
        "card": card,
    }
    if what == "all":
        return {k: f() for k, f in table.items() if k != "card"}
    return table[what]()


def _constraint_args(args) -> list:
    out = []
    for a in args:
        if a.t == "Type":
            out.append({"$type": TY.canonical_id(a.type)})
        elif a.t == "ScalarNull":
            out.append(None)
        else:
            out.append(a.value)
    return out


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "analyze":
        libs_pairs, _, positional = _split_args(argv[1:])
        if len(positional) != 2 or positional[0] not in ANALYSES:
            print(USAGE, file=sys.stderr)
            return 2
        what, template = positional
        libs = _load_libs(libs_pairs)
        try:
            prog = parse_program(_read(template))
            result = _analyze(what, libs, prog)
        except ParseError as e:
            print(f"parse error: {e}", file=sys.stderr)
            return 2
        except TY.TramajTypeError as e:
            print(f"type error: {e}", file=sys.stderr)
            return 1
        print(pretty_json(result))
        return 0

    if argv and argv[0] == "evaluate":
        argv = argv[1:]
    libs_pairs, mode, positional = _split_args(argv)
    if len(positional) != 2:
        print(USAGE, file=sys.stderr)
        return 2
    template, context = positional
    libs = _load_libs(libs_pairs)
    try:
        prog = parse_program(_read(template))
    except ParseError as e:
        print(f"parse error: {e}", file=sys.stderr)
        return 2
    try:
        with open(context, encoding="utf-8") as f:
            ctx = json.load(f)
    except (OSError, ValueError) as e:
        print(f"context {context}: {e}", file=sys.stderr)
        return 2
    try:
        out = run_program(mode, libs, ctx, prog)
    except EvalError as e:
        print(f"eval error: {e}", file=sys.stderr)
        return 1
    print(pretty_json(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
