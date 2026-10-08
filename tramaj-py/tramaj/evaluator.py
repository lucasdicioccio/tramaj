"""``Value``, the environment, and the evaluator: concrete and symbolic modes
(``specs/reference.md`` sections 3, 6, 7, 10, 11; ``specs/v3-symbols.md``
sections 1.9, 4-6; ``specs/v4-types.md`` sections 7-8).

Numbers are two types (reference.md section 3): ``VInt`` holds a Python
``int`` inside the signed 64-bit range and ``VFloat`` a finite Python
``float`` that is never a negative zero. Nothing converts between the two
unless the program says so, with ``real`` or ``floor``.

The arithmetic profile (section 11) is an option of each evaluation, off by
default: ``run_program(..., arithmetic=True)`` puts its ten names in the
initial environment, of the program and of every library it imports."""

from __future__ import annotations

import math
from fractions import Fraction
from dataclasses import dataclass, field
from typing import Optional, Union

from . import ast as A
from .analysis import ARITHMETIC_NAMES, symbol_sites
from .jsonval import (
    Json,
    compact_json,
    display_string,
    in_integer_range,
    json_equal,
    normalize_float,
    normalize_integer,
    utf16_key,
)
from .node import (
    ActionAttr,
    AttributeAttr,
    ElementNode,
    FragmentNode,
    Node,
    NodeAttribute,
    TextNode,
    map_actions,
    node_to_json,
)
from .typesys import (
    ResolvedConstraintArg,
    ResolvedType,
    TramajTypeError,
    canonical_id,
    deep_type_constraints,
    erase_types,
    program_type_roots,
    type_closure,
)

LibraryTable = dict  # import name -> Program

EVAL_ERROR_KINDS = (
    "UnboundName", "PathNotFound", "TypeMismatch", "ConcatMismatch", "UnknownLibrary",
    "ImportCycle", "InLibrary", "SymbolsUnavailable", "NotConcrete",
    "AllocationInLibrary", "TypeErr", "NotRepresentable",
)


class EvalError(Exception):
    """Error kinds from ``specs/reference.md`` section 12, plus v3's symbol
    kinds and the one v4 static failure. ``str(e)`` always leads with the bare
    kind, which is what the corpus harness matches on."""

    def __init__(self, kind: str, detail: str, cause: Optional["EvalError"] = None) -> None:
        super().__init__(kind if detail == "" else f"{kind} {detail}")
        self.kind = kind
        self.detail = detail
        self.cause = cause

    @staticmethod
    def unbound_name(name: str) -> "EvalError":
        return EvalError("UnboundName", name)

    @staticmethod
    def path_not_found(path: list[str]) -> "EvalError":
        return EvalError("PathNotFound", compact_json(path))

    @staticmethod
    def type_mismatch(m: str) -> "EvalError":
        return EvalError("TypeMismatch", m)

    @staticmethod
    def concat_mismatch(m: str) -> "EvalError":
        return EvalError("ConcatMismatch", m)

    @staticmethod
    def unknown_library(name: str) -> "EvalError":
        return EvalError("UnknownLibrary", name)

    @staticmethod
    def import_cycle(name: str) -> "EvalError":
        return EvalError("ImportCycle", name)

    @staticmethod
    def in_library(name: str, e: "EvalError") -> "EvalError":
        return EvalError("InLibrary", f"{name} ({e})", e)

    @staticmethod
    def symbols_unavailable(m: str) -> "EvalError":
        return EvalError("SymbolsUnavailable", m)

    @staticmethod
    def not_concrete(who: str) -> "EvalError":
        return EvalError("NotConcrete", who)

    @staticmethod
    def allocation_in_library(name: str) -> "EvalError":
        return EvalError("AllocationInLibrary", name)

    @staticmethod
    def not_representable(m: str) -> "EvalError":
        """An arithmetic operation has no result in the type of its operands
        (reference.md section 12): integer overflow, a zero divisor, a
        non-finite float."""
        return EvalError("NotRepresentable", m)

    @staticmethod
    def type_err(e: TramajTypeError) -> "EvalError":
        return EvalError("TypeErr", str(e))


# Values ---------------------------------------------------------------------


@dataclass
class VNull:
    t: str = field(default="null", init=False)


@dataclass
class VBool:
    value: bool
    t: str = field(default="bool", init=False)


@dataclass
class VInt:
    """An integer: exact, inside the signed 64-bit range."""

    value: int
    t: str = field(default="int", init=False)


@dataclass
class VFloat:
    """A float: a finite double, never a negative zero."""

    value: float
    t: str = field(default="float", init=False)


@dataclass
class VStr:
    value: str
    t: str = field(default="str", init=False)


@dataclass
class VArray:
    items: list["Value"]
    t: str = field(default="array", init=False)


@dataclass
class VObject:
    fields: dict  # str -> Value, insertion ordered
    t: str = field(default="object", init=False)


@dataclass
class VNode:
    node: Node
    t: str = field(default="node", init=False)


@dataclass
class VClosure:
    params: list[str]
    body: A.Expr
    env: dict
    t: str = field(default="closure", init=False)


@dataclass
class VBuiltin:
    name: str
    t: str = field(default="builtin", init=False)


@dataclass
class VImportResult:
    fields: dict
    t: str = field(default="importResult", init=False)


@dataclass
class Pending:
    name: str
    params: dict
    queued: list  # of (adaptation, fn or None)


@dataclass
class VImport:
    pending: Pending
    t: str = field(default="import", init=False)


@dataclass
class VSymbol:
    """A symbol (``v3-symbols.md`` section 1.1): an id plus a projection path (section 1.6)."""

    id: str
    path: list[str]
    t: str = field(default="symbol", init=False)


@dataclass
class VConstraint:
    name: str
    args: list["Value"]
    t: str = field(default="constraint", init=False)


@dataclass
class VTerm:
    """A term (``v3-symbols.md`` section 1.9): an arithmetic operation left
    unevaluated because one of its operands is a symbol or a term. ``args``
    are the flattened operands exactly as written, each a ``VInt``, a
    ``VFloat``, a ``VSymbol`` or a ``VTerm``, nothing folded or simplified."""

    op: str
    args: list["Value"]
    t: str = field(default="term", init=False)


Value = Union[
    VNull, VBool, VInt, VFloat, VStr, VArray, VObject, VNode, VClosure, VBuiltin,
    VImportResult, VImport, VSymbol, VConstraint, VTerm,
]

Env = dict


@dataclass
class SymbolEntry:
    id: str
    origin: dict  # {"kind": "alloc", "site", "key"} | {"kind": "demand", "path"}
    binding: Optional[str]


