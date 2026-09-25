"""v4-types resolution, normalisation, canonical identity, and the closure and
constraint machinery output needs (``specs/v4-types.md``). A static pass over
parsed programs, evaluating nothing. Mirrors ``tramaj-js/src/types.ts``."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional, Union

from . import ast as A
from .analysis import (
    transitive_import_names,
    type_exprs_in,
    type_param_collisions,
    type_params,
)
from .jsonval import compact_json, sorted_strings, utf16_key

LibraryTable = dict


@dataclass
class RPrim:
    name: str
    t: str = field(default="Prim", init=False)


@dataclass
class RArray:
    element: "ResolvedType"
    t: str = field(default="Array", init=False)


@dataclass
class RRecord:
    fields: list[tuple[str, "ResolvedType"]]
    t: str = field(default="Record", init=False)


@dataclass
class RUnion:
    arms: list[tuple[str, Optional["ResolvedType"]]]
    t: str = field(default="Union", init=False)


@dataclass
class RRef:
    lib: Optional[str]
    name: str
    args: list[tuple[str, "ResolvedType"]]
    t: str = field(default="Ref", init=False)


@dataclass
class RVar:
    path: list[str]
    t: str = field(default="Var", init=False)


ResolvedType = Union[RPrim, RArray, RRecord, RUnion, RRef, RVar]


class TramajTypeError(Exception):
    """``v4-types.md`` section 10's analysis errors. ``str(e)`` leads with the bare kind."""

    def __init__(self, kind: str, detail: str) -> None:
        super().__init__(kind if detail == "" else f"{kind} {detail}")
        self.kind = kind

    @staticmethod
    def unresolved_type(n: str) -> "TramajTypeError":
        return TramajTypeError("UnresolvedType", n)

    @staticmethod
    def not_statically_resolvable(n: str) -> "TramajTypeError":
        return TramajTypeError("NotStaticallyResolvable", n)

    @staticmethod
    def partial_type(cid: str, path: list[str]) -> "TramajTypeError":
        return TramajTypeError("PartialType", f"{cid} {compact_json(path)}")

    @staticmethod
    def type_param_collision(k: str) -> "TramajTypeError":
        return TramajTypeError("TypeParamCollision", k)

    @staticmethod
    def type_cycle(k: str) -> "TramajTypeError":
        return TramajTypeError("TypeCycle", k)


def program_type_decls(prog: A.Program) -> dict[str, A.TypeExpr]:
    """Just the type declarations at the top of a program's own statement chain."""
    return dict(A.type_decls(A.unlets(prog.root)[0]))


def resolve_type_expr(libs: LibraryTable, prog: A.Program, t: A.TypeExpr) -> ResolvedType:
    return _resolve_with(libs, prog, {}, set(), t)


def _resolve_with(
    libs: LibraryTable,
    prog: A.Program,
    subst: dict[str, ResolvedType],
    visiting: set[str],
    t: A.TypeExpr,
) -> ResolvedType:
    if t.t == "Prim":
        return RPrim(t.name)
    if t.t == "Array":
        return RArray(_resolve_with(libs, prog, subst, visiting, t.element))
    if t.t == "Record":
        fields = [(n, _resolve_with(libs, prog, subst, visiting, ft)) for n, ft in t.fields]
        fields.sort(key=lambda f: utf16_key(f[0]))
        return RRecord(fields)
    if t.t == "Union":
        arms = [
            (n, None if at is None else _resolve_with(libs, prog, subst, visiting, at))
            for n, at in t.arms
        ]
        arms.sort(key=lambda a: utf16_key(a[0]))
        return RUnion(arms)
    if t.t == "Var":
        # Only a single-segment path is ever substituted.
        if len(t.path) == 1 and t.path[0] in subst:
            return subst[t.path[0]]
        return RVar(list(t.path))
    if t.t == "Name":
        if t.name in program_type_decls(prog):
            return RRef(None, t.name, [])
        raise TramajTypeError.unresolved_type(t.name)
    if t.t == "LibRef":
        stmts = A.unlets(prog.root)[0]
        key, lib_prog, params = _resolve_lib_binding(libs, stmts, t.lib)
        if t.name not in program_type_decls(lib_prog):
            raise TramajTypeError.unresolved_type(t.name)
        if key in visiting:
            raise TramajTypeError.type_cycle(key)
        visiting2 = set(visiting)
        visiting2.add(key)
        wanted = {(p[0] if p else "") for p in type_params(lib_prog)}
        supplied_types = {k: v.type for k, v in params if v.t == "PType"}
        args: list[tuple[str, ResolvedType]] = []
        for k in sorted(wanted, key=utf16_key):
            te = supplied_types.get(k)
            args.append((k, RVar([k]) if te is None else _resolve_with(libs, prog, subst, visiting2, te)))
        return RRef(key, t.name, args)
    raise AssertionError(f"unknown type expression {t.t}")


