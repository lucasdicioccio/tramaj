"""Static analysis over the AST alone (``specs/reference.md`` section 9,
``specs/v3-symbols.md`` section 7, ``specs/v4-types.md`` section 9). Answers
from the AST alone: no context, no library evaluation, no host code.

Every set-valued answer is returned as a sorted list, so two runs over the
same program agree on order as well as membership."""

from __future__ import annotations

from typing import Callable, TypeVar

from . import ast as A
from .jsonval import compact_json, sorted_strings, utf16_key

LibraryTable = dict  # import name -> Program
T = TypeVar("T")


def _sorted_paths(xs) -> list[list[str]]:
    seen: dict[str, list[str]] = {}
    for p in xs:
        seen[compact_json(p)] = list(p)
    return [seen[k] for k in sorted(seen.keys(), key=utf16_key)]


def _everywhere(f: Callable[[A.Expr], list[T]], e: A.Expr) -> list[T]:
    """Collects from an expression and every expression inside it."""
    out = list(f(e))
    for sub in A.sub_exprs(e):
        out.extend(_everywhere(f, sub))
    return out


# Imports --------------------------------------------------------------------


def static_import_names(prog: A.Program) -> list[str]:
    """Every library this program imports directly."""
    return sorted_strings(_everywhere(lambda e: [e.name] if e.t == "Import" else [], prog.root))


def transitive_import_names(libs: LibraryTable, prog: A.Program) -> list[str]:
    """Every library reachable from this program, directly or through another
    import. A missing name is still reported; a cycle terminates."""
    seen: set[str] = set()
    frontier = list(static_import_names(prog))
    while frontier:
        name = frontier.pop()
        if name in seen:
            continue
        seen.add(name)
        p = libs.get(name)
        if p is None:
            continue
        for nxt in static_import_names(p):
            if nxt not in seen:
                frontier.append(nxt)
    return sorted_strings(seen)


# Actions ---------------------------------------------------------------------


def _own_keys_of(e: A.Expr) -> list[str]:
    if e.t != "Element":
        return []
    return [a.key for a in e.attributes if a.t == "ActionAttr"]


def _action_keys_in(e: A.Expr) -> list[str]:
    if e.t == "AdaptActions":
        out = [A.adapt_key(e.adaptation, k) for k in _action_keys_in(e.target)]
        return out if e.fn is None else out + _action_keys_in(e.fn)
    out = _own_keys_of(e)
    for sub in A.sub_exprs(e):
        out.extend(_action_keys_in(sub))
    return out


def static_action_keys(prog: A.Program) -> list[str]:
    """Every action key this program can emit from its own AST; adaptation is applied, not ignored."""
    return sorted_strings(_action_keys_in(prog.root))


def deep_action_keys(libs: LibraryTable, prog: A.Program) -> list[str]:
    """Every action key this program can emit, following imports. An over-approximation."""

    def go(seen: set[str], e: A.Expr) -> list[str]:
        if e.t == "AdaptActions":
            out = [A.adapt_key(e.adaptation, k) for k in go(seen, e.target)]
            return out if e.fn is None else out + go(seen, e.fn)
        if e.t == "Import":
            out = []
            for _, p in e.params:
                if p.t == "PExpr":
                    out.extend(go(seen, p.expr))
            if e.name not in seen:
                seen.add(e.name)
                lib = libs.get(e.name)
                if lib is not None:
                    out.extend(go(seen, lib.root))
            return out
        out = _own_keys_of(e)
        for sub in A.sub_exprs(e):
            out.extend(go(seen, sub))
        return out

    return sorted_strings(go(set(), prog.root))


# Context holes -------------------------------------------------------------------


def _own_context_holes(e: A.Expr) -> list[list[str]]:
    if e.t != "Import":
        return []
    return [p.path for _, p in e.params if p.t == "PFromContext"]


def context_holes(prog: A.Program) -> list[list[str]]:
    """Every path this program declares as a hole with ``ctx(path)``."""
    return _sorted_paths(_everywhere(_own_context_holes, prog.root))


def deep_context_holes(libs: LibraryTable, prog: A.Program) -> list[list[str]]:
    out = list(context_holes(prog))
    for name in transitive_import_names(libs, prog):
        p = libs.get(name)
        if p is not None:
            out.extend(context_holes(p))
    return _sorted_paths(out)


def context_reads(prog: A.Program) -> list[list[str]]:
    """Every path this program reads out of its own context, however written."""

    def f(e: A.Expr) -> list[list[str]]:
        if e.t == "Path" and e.root == "ctx":
            return [e.fields]
        return _own_context_holes(e)

    return _sorted_paths(_everywhere(f, prog.root))