@dataclass
class Emissions:
    """What evaluation accumulates alongside its result (``v3-symbols.md``
    section 4): emitted constraints and allocated symbol-table entries, each in
    evaluation order and deduplicated once, globally, at the top."""

    constraints: list[Value] = field(default_factory=list)
    symbols: list[SymbolEntry] = field(default_factory=list)


@dataclass
class EvalCtx:
    libs: LibraryTable
    in_progress: frozenset
    mode: str
    is_root: bool
    emissions: Emissions
    # Whether the arithmetic profile is on for this evaluation: a library's
    # initial environment follows the root's.
    arithmetic: bool = False


def _enter_library(name: str, ctx: EvalCtx) -> EvalCtx:
    return EvalCtx(ctx.libs, ctx.in_progress | {name}, ctx.mode, False, ctx.emissions, ctx.arithmetic)


# Entry points ---------------------------------------------------------------


@dataclass
class Output:
    t: str  # "node" | "value"
    node: Optional[Node] = None
    value: Json = None


def eval_program(
    mode: str, libs: LibraryTable, ctx: Json, program: A.Program, *, arithmetic: bool = False
) -> Output:
    """Evaluates to a node or a JSON value. ``arithmetic`` turns the
    arithmetic profile on for this evaluation (see ``run_program``)."""
    return _eval_program_with_emissions(mode, libs, ctx, program, arithmetic)[0]


def _with_type_errors(f):
    try:
        return f()
    except TramajTypeError as e:
        raise EvalError.type_err(e) from e


def _eval_program_with_emissions(
    mode: str, libs: LibraryTable, ctx: Json, program: A.Program, arithmetic: bool = False
):
    if mode not in ("concrete", "symbolic"):
        raise ValueError(f"unknown mode {mode!r}")
    erased = _with_type_errors(lambda: erase_types(libs, program))
    ctx_val = _checked_from_json(mode, arithmetic, ctx)
    emissions = Emissions()
    eval_ctx = EvalCtx(libs, frozenset(), mode, True, emissions, arithmetic)
    env = _initial_env(ctx_val, arithmetic)
    v = _eval_expr(eval_ctx, env, erased.root)
    if v.t == "node":
        output = Output("node", node=v.node)
    else:
        output = Output("value", value=to_json(v))
    return output, _dedupe(emissions)


def _dedupe(e: Emissions) -> Emissions:
    """Two constraints with the same name and equal arguments are one
    constraint, and two symbol-table entries with the same id are one entry,
    each kept at the position of the first."""
    constraints: list[Value] = []
    for c in e.constraints:
        if not any(_constraint_eq(x, c) for x in constraints):
            constraints.append(c)
    symbols: list[SymbolEntry] = []
    seen: set[str] = set()
    for s in e.symbols:
        if s.id not in seen:
            seen.add(s.id)
            symbols.append(s)
    return Emissions(constraints, symbols)


def _constraint_eq(a: Value, b: Value) -> bool:
    if a.t != "constraint" or b.t != "constraint":
        return False
    if a.name != b.name or len(a.args) != len(b.args):
        return False
    for x, y in zip(a.args, b.args):
        try:
            if not json_equal(to_json(x), to_json(y)):
                return False
        except EvalError:
            return False
    return True


def run_program(
    mode: str, libs: LibraryTable, ctx: Json, program: A.Program, *, arithmetic: bool = False
) -> Json:
    """Evaluates and serializes to the wire JSON a host compares against ``expected.json``.

    ``arithmetic`` is reference.md section 11's arithmetic profile, per
    evaluation and off by default. With it on, the ten names of
    ``analysis.ARITHMETIC_NAMES`` are in the initial environment of the
    program and of every library it imports, and a seeded term is accepted in
    symbolic mode. With it off they are unbound, so a program that uses one
    fails with ``UnboundName``; ``analysis.deep_arithmetic_ops`` says so
    beforehand.

    The context is a ``Json`` value whose numbers are typed by their Python
    type: an ``int`` is an integer and a ``float`` a float. Read JSON text
    with ``jsonval.parse_json`` (or the standard ``json`` module), which keep
    ``3`` and ``3.0`` apart. An ``int`` outside the signed 64-bit range and a
    non-finite ``float`` are refused with a ``TypeMismatch``."""
    output, emissions = _eval_program_with_emissions(mode, libs, ctx, program, arithmetic)
    root = node_to_json(output.node) if output.t == "node" else output.value
    if mode == "concrete":
        return root
    kind = "document" if output.t == "node" else "expression"
    types, type_constraints = _with_type_errors(lambda: _build_types_info(libs, program))
    sorted_types = sorted(types.items(), key=lambda kv: utf16_key(kv[0]))
    return {
        "format": "tramaj/symbolic/1",
        "kind": kind,
        "root": root,
        "symbols": [_symbol_entry_to_json(s) for s in emissions.symbols],
        "constraints": [_constraint_to_json(c) for c in emissions.constraints],
        "types": [{"id": cid, "definition": _resolved_type_to_json(rt)} for cid, rt in sorted_types],
        "type-constraints": [_type_constraint_to_json(tc) for tc in type_constraints],
    }


def _build_types_info(libs: LibraryTable, prog: A.Program):
    roots = program_type_roots(libs, prog)
    return type_closure(libs, prog, roots), deep_type_constraints(libs, prog)


def _resolved_type_to_json(rt: ResolvedType) -> Json:
    if rt.t == "Prim":
        return {"kind": "prim", "name": rt.name}
    if rt.t == "Array":
        return {"kind": "array", "element": _resolved_type_to_json(rt.element)}
    if rt.t == "Record":
        return {
            "kind": "record",
            "fields": [{"name": n, "type": _resolved_type_to_json(t)} for n, t in rt.fields],
        }
    if rt.t == "Union":
        return {
            "kind": "union",
            "arms": [
                {"name": n} if p is None else {"name": n, "payload": _resolved_type_to_json(p)}
                for n, p in rt.arms
            ],
        }
    if rt.t == "Ref":
        return {"kind": "ref", "id": canonical_id(rt)}
    return {"kind": "var", "path": list(rt.path)}


def _type_constraint_to_json(tc) -> Json:
    name, args = tc
    out = []
    for a in args:
        if a.t == "Type":
            out.append({"$type": canonical_id(a.type)})
        elif a.t == "ScalarNull":
            out.append(None)
        else:
            out.append(a.value)
    return {"name": name, "arguments": out}


def _constraint_to_json(v: Value) -> Json:
    if v.t != "constraint":
        return _try_to_json(v)
    return {"name": v.name, "arguments": [_try_to_json(a) for a in v.args]}


def _try_to_json(v: Value) -> Json:
    try:
        return to_json(v)
    except EvalError:
        return None


def _symbol_entry_to_json(e: SymbolEntry) -> Json:
    return {"id": e.id, "origin": dict(e.origin), "binding": e.binding}