def _resolve_lib_binding(libs: LibraryTable, stmts: list[A.Stmt], lib: str):
    found = None
    for s in stmts:
        if s.t == "Let" and s.value.t == "Import" and s.name == lib:
            found = (s.value.name, s.value.params)
    if found is None:
        raise TramajTypeError.not_statically_resolvable(lib)
    lib_prog = libs.get(found[0])
    if lib_prog is None:
        raise TramajTypeError.not_statically_resolvable(lib)
    return found[0], lib_prog, found[1]


def canonical_id(rt: ResolvedType) -> str:
    """``v4-types.md`` section 3's grammar, rendered. Renders the order it is
    given, it does not sort."""
    if rt.t == "Prim":
        return rt.name
    if rt.t == "Array":
        return f"[{canonical_id(rt.element)}]"
    if rt.t == "Record":
        return "{" + ",".join(f"{n}:{canonical_id(t)}" for n, t in rt.fields) + "}"
    if rt.t == "Union":
        return "".join(f"|{n}" if t is None else f"|{n} {canonical_id(t)}" for n, t in rt.arms)
    if rt.t == "Ref":
        head = f"{_render_library(rt.lib)}:{rt.name}"
        if not rt.args:
            return head
        return head + "[" + ",".join(f"{k}={canonical_id(t)}" for k, t in rt.args) + "]"
    return "%ctx" + "".join(f".{p}" for p in rt.path)


def _render_library(lib: Optional[str]) -> str:
    return "root" if lib is None else f'"{lib}"'


def resolved_type_equal(a: ResolvedType, b: ResolvedType) -> bool:
    if a.t != b.t:
        return False
    if a.t == "Prim":
        return a.name == b.name
    if a.t == "Array":
        return resolved_type_equal(a.element, b.element)
    if a.t == "Record":
        return len(a.fields) == len(b.fields) and all(
            n == m and resolved_type_equal(t, u) for (n, t), (m, u) in zip(a.fields, b.fields)
        )
    if a.t == "Union":
        if len(a.arms) != len(b.arms):
            return False
        for (n, t), (m, u) in zip(a.arms, b.arms):
            if n != m:
                return False
            if t is None or u is None:
                if not (t is None and u is None):
                    return False
            elif not resolved_type_equal(t, u):
                return False
        return True
    if a.t == "Ref":
        return (
            a.lib == b.lib
            and a.name == b.name
            and len(a.args) == len(b.args)
            and all(k == l and resolved_type_equal(t, u) for (k, t), (l, u) in zip(a.args, b.args))
        )
    return a.path == b.path


def _contains_var(rt: ResolvedType) -> bool:
    if rt.t == "Var":
        return True
    if rt.t == "Array":
        return _contains_var(rt.element)
    if rt.t == "Record":
        return any(_contains_var(t) for _, t in rt.fields)
    if rt.t == "Union":
        return any(t is not None and _contains_var(t) for _, t in rt.arms)
    if rt.t == "Ref":
        return any(_contains_var(t) for _, t in rt.args)
    return False


def _first_var_path(rt: ResolvedType) -> list[str]:
    if rt.t == "Var":
        return list(rt.path)
    if rt.t == "Array":
        return _first_var_path(rt.element)
    if rt.t == "Record":
        for _, t in rt.fields:
            if _contains_var(t):
                return _first_var_path(t)
        return []
    if rt.t == "Union":
        for _, t in rt.arms:
            if t is not None and _contains_var(t):
                return _first_var_path(t)
        return []
    if rt.t == "Ref":
        for _, t in rt.args:
            if _contains_var(t):
                return _first_var_path(t)
        return []
    return []


def require_closed(rt: ResolvedType) -> ResolvedType:
    """``v4-types.md`` section 4: a type reaching the root must be closed."""
    if _contains_var(rt):
        raise TramajTypeError.partial_type(canonical_id(rt), _first_var_path(rt))
    return rt


def check_type_param_collisions(prog: A.Program) -> None:
    xs = sorted_strings(type_param_collisions(prog))
    if xs:
        raise TramajTypeError.type_param_collision(xs[0])