def unsupplied_params(libs: LibraryTable, prog: A.Program) -> list[tuple[str, list[list[str]]]]:
    """For each import in this program, the paths its library reads from its
    context that the import does not supply. Attributed by the read's first segment."""
    out: list[tuple[str, list[list[str]]]] = []

    def collect(e: A.Expr) -> None:
        if e.t == "Import":
            supplied = {k for k, _ in e.params}
            p = libs.get(e.name)
            reads = [] if p is None else context_reads(p)
            out.append((e.name, [path for path in reads if path and path[0] not in supplied]))
        for sub in A.sub_exprs(e):
            collect(sub)

    collect(prog.root)
    return out


# Constraints -----------------------------------------------------------------


def constraint_kinds(prog: A.Program) -> list[str]:
    return sorted_strings(_everywhere(lambda e: [e.name] if e.t == "Constrain" else [], prog.root))


def deep_constraint_kinds(libs: LibraryTable, prog: A.Program) -> list[str]:
    def go(seen: set[str], e: A.Expr) -> list[str]:
        if e.t == "Import":
            out = []
            for _, p in e.params:
                if p.t == "PExpr":
                    out.extend(go(seen, p.expr))
            if e.name not in seen:
                seen.add(e.name)
                lib = libs.get(e.name)
                if lib is not None:
                    out.extend(go(seen, lib.root))
            return out
        out = [e.name] if e.t == "Constrain" else []
        for sub in A.sub_exprs(e):
            out.extend(go(seen, sub))
        return out

    return sorted_strings(go(set(), prog.root))


# Symbols -----------------------------------------------------------------------


def symbol_sites(prog: A.Program) -> list[int]:
    """The ``?(k)`` allocation sites this program contains: sites, not keys."""
    sites = _everywhere(lambda e: [e.site] if e.t == "Alloc" else [], prog.root)
    return sorted(set(sites))


def symbol_demands(prog: A.Program) -> list[list[str]]:
    return _sorted_paths(_everywhere(lambda e: [e.path] if e.t == "Demand" else [], prog.root))


def deep_symbol_demands(libs: LibraryTable, prog: A.Program) -> list[list[str]]:
    out = list(symbol_demands(prog))
    for name in transitive_import_names(libs, prog):
        p = libs.get(name)
        if p is not None:
            out.extend(symbol_demands(p))
    return _sorted_paths(out)


# Types -------------------------------------------------------------------------


def type_declarations(prog: A.Program) -> list[str]:
    return sorted_strings(n for n, _ in A.type_decls(A.unlets(prog.root)[0]))


def _type_params_in(t: A.TypeExpr) -> list[list[str]]:
    if t.t == "Array":
        return _type_params_in(t.element)
    if t.t == "Record":
        out = []
        for _, ft in t.fields:
            out.extend(_type_params_in(ft))
        return out
    if t.t == "Union":
        out = []
        for _, at in t.arms:
            if at is not None:
                out.extend(_type_params_in(at))
        return out
    if t.t == "Var":
        return [t.path]
    return []


def type_exprs_in(e: A.Expr) -> list[A.TypeExpr]:
    """Every ``TypeExpr`` sitting in one expression's own syntax, not recursing
    into subexpressions."""
    if e.t in ("TypeDecl", "TypeAnnotate"):
        return [e.type]
    if e.t == "TypeEmit":
        return [a.type for a in e.args if a.t == "Type"]
    if e.t == "Import":
        return [p.type for _, p in e.params if p.t == "PType"]
    return []


def type_params(prog: A.Program) -> list[list[str]]:
    def f(e: A.Expr) -> list[list[str]]:
        out = []
        for t in type_exprs_in(e):
            out.extend(_type_params_in(t))
        return out

    return _sorted_paths(_everywhere(f, prog.root))


def unsupplied_type_params(libs: LibraryTable, prog: A.Program) -> list[tuple[str, list[list[str]]]]:
    out: list[tuple[str, list[list[str]]]] = []

    def go(e: A.Expr) -> None:
        if e.t == "Import":
            supplied = {k for k, p in e.params if p.t == "PType"}
            p = libs.get(e.name)
            wanted = [] if p is None else type_params(p)
            out.append((e.name, [path for path in wanted if path and path[0] not in supplied]))
        for sub in A.sub_exprs(e):
            go(sub)

    go(prog.root)
    return out


def type_param_collisions(prog: A.Program) -> list[str]:
    reads = {p[0] for p in context_reads(prog) if p}
    tparams = [p[0] for p in type_params(prog) if p]
    return sorted_strings(k for k in tparams if k in reads)


# Card -----------------------------------------------------------------------


def program_kind(prog: A.Program) -> str:
    return "document" if prog.kind == "document" else "value"


def program_card(libs: LibraryTable, prog: A.Program) -> dict:
    """A one-glance summary of a program's static interface."""
    return {
        "produces": program_kind(prog),
        "requires": context_reads(prog),
        "imports": transitive_import_names(libs, prog),
        "emits": deep_action_keys(libs, prog),
        "unsupplied": unsupplied_params(libs, prog),
    }