BUILTIN_NAMES = (
    "cardinality", "count", "str", "not", "and", "or", "eq", "lt", "lte", "gt", "gte",
    "has", "lookup", "concat", "append", "format-number",
)


def _initial_env(ctx_val: Value, arithmetic: bool) -> Env:
    """``$ctx`` and the builtins. The arithmetic names are bound only with the
    arithmetic profile on (reference.md section 11); without it they are
    unbound, like any other name the program did not bind."""
    env: Env = {n: VBuiltin(n) for n in BUILTIN_NAMES}
    if arithmetic:
        for n in ARITHMETIC_NAMES:
            env[n] = VBuiltin(n)
    env["ctx"] = ctx_val
    return env


# Core evaluation --------------------------------------------------------------


def _eval_expr(ctx: EvalCtx, env: Env, e: A.Expr) -> Value:
    t = e.t
    if t == "Path":
        v = env.get(e.root)
        if v is None:
            raise EvalError.unbound_name(e.root)
        return _walk_fields(ctx, [e.root, *e.fields], v, e.fields)
    if t == "FieldAccess":
        return _walk_fields(ctx, e.fields, _eval_expr(ctx, env, e.target), e.fields)
    if t == "Call":
        fn_val = _eval_expr(ctx, env, e.fn)
        arg_vals = [_eval_expr(ctx, env, a) for a in e.args]
        return _apply(ctx, _describe_callee(e.fn), fn_val, arg_vals)
    if t == "Lambda":
        return VClosure(e.params, e.body, dict(env))
    if t == "Let":
        v = _eval_bindable(ctx, env, None if A.is_hidden_name(e.name) else e.name, e.value)
        env2 = dict(env)
        env2[e.name] = v
        return _eval_expr(ctx, env2, e.body)
    if t == "StringLit":
        return VStr(e.value)
    if t == "NumberLit":
        return VFloat(e.value) if isinstance(e.value, float) else VInt(e.value)
    if t == "BoolLit":
        return VBool(e.value)
    if t == "NullLit":
        return VNull()
    if t == "ArrayLit":
        return VArray([_eval_expr(ctx, env, x) for x in e.elements])
    if t == "ObjectLit":
        fields: dict = {}
        for k, sub in e.fields:
            fields[k] = _eval_expr(ctx, env, sub)
        return VObject(fields)
    if t == "Element":
        attributes = [_eval_attribute(ctx, env, a) for a in e.attributes]
        value = to_json(_eval_expr(ctx, env, e.value))
        children = _eval_children(ctx, env, e.children)
        return VNode(ElementNode(e.tag, attributes, value, children, {}))
    if t == "Fragment":
        return VNode(FragmentNode(_eval_children(ctx, env, e.children), {}))
    if t == "Branch":
        cond = _require_bool("a branch condition", _eval_expr(ctx, env, e.condition))
        return _eval_expr(ctx, env, e.then if cond else e.else_)
    if t == "Map":
        items = _eval_collection(ctx, env, "map", e.collection)
        fn_val = _eval_expr(ctx, env, e.fn)
        return VArray([_apply(ctx, "map", fn_val, [item]) for item in items])
    if t == "Filter":
        items = _eval_collection(ctx, env, "filter", e.collection)
        fn_val = _eval_expr(ctx, env, e.fn)
        kept = []
        for item in items:
            if _require_bool("a filter predicate", _apply(ctx, "filter", fn_val, [item])):
                kept.append(item)
        return VArray(kept)
    if t == "SortBy":
        who = "sort-by-descending" if e.descending else "sort-by"
        items = _eval_collection(ctx, env, who, e.collection)
        return _sort_by(ctx, who, e.descending, items, _eval_expr(ctx, env, e.fn))
    if t == "Scan":
        items = _eval_collection(ctx, env, "scan", e.collection)
        acc = _eval_expr(ctx, env, e.initial)
        fn_val = _eval_expr(ctx, env, e.fn)
        out = [acc]
        for item in items:
            acc = _apply(ctx, "scan", fn_val, [acc, item])
            out.append(acc)
        return VArray(out)
    if t == "Fold":
        items = _eval_collection(ctx, env, "fold", e.collection)
        acc = _eval_expr(ctx, env, e.initial)
        fn_val = _eval_expr(ctx, env, e.fn)
        for item in items:
            acc = _apply(ctx, "fold", fn_val, [acc, item])
        return acc
    if t == "Concat":
        return _concat_values(_eval_expr(ctx, env, e.left), _eval_expr(ctx, env, e.right))
    if t == "Import":
        params: dict = {}
        for k, p in e.params:
            if p.t == "PExpr":
                params[k] = _eval_expr(ctx, env, p.expr)
            elif p.t == "PFromContext":
                ctx_val = env.get("ctx")
                if ctx_val is None:
                    raise EvalError.unbound_name("ctx")
                params[k] = _walk_fields(ctx, ["ctx", *p.path], ctx_val, p.path)
            # A ``%``-marked entry supplies a type, not a value.
        return VImport(Pending(e.name, params, []))
    if t == "AdaptActions":
        target = _eval_expr(ctx, env, e.target)
        fn_val = None if e.fn is None else _eval_expr(ctx, env, e.fn)
        return _adapt_value(ctx, e.adaptation, fn_val, target)
    if t == "Constrain":
        args = [_eval_expr(ctx, env, a) for a in e.args]
        for a in args:
            to_json(a)
        return VConstraint(e.name, args)
    if t == "Emit":
        cv = _eval_expr(ctx, env, e.constraint)
        ctx.emissions.constraints.extend(_collect_constraints(cv))
        return _eval_expr(ctx, env, e.body)
    if t in ("Alloc", "Demand"):
        return _eval_bindable(ctx, env, None, e)
    if t == "TypeDecl":
        return _eval_expr(ctx, env, e.body)
    if t == "TypeAnnotate":
        v = _eval_bindable(ctx, env, e.name, e.value)
        env2 = dict(env)
        env2[e.name] = v
        return _eval_expr(ctx, env2, e.body)
    if t == "TypeEmit":
        return _eval_expr(ctx, env, e.body)
    raise AssertionError(f"unknown expression {t}")


def _eval_bindable(ctx: EvalCtx, env: Env, binding: Optional[str], e: A.Expr) -> Value:
    if e.t == "Alloc":
        return _eval_alloc(ctx, env, binding, e.site, e.key)
    if e.t == "Demand":
        return _eval_demand(ctx, env, binding, e.path)
    return _eval_expr(ctx, env, e)