# Output: the transitive closure of referenced types (v4-types section 8) ------------


def _collect_refs(rt: ResolvedType) -> list[ResolvedType]:
    if rt.t == "Ref":
        out = [rt]
        for _, a in rt.args:
            out.extend(_collect_refs(a))
        return out
    if rt.t == "Array":
        return _collect_refs(rt.element)
    if rt.t == "Record":
        out = []
        for _, t in rt.fields:
            out.extend(_collect_refs(t))
        return out
    if rt.t == "Union":
        out = []
        for _, t in rt.arms:
            if t is not None:
                out.extend(_collect_refs(t))
        return out
    return []


def _lookup_decl(libs: LibraryTable, prog: A.Program, lib_key: Optional[str], name: str):
    if lib_key is None:
        body = program_type_decls(prog).get(name)
        if body is None:
            raise TramajTypeError.unresolved_type(name)
        return prog, body
    lib_prog = libs.get(lib_key)
    if lib_prog is None:
        raise TramajTypeError.not_statically_resolvable(lib_key)
    body = program_type_decls(lib_prog).get(name)
    if body is None:
        raise TramajTypeError.unresolved_type(name)
    return lib_prog, body


def type_closure(libs: LibraryTable, prog: A.Program, roots: list[ResolvedType]) -> dict[str, ResolvedType]:
    """The transitive closure of every type referenced from ``roots``, cut by
    canonical id so a cycle terminates."""
    acc: dict[str, ResolvedType] = {}
    queue: list[ResolvedType] = []
    for r in roots:
        queue.extend(_collect_refs(r))
    while queue:
        r = queue.pop()
        if r.t != "Ref":
            continue
        cid = canonical_id(r)
        if cid in acc:
            continue
        decl_prog, body = _lookup_decl(libs, prog, r.lib, r.name)
        subst = dict(r.args)
        definition = _resolve_with(libs, decl_prog, subst, set(), body)
        queue.extend(_collect_refs(definition))
        acc[cid] = definition
    return acc


# Erasure (v4-types section 7) ---------------------------------------------------------


def erase_types(libs: LibraryTable, prog: A.Program) -> A.Program:
    """Rewrites every ``TypeAnnotate`` into the ``Let`` plus ``Emit`` section 7
    specifies, resolving and closing its type first. A ``TypeDecl`` is left in
    place; a ``TypeEmit`` is dropped."""
    return A.Program(prog.kind, _erase_expr(libs, prog, prog.root))


def _erase_expr(libs: LibraryTable, prog: A.Program, e: A.Expr) -> A.Expr:
    def go(x: A.Expr) -> A.Expr:
        return _erase_expr(libs, prog, x)

    t = e.t
    if t in ("Path", "StringLit", "NumberLit", "BoolLit", "NullLit", "Demand"):
        return e
    if t == "FieldAccess":
        return A.FieldAccess(go(e.target), e.fields)
    if t == "Call":
        return A.Call(go(e.fn), [go(a) for a in e.args])
    if t == "Lambda":
        return A.Lambda(e.params, go(e.body))
    if t == "Let":
        return A.Let(e.name, go(e.value), go(e.body))
    if t == "ArrayLit":
        return A.ArrayLit([go(x) for x in e.elements])
    if t == "ObjectLit":
        return A.ObjectLit([(k, go(v)) for k, v in e.fields])
    if t == "Element":
        return A.Element(
            e.tag,
            [_erase_attr(libs, prog, a) for a in e.attributes],
            go(e.value),
            [go(c) for c in e.children],
        )
    if t == "Fragment":
        return A.Fragment([go(c) for c in e.children])
    if t == "Branch":
        return A.Branch(go(e.condition), go(e.then), go(e.else_))
    if t == "Map":
        return A.Map(go(e.collection), go(e.fn))
    if t == "Filter":
        return A.Filter(go(e.collection), go(e.fn))
    if t == "Scan":
        return A.Scan(go(e.collection), go(e.initial), go(e.fn))
    if t == "Fold":
        return A.Fold(go(e.collection), go(e.initial), go(e.fn))
    if t == "Concat":
        return A.Concat(go(e.left), go(e.right))
    if t == "Import":
        return A.Import(
            e.name,
            [(k, A.PExpr(go(p.expr)) if p.t == "PExpr" else p) for k, p in e.params],
        )
    if t == "AdaptActions":
        return A.AdaptActions(go(e.target), e.adaptation, None if e.fn is None else go(e.fn))
    if t == "Constrain":
        return A.Constrain(e.name, [go(a) for a in e.args])
    if t == "Emit":
        return A.Emit(go(e.constraint), go(e.body))
    if t == "Alloc":
        return A.Alloc(e.site, go(e.key))
    if t == "TypeDecl":
        return A.TypeDecl(e.name, e.type, go(e.body))
    if t == "TypeAnnotate":
        rt = require_closed(resolve_type_expr(libs, prog, e.type))
        has_type = A.Constrain(
            "has-type",
            [A.Path(e.name, []), A.ObjectLit([("$type", A.StringLit(canonical_id(rt)))])],
        )
        return A.Let(e.name, go(e.value), A.Emit(has_type, go(e.body)))
    if t == "TypeEmit":
        return go(e.body)
    raise AssertionError(f"unknown expression {t}")


