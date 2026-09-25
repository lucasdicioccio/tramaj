"""``Value``, the environment, and the evaluator: concrete and symbolic modes
(``specs/reference.md`` sections 6, 7, 10; ``specs/v3-symbols.md`` sections 4-6;
``specs/v4-types.md`` sections 7-8). Mirrors ``tramaj-js/src/eval.ts``."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional, Union

from . import ast as A
from .analysis import symbol_sites
from .jsonval import (
    Json,
    compact_json,
    display_string,
    is_number,
    json_equal,
    normalize_number,
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
    "AllocationInLibrary", "TypeErr",
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
class VNumber:
    value: Union[int, float]
    t: str = field(default="number", init=False)


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


Value = Union[
    VNull, VBool, VNumber, VStr, VArray, VObject, VNode, VClosure, VBuiltin,
    VImportResult, VImport, VSymbol, VConstraint,
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


def _enter_library(name: str, ctx: EvalCtx) -> EvalCtx:
    return EvalCtx(ctx.libs, ctx.in_progress | {name}, ctx.mode, False, ctx.emissions)


# Entry points ---------------------------------------------------------------


@dataclass
class Output:
    t: str  # "node" | "value"
    node: Optional[Node] = None
    value: Json = None


def eval_program(mode: str, libs: LibraryTable, ctx: Json, program: A.Program) -> Output:
    return _eval_program_with_emissions(mode, libs, ctx, program)[0]


def _with_type_errors(f):
    try:
        return f()
    except TramajTypeError as e:
        raise EvalError.type_err(e) from e


def _eval_program_with_emissions(mode: str, libs: LibraryTable, ctx: Json, program: A.Program):
    if mode not in ("concrete", "symbolic"):
        raise ValueError(f"unknown mode {mode!r}")
    erased = _with_type_errors(lambda: erase_types(libs, program))
    ctx_val = _checked_from_json(mode, ctx)
    emissions = Emissions()
    eval_ctx = EvalCtx(libs, frozenset(), mode, True, emissions)
    env = _initial_env(ctx_val)
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


def run_program(mode: str, libs: LibraryTable, ctx: Json, program: A.Program) -> Json:
    """Evaluates and serializes to the wire JSON a host compares against ``expected.json``."""
    output, emissions = _eval_program_with_emissions(mode, libs, ctx, program)
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
    "has", "lookup", "concat", "append",
)


def _initial_env(ctx_val: Value) -> Env:
    env: Env = {n: VBuiltin(n) for n in BUILTIN_NAMES}
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
        v = _eval_bindable(ctx, env, e.name, e.value)
        env2 = dict(env)
        env2[e.name] = v
        return _eval_expr(ctx, env2, e.body)
    if t == "StringLit":
        return VStr(e.value)
    if t == "NumberLit":
        return VNumber(e.value)
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
    if v.t == "symbol":
        raise EvalError.not_concrete(who)
    raise EvalError.type_mismatch(f"{who} expects an array as its first argument, got {_describe_value(v)}")


# Concat -----------------------------------------------------------------------


def _concat_values(l: Value, r: Value) -> Value:
    if l.t == "symbol" or r.t == "symbol":
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
        lib_env = _initial_env(ctx_val)
        binding_names: list[str] = []
        for stmt in statements:
            if stmt.t in ("Let", "Annotate"):
                lib_env[stmt.name] = _eval_expr(ctx2, lib_env, stmt.value)
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
    if t in ("bool", "number", "str"):
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
    if t == "constraint":
        raise EvalError.type_mismatch(
            f'a constraint ("{v.name}") cannot cross a JSON boundary -- only "!" may consume it'
        )
    raise AssertionError(f"unknown value {t}")


def _contains_symbol(v: Value) -> bool:
    if v.t == "symbol":
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
    if v is None:
        return VNull()
    if isinstance(v, bool):
        return VBool(v)
    if is_number(v):
        return VNumber(normalize_number(v))
    if isinstance(v, str):
        return VStr(v)
    if isinstance(v, list):
        return VArray([_from_json(x) for x in v])
    return VObject({k: _from_json(x) for k, x in v.items()})


def _checked_from_json(mode: str, v: Json) -> Value:
    """The input context's boundary: as ``_from_json``, but recursively refusing
    ``"$sym"`` and ``"$type"`` as ordinary object keys. In symbolic mode,
    seeding accepts a well-formed ``{"$sym": ..., "path": [...]}`` back as a symbol."""
    if v is None:
        return VNull()
    if isinstance(v, bool):
        return VBool(v)
    if is_number(v):
        return VNumber(normalize_number(v))
    if isinstance(v, str):
        return VStr(v)
    if isinstance(v, list):
        return VArray([_checked_from_json(mode, x) for x in v])
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
    return VObject({k: _checked_from_json(mode, x) for k, x in v.items()})


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
        "number": "a number",
        "str": "a string",
        "array": "an array",
        "object": "an object",
        "node": "a document node",
        "closure": "a function",
        "importResult": "an import result",
        "symbol": "a symbol",
    }.get(v.t) or (
        f'the builtin "{v.name}"'
        if v.t == "builtin"
        else f'the not-yet-run import of "{v.pending.name}"'
        if v.t == "import"
        else f'a constraint ("{v.name}")'
    )


def _require_bool(who: str, v: Value) -> bool:
    if v.t == "bool":
        return v.value
    if v.t == "symbol":
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
            return VNumber(len(a.items))
        if a.t == "object":
            return VNumber(len(a.fields))
        if a.t == "symbol":
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
        a = _as_number(name, args[0])
        b = _as_number(name, args[1])
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
    raise EvalError.unbound_name(name)


def _as_bool(name: str, v: Value) -> bool:
    if v.t == "bool":
        return v.value
    raise EvalError.type_mismatch(f"{name} expects a boolean argument, got {_describe_value(v)}")


def _as_number(name: str, v: Value):
    if v.t == "number":
        return v.value
    if v.t == "symbol":
        raise EvalError.not_concrete(name)
    raise EvalError.type_mismatch(f"{name} expects a number argument, got {_describe_value(v)}")


def _as_array(name: str, v: Value) -> list[Value]:
    if v.t == "array":
        return v.items
    raise EvalError.type_mismatch(f"{name} expects an array argument, got {_describe_value(v)}")


def _as_index(n) -> Optional[int]:
    if isinstance(n, float):
        if n != n or n in (float("inf"), float("-inf")) or not n.is_integer():
            return None
        n = int(n)
    return n if n >= 0 else None


def _has_impl(name: str, container: Value, key: Value) -> bool:
    """Deliberately tolerant: a missing key, an out-of-range index, or a
    container of the wrong shape all answer false, except a symbolic
    container, which is NotConcrete rather than a lie."""
    if container.t == "symbol":
        raise EvalError.not_concrete(name)
    if container.t == "object" and key.t == "str":
        return key.value in container.fields
    if container.t == "array" and key.t == "number":
        i = _as_index(key.value)
        return i is not None and i < len(container.items)
    return False


def _lookup_impl(name: str, container: Value, key: Value, fallback: Value) -> Value:
    if container.t == "symbol":
        raise EvalError.not_concrete(name)
    if container.t == "object" and key.t == "str":
        return container.fields.get(key.value, fallback)
    if container.t == "array" and key.t == "number":
        i = _as_index(key.value)
        if i is None or i >= len(container.items):
            return fallback
        return container.items[i]
    return fallback