def _eval_alloc(ctx: EvalCtx, env: Env, binding: Optional[str], site: int, key_expr: A.Expr) -> Value:
    key_json = _require_concrete("?(...)", _eval_expr(ctx, env, key_expr))
    if ctx.mode == "concrete":
        raise EvalError.symbols_unavailable(
            "?(...) would have to allocate a symbol, which concrete mode cannot represent"
        )
    sid = f"#{site}:{compact_json(key_json)}"
    ctx.emissions.symbols.append(SymbolEntry(sid, {"kind": "alloc", "site": site, "key": key_json}, binding))
    return VSymbol(sid, [])


def _eval_demand(ctx: EvalCtx, env: Env, binding: Optional[str], path: list[str]) -> Value:
    n_constraints = len(ctx.emissions.constraints)
    n_symbols = len(ctx.emissions.symbols)
    try:
        return _eval_expr(ctx, env, A.Path("ctx", path))
    except EvalError as err:
        del ctx.emissions.constraints[n_constraints:]
        del ctx.emissions.symbols[n_symbols:]
        if err.kind != "PathNotFound" or not ctx.is_root:
            raise
        if ctx.mode == "concrete":
            raise EvalError.symbols_unavailable(
                "?ctx....  unsupplied at the root would have to allocate a symbol, which concrete mode cannot represent"
            ) from None
        sid = "#ctx" + "".join(f".{p}" for p in path)
        ctx.emissions.symbols.append(SymbolEntry(sid, {"kind": "demand", "path": list(path)}, binding))
        return VSymbol(sid, [])


def _collect_constraints(v: Value) -> list[Value]:
    if v.t == "constraint":
        return [v]
    if v.t == "array":
        out = []
        for x in v.items:
            out.extend(_collect_constraints(x))
        return out
    raise EvalError.type_mismatch(f"! expects a constraint or an array of them, got {_describe_value(v)}")


def _describe_callee(e: A.Expr) -> str:
    return ".".join([e.root, *e.fields]) if e.t == "Path" else "a call"


# Documents ------------------------------------------------------------------


def _eval_attribute(ctx: EvalCtx, env: Env, a: A.Attribute) -> NodeAttribute:
    if a.t == "Attr":
        return AttributeAttr(a.name, to_json(_eval_expr(ctx, env, a.value)))
    return ActionAttr(a.event, a.key, to_json(_eval_expr(ctx, env, a.payload)))


def _eval_children(ctx: EvalCtx, env: Env, children: list[A.Expr]) -> list[Node]:
    out: list[Node] = []
    for e in children:
        out.extend(_child_nodes(_eval_expr(ctx, env, e)))
    return out


def _child_nodes(v: Value) -> list[Node]:
    if v.t == "node":
        return [v.node]
    if v.t == "array":
        out = []
        for x in v.items:
            out.extend(_child_nodes(x))
        return out
    return [TextNode(to_json(v), {})]


# Application ------------------------------------------------------------------


def _apply(ctx: EvalCtx, who: str, f: Value, args: list[Value]) -> Value:
    if f.t == "closure":
        if len(f.params) != len(args):
            raise EvalError.type_mismatch(
                f"closure expects {len(f.params)} argument(s), got {len(args)}"
            )
        env2 = dict(f.env)
        for p, a in zip(f.params, args):
            env2[p] = a
        return _eval_expr(ctx, env2, f.body)
    if f.t == "builtin":
        return _eval_builtin(f.name, args)
    if f.t == "import":
        if len(args) != 1:
            raise EvalError.type_mismatch(
                f'{who}: the import of "{f.pending.name}" expects exactly 1 argument, the parameters to add'
            )
        only = args[0]
        if only.t != "object":
            raise EvalError.type_mismatch(
                f'{who}: the import of "{f.pending.name}" takes an object of parameters, got {_describe_value(only)}'
            )
        params = dict(f.pending.params)
        params.update(only.fields)
        return VImport(Pending(f.pending.name, params, list(f.pending.queued)))
    raise EvalError.type_mismatch(f"{who} is not callable: {_describe_value(f)}")


def _eval_collection(ctx: EvalCtx, env: Env, who: str, e: A.Expr) -> list[Value]:
    v = _eval_expr(ctx, env, e)
    if v.t == "array":
        return v.items
    if _is_symbolic(v):
        raise EvalError.not_concrete(who)
    raise EvalError.type_mismatch(f"{who} expects an array as its first argument, got {_describe_value(v)}")


# Sorting (reference.md section 11) ---------------------------------------------

_KEY_TYPES = ("int", "float", "str")


def _sort_by(ctx: EvalCtx, who: str, descending: bool, items: list[Value], fn: Value) -> Value:
    """``sort-by`` and ``sort-by-descending`` over an evaluated list.

    The key function is applied exactly once per element, in index order, and
    each key is checked as soon as it is known, so the first element whose
    application or key fails decides the error, before anything is reordered.
    The keys of one call are all integers, all floats or all strings; a
    symbol or a term is ``NotConcrete``, anything else a ``TypeMismatch``. The
    elements themselves are never inspected.

    The order: element ``i`` precedes element ``j`` when its key is smaller
    (larger, when descending), or when the keys are equal and ``i < j``.
    Python's sort is stable in both directions, ``reverse=True`` included, so
    a descending sort is not the reversal of the ascending one. Python
    compares ``str`` by code point, which is the order asked for; it is not
    ``utf16_key``, which this package uses to write object keys."""
    keys: list[Value] = []
    for item in items:
        k = _apply(ctx, who, fn, [item])
        if _is_symbolic(k):
            raise EvalError.not_concrete(who)
        if k.t not in _KEY_TYPES:
            raise EvalError.type_mismatch(
                f"{who} expects each key to be an integer, a float or a string, got {_describe_value(k)}"
            )
        if keys and k.t != keys[0].t:
            raise EvalError.type_mismatch(
                f"{who} expects keys of one type, got {_describe_value(keys[0])} and {_describe_value(k)}"
            )
        keys.append(k)
    order = sorted(range(len(items)), key=lambda i: keys[i].value, reverse=descending)
    return VArray([items[i] for i in order])


# Concat -----------------------------------------------------------------------


def _concat_values(l: Value, r: Value) -> Value:
    if _is_symbolic(l) or _is_symbolic(r):
        raise EvalError.not_concrete("<>")
    if l.t == "str" and r.t == "str":
        return VStr(l.value + r.value)
    if l.t == "array" and r.t == "array":
        return VArray([*l.items, *r.items])
    if l.t == "object" and r.t == "object":
        fields = dict(l.fields)
        fields.update(r.fields)
        return VObject(fields)
    raise EvalError.concat_mismatch(f"{_describe_value(l)} and {_describe_value(r)}")


# Imports ----------------------------------------------------------------------


def _force_import(ctx: EvalCtx, pending: Pending) -> Value:
    result = _run_library(ctx, pending.name, VObject(dict(pending.params)))
    return _apply_queued(ctx, pending.queued, result)