def _erase_attr(libs: LibraryTable, prog: A.Program, a: A.Attribute) -> A.Attribute:
    if a.t == "Attr":
        return A.Attr(a.name, _erase_expr(libs, prog, a.value))
    return A.ActionAttr(a.event, a.key, _erase_expr(libs, prog, a.payload))


# Type constraints (v4-types section 5) -------------------------------------------------


@dataclass
class CArgType:
    type: ResolvedType
    t: str = field(default="Type", init=False)


ResolvedConstraintArg = Union[CArgType, A.ArgScalarStr, A.ArgScalarNum, A.ArgScalarBool, A.ArgScalarNull]


def _resolve_constraint_arg(libs: LibraryTable, prog: A.Program, a: A.TypeConstraintArg) -> ResolvedConstraintArg:
    return CArgType(resolve_type_expr(libs, prog, a.type)) if a.t == "Type" else a


def _constraint_arg_equal(a: ResolvedConstraintArg, b: ResolvedConstraintArg) -> bool:
    if a.t != b.t:
        return False
    if a.t == "Type":
        return resolved_type_equal(a.type, b.type)
    if a.t == "ScalarNull":
        return True
    if a.t == "ScalarBool":
        return a.value is b.value
    return a.value == b.value


def _collect_type_emits(e: A.Expr) -> list[tuple[str, list[A.TypeConstraintArg]]]:
    own = [(e.name, e.args)] if e.t == "TypeEmit" else []
    for sub in A.sub_exprs(e):
        own.extend(_collect_type_emits(sub))
    return own


def _dedupe_first(xs):
    out: list = []
    for x in xs:
        seen = any(
            n == x[0]
            and len(args) == len(x[1])
            and all(_constraint_arg_equal(a, b) for a, b in zip(args, x[1]))
            for n, args in out
        )
        if not seen:
            out.append(x)
    return out


def type_constraints(libs: LibraryTable, prog: A.Program) -> list[tuple[str, list[ResolvedConstraintArg]]]:
    """Every ``!type-constraint`` this program's own chain collects."""
    return _dedupe_first(
        [
            (name, [_resolve_constraint_arg(libs, prog, a) for a in args])
            for name, args in _collect_type_emits(prog.root)
        ]
    )


def deep_type_constraints(libs: LibraryTable, prog: A.Program) -> list[tuple[str, list[ResolvedConstraintArg]]]:
    out = type_constraints(libs, prog)
    for name in transitive_import_names(libs, prog):
        p = libs.get(name)
        if p is not None:
            out.extend(type_constraints(libs, p))
    return _dedupe_first(out)


# Type references (v4-types section 9) ----------------------------------------------------


def program_type_roots(libs: LibraryTable, prog: A.Program) -> list[ResolvedType]:
    """Every ``TypeExpr`` in a type-bearing position of ``prog``'s own syntax, resolved."""

    def everywhere(e: A.Expr) -> list[A.TypeExpr]:
        out = list(type_exprs_in(e))
        for sub in A.sub_exprs(e):
            out.extend(everywhere(sub))
        return out

    return [resolve_type_expr(libs, prog, t) for t in everywhere(prog.root)]


def type_references(libs: LibraryTable, prog: A.Program) -> list[str]:
    return sorted_strings(canonical_id(rt) for rt in program_type_roots(libs, prog))


def deep_type_references(libs: LibraryTable, prog: A.Program) -> list[str]:
    out = set(type_references(libs, prog))
    for name in transitive_import_names(libs, prog):
        p = libs.get(name)
        if p is not None:
            out.update(type_references(libs, p))
    return sorted_strings(out)