def _run_library(ctx: EvalCtx, name: str, ctx_val: Value) -> Value:
    if name in ctx.in_progress:
        raise EvalError.import_cycle(name)
    raw_prog = ctx.libs.get(name)
    if raw_prog is None:
        raise EvalError.unknown_library(name)
    # Checked lexically before evaluating anything and deliberately not wrapped
    # in InLibrary: this is a property of the library's own source.
    if symbol_sites(raw_prog):
        raise EvalError.allocation_in_library(name)
    prog = _with_type_errors(lambda: erase_types(ctx.libs, raw_prog))
    ctx2 = _enter_library(name, ctx)
    try:
        statements, root = A.unlets(prog.root)
        lib_env = _initial_env(ctx_val, ctx.arithmetic)
        binding_names: list[str] = []
        for stmt in statements:
            if stmt.t in ("Let", "Annotate"):
                lib_env[stmt.name] = _eval_expr(ctx2, lib_env, stmt.value)
                if not A.is_hidden_name(stmt.name):
                    binding_names.append(stmt.name)
            elif stmt.t == "Emit":
                ctx2.emissions.constraints.extend(
                    _collect_constraints(_eval_expr(ctx2, lib_env, stmt.constraint))
                )
        rendered = _eval_expr(ctx2, lib_env, root)
        vals = {n: lib_env[n] for n in binding_names}
        return VImportResult({"rendered": rendered, "vals": VImportResult(vals)})
    except EvalError as e:
        raise EvalError.in_library(name, e) from e


# Action adaptation ---------------------------------------------------------------


def _adapt_value(ctx: EvalCtx, adaptation: A.ActionAdaptation, fn_val: Optional[Value], v: Value) -> Value:
    if v.t == "node":
        return VNode(
            map_actions(
                v.node,
                lambda event, key, payload: _adapt_action(ctx, adaptation, fn_val, event, key, payload),
            )
        )
    if v.t == "importResult":
        return VImportResult({k: _adapt_value(ctx, adaptation, fn_val, x) for k, x in v.fields.items()})
    if v.t == "array":
        return VArray([_adapt_value(ctx, adaptation, fn_val, x) for x in v.items])
    if v.t == "object":
        return VObject({k: _adapt_value(ctx, adaptation, fn_val, x) for k, x in v.fields.items()})
    if v.t == "import":
        p = v.pending
        return VImport(Pending(p.name, p.params, [*p.queued, (adaptation, fn_val)]))
    return v


def _apply_queued(ctx: EvalCtx, queued: list, v: Value) -> Value:
    for adaptation, fn in queued:
        v = _adapt_value(ctx, adaptation, fn, v)
    return v


def _adapt_action(
    ctx: EvalCtx,
    adaptation: A.ActionAdaptation,
    fn_val: Optional[Value],
    event: str,
    key: str,
    payload: Json,
) -> NodeAttribute:
    key2 = A.adapt_key(adaptation, key)
    if fn_val is None:
        return ActionAttr(event, key2, payload)
    action_obj = VObject({"eventType": VStr(event), "key": VStr(key2), "payload": _from_json(payload)})
    result = to_json(_apply(ctx, "adapt-actions", fn_val, [action_obj]))
    if not isinstance(result, dict):
        raise EvalError.type_mismatch(
            "adapt-actions: the function must return an object with an eventType field"
        )
    event2 = result.get("eventType")
    if not isinstance(event2, str):
        raise EvalError.type_mismatch(
            'adapt-actions: the function\'s result needs a string "eventType" field'
        )
    payload2 = result["payload"] if "payload" in result else None
    return ActionAttr(event2, key2, payload2)


# Paths and fields -------------------------------------------------------------


def _walk_fields(ctx: EvalCtx, context: list[str], v: Value, fields: list[str]) -> Value:
    if not fields:
        return v
    fld = fields[0]
    rest = fields[1:]
    if v.t in ("object", "importResult"):
        nxt = v.fields.get(fld)
        if nxt is None:
            raise EvalError.path_not_found(context)
        return _walk_fields(ctx, context, nxt, rest)
    if v.t == "import":
        return _walk_fields(ctx, context, _force_import(ctx, v.pending), fields)
    if v.t == "symbol":
        # Projection (section 1.6): reads nothing, and is never rejected.
        return VSymbol(v.id, [*v.path, *fields])
    raise EvalError.type_mismatch(
        f'cannot read field "{fld}" of {_describe_value(v)} in path "{".".join(context)}"'
    )


# Conversion ------------------------------------------------------------------


def to_json(v: Value) -> Json:
    """Down to JSON, at the boundaries where only JSON is meaningful."""
    t = v.t
    if t == "null":
        return None
    if t in ("bool", "int", "float", "str"):
        return v.value
    if t == "array":
        return [to_json(x) for x in v.items]
    if t == "object":
        return {k: to_json(x) for k, x in v.fields.items()}
    if t == "node":
        raise EvalError.type_mismatch(
            "a document node is not a plain value -- nest it as a child rather than using it where a value is expected"
        )
    if t == "closure":
        raise EvalError.type_mismatch("expected a value, got a function -- call it first, e.g. $my-fn(...)")
    if t == "builtin":
        raise EvalError.type_mismatch(f'expected a value, got the builtin "{v.name}" -- call it first')
    if t == "importResult":
        raise EvalError.type_mismatch(
            "expected a value, got an import result -- read .rendered, .vals, or a binding name from it first"
        )
    if t == "import":
        raise EvalError.type_mismatch(
            f'expected a value, got the import of "{v.pending.name}" -- read .rendered or .vals from it to run it first'
        )
    if t == "symbol":
        return {"$sym": v.id, "path": list(v.path)}
    if t == "term":
        # A term crosses wherever a symbol does, as section 5.3's other tagged
        # shape. Its operands are numbers, symbols and terms, and each number
        # keeps its type, which the residual law depends on.
        return {"$term": v.op, "arguments": [to_json(a) for a in v.args]}
    if t == "constraint":
        raise EvalError.type_mismatch(
            f'a constraint ("{v.name}") cannot cross a JSON boundary -- only "!" may consume it'
        )
    raise AssertionError(f"unknown value {t}")


def _is_symbolic(v: Value) -> bool:
    """Whether a value is itself a symbol or a term (``v3-symbols.md`` section
    1.9): the depth at which a container, a collection, a condition or an
    operand is refused. A concrete structure that merely holds one is not
    special (section 1.7); ``_contains_symbol`` is the other depth."""
    return v.t in ("symbol", "term")


def _contains_symbol(v: Value) -> bool:
    """Whether a value is, or contains, a symbol or a term."""
    if _is_symbolic(v):
        return True
    if v.t == "array":
        return any(_contains_symbol(x) for x in v.items)
    if v.t == "object":
        return any(_contains_symbol(x) for x in v.fields.values())
    return False


def _require_concrete(who: str, v: Value) -> Json:
    if _contains_symbol(v):
        raise EvalError.not_concrete(who)
    return to_json(v)


def _from_json(v: Json) -> Value:
    """A JSON value this evaluator produced, back as a ``Value``: its numbers
    are already values, so nothing is checked. The context goes through
    ``_checked_from_json`` instead."""
    if v is None:
        return VNull()
    if isinstance(v, bool):
        return VBool(v)
    if isinstance(v, int):
        return VInt(v)
    if isinstance(v, float):
        return VFloat(v)
    if isinstance(v, str):
        return VStr(v)
    if isinstance(v, list):
        return VArray([_from_json(x) for x in v])
    return VObject({k: _from_json(x) for k, x in v.items()})


def _checked_from_json(mode: str, arithmetic: bool, v: Json) -> Value:
    """The input context's boundary. It is decoded whole, before evaluation
    starts, so what it refuses does not depend on what the program reads, and
    every refusal is a ``TypeMismatch``.

    Numbers (reference.md section 3): an ``int`` is an integer and a ``float``
    a float, as the JSON text had them. An integer outside the signed 64-bit
    range is refused, never rounded, and so is a float that is not finite
    (what ``1e400`` reads as); a negative zero is ``0.0``.

    Reserved keys (``v3-symbols.md`` section 5.3): ``"$sym"``, ``"$type"`` and
    ``"$term"`` are refused as ordinary object keys, at any depth and in every
    profile. In symbolic mode, seeding accepts a well-formed
    ``{"$sym": ..., "path": [...]}`` back as a symbol and, with the arithmetic
    profile on, a well-formed term back as a term."""
    if v is None:
        return VNull()
    if isinstance(v, bool):
        return VBool(v)
    if isinstance(v, int):
        try:
            return VInt(normalize_integer(v))
        except ValueError as e:
            raise EvalError.type_mismatch(f"the context holds a number that is not a value: {e}") from None
    if isinstance(v, float):
        try:
            return VFloat(normalize_float(v))
        except ValueError as e:
            raise EvalError.type_mismatch(f"the context holds a number that is not a value: {e}") from None
    if isinstance(v, str):
        return VStr(v)
    if isinstance(v, list):
        return VArray([_checked_from_json(mode, arithmetic, x) for x in v])
    if not isinstance(v, dict):
        raise EvalError.type_mismatch(f"the context holds a value JSON cannot represent: {v!r}")
    if "$type" in v:
        raise EvalError.type_mismatch(
            'the context carries the reserved key "$type", which only a typed envelope may use'
        )
    if "$sym" in v:
        if mode == "concrete":
            raise EvalError.type_mismatch(
                'the context carries the reserved key "$sym", which only a symbolic envelope may use'
            )
        return _decode_symbol_ref(v["$sym"], v)
    if "$term" in v:
        if mode == "concrete":
            raise EvalError.type_mismatch(
                'the context carries the reserved key "$term", which only a symbolic envelope may use'
            )
        op = v["$term"]
        args = v.get("arguments")
        if not isinstance(op, str) or len(v) != 2 or not isinstance(args, list):
            raise EvalError.type_mismatch(
                'a "$term" object must be exactly {"$term": <op>, "arguments": [<argument>, ...]}'
            )
        return _seeded_term(arithmetic, op, [_checked_from_json(mode, arithmetic, x) for x in args])
    return VObject({k: _checked_from_json(mode, arithmetic, x) for k, x in v.items()})


def _seeded_term(arithmetic: bool, op: str, args: list[Value]) -> Value:
    """A well-formed term is one a call could have built (``v3-symbols.md``
    section 5.3), so this is the call's own check, ``_arithmetic_operands``, on
    arguments already decoded, which holds a nested term to the same rule. Two
    things a call accepts are refused first: an array, since a term holds its
    operands already flattened, and operands that are all numbers, since the
    call would have computed. Without the arithmetic profile no ``op`` is
    known, so every term is refused."""
    if not arithmetic:
        raise EvalError.type_mismatch(
            f'the context carries a term ("{op}"), which needs the arithmetic profile'
        )
    if op not in ARITHMETIC_NAMES:
        raise EvalError.type_mismatch(f'a term names an unknown operation: "{op}"')
    if any(a.t == "array" for a in args):
        raise EvalError.type_mismatch(f'a term ("{op}") holds its operands flattened, not in an array')
    operands = _arithmetic_operands(op, args)
    if not any(_is_symbolic(o) for o in operands):
        raise EvalError.type_mismatch(
            f'a term ("{op}") must hold a symbol or a term among its arguments'
        )
    return VTerm(op, operands)


def _decode_symbol_ref(sym_val: Json, obj: dict) -> Value:
    def bad_shape() -> EvalError:
        return EvalError.type_mismatch(
            'a "$sym" object must be exactly {"$sym": <id>, "path": [<segment>, ...]}'
        )

    if not isinstance(sym_val, str):
        raise bad_shape()
    if len(obj) != 2:
        raise bad_shape()
    path_arr = obj.get("path")
    if not isinstance(path_arr, list):
        raise bad_shape()
    path = []
    for x in path_arr:
        if not isinstance(x, str):
            raise EvalError.type_mismatch('a symbol reference\'s "path" must be an array of strings')
        path.append(x)
    return VSymbol(sym_val, path)


def _describe_value(v: Value) -> str:
    return {
        "null": "null",
        "bool": "a boolean",
        "int": "an integer",
        "float": "a float",
        "str": "a string",
        "array": "an array",
        "object": "an object",
        "node": "a document node",
        "closure": "a function",
        "importResult": "an import result",
        "symbol": "a symbol",
    }.get(v.t) or (
        f'a term ("{v.op}")'
        if v.t == "term"
        else
        f'the builtin "{v.name}"'
        if v.t == "builtin"
        else f'the not-yet-run import of "{v.pending.name}"'
        if v.t == "import"
        else f'a constraint ("{v.name}")'
    )


def _require_bool(who: str, v: Value) -> bool:
    if v.t == "bool":
        return v.value
    if _is_symbolic(v):
        raise EvalError.not_concrete(who)
    raise EvalError.type_mismatch(f"{who} must be a boolean, got {_describe_value(v)}")


# Builtins -------------------------------------------------------------------


def _eval_builtin(name: str, args: list[Value]) -> Value:
    def arity_err(n: int) -> EvalError:
        return EvalError.type_mismatch(f"{name} expects exactly {n} argument(s), got {len(args)}")

    if name in ("cardinality", "count"):
        if len(args) != 1:
            raise arity_err(1)
        a = args[0]
        if a.t == "array":
            return VInt(len(a.items))
        if a.t == "object":
            return VInt(len(a.fields))
        if _is_symbolic(a):
            raise EvalError.not_concrete(name)
        raise EvalError.type_mismatch(f"{name} expects an array or object, got {_describe_value(a)}")
    if name == "str":
        if len(args) != 1:
            raise arity_err(1)
        return VStr(display_string(_require_concrete(name, args[0])))
    if name == "not":
        if len(args) != 1:
            raise arity_err(1)
        return VBool(not _as_bool(name, args[0]))
    if name == "and":
        acc = True
        for a in args:
            acc = acc and _as_bool(name, a)
        return VBool(acc)
    if name == "or":
        acc = False
        for a in args:
            acc = acc or _as_bool(name, a)
        return VBool(acc)
    if name == "eq":
        if len(args) != 2:
            raise arity_err(2)
        a = _require_concrete(name, args[0])
        b = _require_concrete(name, args[1])
        return VBool(json_equal(a, b))
    if name in ("lt", "lte", "gt", "gte"):
        if len(args) != 2:
            raise arity_err(2)
        # Two integers or two floats (reference.md section 11). A mixed pair
        # is a TypeMismatch like any other pair of two types: nothing is
        # promoted, so gt(1.5, 0) is written gt(1.5, 0.0).
        na = _as_number(name, args[0])
        nb = _as_number(name, args[1])
        if na.t != nb.t:
            raise EvalError.type_mismatch(
                f"{name} expects two integers or two floats, got {_describe_value(na)} and {_describe_value(nb)}"
            )
        a, b = na.value, nb.value
        r = a < b if name == "lt" else a <= b if name == "lte" else a > b if name == "gt" else a >= b
        return VBool(r)
    if name == "has":
        if len(args) != 2:
            raise arity_err(2)
        return VBool(_has_impl(name, args[0], args[1]))
    if name == "lookup":
        if len(args) != 3:
            raise arity_err(3)
        return _lookup_impl(name, args[0], args[1], args[2])
    if name == "concat":
        out = []
        for a in args:
            out.extend(_as_array(name, a))
        return VArray(out)
    if name == "append":
        if len(args) != 2:
            raise arity_err(2)
        return VArray([*_as_array(name, args[0]), args[1]])
    if name == "format-number":
        if len(args) != 3:
            raise arity_err(3)
        return VStr(_format_number(name, args[0], args[1], args[2]))
    if name in ARITHMETIC_NAMES:
        return _arithmetic(name, args)
    raise EvalError.unbound_name(name)


def _as_bool(name: str, v: Value) -> bool:
    if v.t == "bool":
        return v.value
    raise EvalError.type_mismatch(f"{name} expects a boolean argument, got {_describe_value(v)}")


def _as_number(name: str, v: Value) -> Value:
    """A number operand, returned as it is so that its type is still there to
    check. A symbol or a term is ``NotConcrete`` (``v3-symbols.md`` section 1.5)."""
    if v.t in ("int", "float"):
        return v
    if _is_symbolic(v):
        raise EvalError.not_concrete(name)
    raise EvalError.type_mismatch(f"{name} expects a number argument, got {_describe_value(v)}")


def _as_array(name: str, v: Value) -> list[Value]:
    if v.t == "array":
        return v.items
    raise EvalError.type_mismatch(f"{name} expects an array argument, got {_describe_value(v)}")


def _as_index(key: Value) -> Optional[int]:
    """An index is a non-negative integer: ``-1`` is not one, and neither is a
    float, ``1.0`` included, since nothing converts a float into an integer here."""
    if key.t == "int" and key.value >= 0:
        return key.value
    return None


def _has_impl(name: str, container: Value, key: Value) -> bool:
    """Deliberately tolerant: a missing key, an out-of-range index, or a
    container of the wrong shape all answer false, except a symbolic
    container, which is NotConcrete rather than a lie."""
    if _is_symbolic(container):
        raise EvalError.not_concrete(name)
    if container.t == "object" and key.t == "str":
        return key.value in container.fields
    if container.t == "array":
        i = _as_index(key)
        return i is not None and i < len(container.items)
    return False


def _lookup_impl(name: str, container: Value, key: Value, fallback: Value) -> Value:
    if _is_symbolic(container):
        raise EvalError.not_concrete(name)
    if container.t == "object" and key.t == "str":
        return container.fields.get(key.value, fallback)
    if container.t == "array":
        i = _as_index(key)
        if i is None or i >= len(container.items):
            return fallback
        return container.items[i]
    return fallback


# Number formatting (reference.md section 11) -------------------------------------

_MAX_DECIMALS = 20


def _round_half_away(numerator: int, denominator: int) -> int:
    """The integer nearest to ``numerator / denominator``, the first
    non-negative and the second positive; of two equally near, the larger. On
    Python's unbounded integers this is exact. With the sign put back by the
    caller it is "ties away from zero", the one rounding rule of
    ``format-number`` and ``round``. Python's own ``round`` and ``%f`` round
    ties to even."""
    q, r = divmod(numerator, denominator)
    return q + 1 if 2 * r >= denominator else q


def _format_number(name: str, x: Value, decimals: Value, group: Value) -> str:
    """``format-number(x, decimals, group)``: positional decimal text with
    exactly ``decimals`` digits after the point.

    The arguments are examined left to right and the first that is not
    acceptable decides the error: a symbol or a term is ``NotConcrete``,
    anything else a ``TypeMismatch``, a float ``decimals`` and one outside 0
    to 20 included.

    The value rounded is the exact one: ``Fraction`` of a float is the binary
    fraction the double holds, and an integer is itself. So ``1.005`` gives
    ``1.00``, its double being a little under, and ``0.125`` gives ``0.13``,
    a real tie. There is never an exponent, and a result whose digits are all
    zero carries no sign."""
    x = _as_number(name, x)
    if decimals.t != "int":
        if _is_symbolic(decimals):
            raise EvalError.not_concrete(name)
        raise EvalError.type_mismatch(
            f"{name} expects an integer number of decimals, got {_describe_value(decimals)}"
        )
    d = decimals.value
    if d < 0 or d > _MAX_DECIMALS:
        raise EvalError.type_mismatch(f"{name} expects 0 to {_MAX_DECIMALS} decimals, got {d}")
    if group.t != "str":
        if _is_symbolic(group):
            raise EvalError.not_concrete(name)
        raise EvalError.type_mismatch(
            f"{name} expects a string as its group separator, got {_describe_value(group)}"
        )
    exact = Fraction(x.value)
    scaled = _round_half_away(abs(exact.numerator) * 10**d, exact.denominator)
    digits = str(scaled).rjust(d + 1, "0")
    whole, fraction = (digits[:-d], digits[-d:]) if d else (digits, "")
    if group.value != "":
        head = len(whole) % 3 or 3
        parts = [whole[:head]] + [whole[i : i + 3] for i in range(head, len(whole), 3)]
        whole = group.value.join(parts)
    sign = "-" if exact < 0 and scaled != 0 else ""
    return sign + whole + ("." + fraction if d else "")


# Arithmetic (reference.md section 11) ------------------------------------------

_VARIADIC = ("sum", "product")
_BINARY = ("quotient", "floor-quotient", "modulo")
_FLOATS_ONLY = ("quotient", "inverse")
_INTEGERS_ONLY = ("floor-quotient", "modulo")


def _arithmetic(name: str, args: list[Value]) -> Value:
    """One of the arithmetic builtins, applied. Operands that are all numbers
    compute; if one is a symbol or a term the result is a term holding the
    flattened operands exactly as written (``v3-symbols.md`` section 1.9).
    Every operand is checked before either happens, so a ``TypeMismatch``
    takes precedence over a ``NotRepresentable``."""
    operands = _arithmetic_operands(name, args)
    if any(_is_symbolic(o) for o in operands):
        return VTerm(name, operands)
    return _compute(name, operands)


def _flatten_operands(args: list[Value]) -> list[Value]:
    out: list[Value] = []
    for a in args:
        if a.t == "array":
            out.extend(_flatten_operands(a.items))
        else:
            out.append(a)
    return out


def _arithmetic_operands(name: str, args: list[Value]) -> list[Value]:
    """The operands of a call, checked as far as they can be without knowing
    what a symbol stands for; every refusal is a ``TypeMismatch``.

    * ``sum`` and ``product`` flatten their arguments by the rule children
      use: an array contributes each of its elements, recursively, in order.
      They need at least one operand afterwards. The others take a fixed
      count and do not flatten, so an array given to one is refused whatever
      it holds.
    * Each operand is a number, a symbol or a term. A symbol or a term stands
      for one number of either type and is not looked into.
    * The operands that are numbers agree with each other in type and with
      what the builtin accepts. Nothing is converted or promoted."""
    if name in _VARIADIC:
        operands = _flatten_operands(args)
        if not operands:
            raise EvalError.type_mismatch(
                f"{name} expects at least one operand: seed it with the zero or the one of the intended type"
            )
    else:
        arity = 2 if name in _BINARY else 1
        if len(args) != arity:
            raise EvalError.type_mismatch(f"{name} expects exactly {arity} argument(s), got {len(args)}")
        operands = list(args)
    for o in operands:
        if o.t not in ("int", "float") and not _is_symbolic(o):
            raise EvalError.type_mismatch(f"{name} expects number operands, got {_describe_value(o)}")
    numbers = [o for o in operands if not _is_symbolic(o)]
    all_ints = all(n.t == "int" for n in numbers)
    all_floats = all(n.t == "float" for n in numbers)
    if name in _FLOATS_ONLY:
        accepted, wanted = all_floats, "a float" if name == "inverse" else "two floats"
    elif name in _INTEGERS_ONLY:
        accepted, wanted = all_ints, "two integers"
    elif name in _VARIADIC:
        accepted, wanted = all_ints or all_floats, "all integers or all floats"
    else:
        # negate, floor, real and round take a number of either type.
        accepted, wanted = True, ""
    if not accepted:
        got = ", ".join(_describe_value(n) for n in numbers)
        raise EvalError.type_mismatch(f"{name} expects {wanted}, got {got}")
    return operands


def _integer_result(name: str, n: int) -> Value:
    """An integer result, or ``NotRepresentable`` outside the integer range.
    Python integers are unbounded, so the mathematical result is always in
    hand and nothing wraps: this check is the range."""
    if not in_integer_range(n):
        raise EvalError.not_representable(
            f"{name}: the result is outside the integer range, -2^63 to 2^63 - 1"
        )
    return VInt(n)


def _float_result(name: str, x: float) -> Value:
    """A float result, or ``NotRepresentable`` when it is not finite, which
    covers overflow. There is no negative zero."""
    if x != x or x in (float("inf"), float("-inf")):
        raise EvalError.not_representable(f"{name}: the result is not a finite float")
    return VFloat(0.0 if x == 0 else x)


def _float_division(name: str, a: float, b: float) -> Value:
    # Python raises on a zero divisor where IEEE 754 gives an infinity or a
    # NaN; both are the same refusal.
    if b == 0:
        raise EvalError.not_representable(f"{name}: the result is not a finite float")
    return _float_result(name, a / b)


def _compute(name: str, operands: list[Value]) -> Value:
    """The concrete rules (reference.md section 11, *Semantics*), over
    operands ``_arithmetic_operands`` accepted and that are all numbers.

    An integer step is computed over Python's unbounded integers and then
    held to the range, at every step of a fold. A float step is one Python
    ``float`` operation, which is the one IEEE 754 binary64 operation,
    rounded to nearest, ties to even; nothing is reordered or fused."""
    first = operands[0]
    if name in _VARIADIC:
        add = name == "sum"
        acc = first
        for o in operands[1:]:
            raw = acc.value + o.value if add else acc.value * o.value
            acc = _integer_result(name, raw) if first.t == "int" else _float_result(name, raw)
        return acc
    if name == "negate":
        if first.t == "int":
            return _integer_result(name, -first.value)
        return _float_result(name, -first.value)
    if name == "quotient":
        return _float_division(name, first.value, operands[1].value)
    if name == "inverse":
        return _float_division(name, 1.0, first.value)
    if name in _INTEGERS_ONLY:
        a, b = first.value, operands[1].value
        if b == 0:
            raise EvalError.not_representable(f"{name}: the divisor is zero")
        # Python's // rounds toward negative infinity and % is its remainder,
        # zero or of the sign of the divisor, which is what section 11 asks.
        # Each is checked on its own: the remainder of -2^63 by -1 is 0,
        # although the quotient is out of range.
        return _integer_result(name, a // b if name == "floor-quotient" else a % b)
    if name == "floor":
        if first.t == "int":
            return first
        # math.floor of a finite float is the exact integer.
        return _integer_result(name, math.floor(first.value))
    if name == "real":
        if first.t == "float":
            return first
        # int -> float is correctly rounded: exact up to 2^53, the nearest
        # double, ties to even, beyond.
        return VFloat(float(first.value))
    if name == "round":
        if first.t == "int":
            return first
        # The integer nearest to the exact value, ties away from zero. Nothing
        # adds 0.5, which would round 0.49999999999999994 up to 1.
        exact = Fraction(first.value)
        magnitude = _round_half_away(abs(exact.numerator), exact.denominator)
        return _integer_result(name, -magnitude if exact < 0 else magnitude)
    raise AssertionError(f"unknown arithmetic builtin {name}")
