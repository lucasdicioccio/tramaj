"""Core AST (``specs/reference.md`` section 2, ``specs/v3-symbols.md`` section 3,
``specs/v4-types.md`` section 1). Mirrors ``tramaj-js/src/ast.ts`` and
``tramaj-rs/src/ast.rs``.

Every node is a ``dataclass`` whose first field, ``t``, names its constructor,
so a ``match``/``if`` over ``e.t`` reads like the other ports' tagged unions.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional, Union


@dataclass
class Program:
    kind: str  # "document" | "expression"
    root: "Expr"


def document_program(root: "Expr") -> Program:
    return Program("document", root)


def expression_program(root: "Expr") -> Program:
    return Program("expression", root)


# Type expressions (v4-types section 1) -------------------------------------------


@dataclass
class TPrim:
    name: str
    t: str = field(default="Prim", init=False)


@dataclass
class TArray:
    element: "TypeExpr"
    t: str = field(default="Array", init=False)


@dataclass
class TRecord:
    fields: list[tuple[str, "TypeExpr"]]
    t: str = field(default="Record", init=False)


@dataclass
class TUnion:
    arms: list[tuple[str, Optional["TypeExpr"]]]
    t: str = field(default="Union", init=False)


@dataclass
class TName:
    name: str
    t: str = field(default="Name", init=False)


@dataclass
class TLibRef:
    lib: str
    name: str
    t: str = field(default="LibRef", init=False)


@dataclass
class TVar:
    path: list[str]
    t: str = field(default="Var", init=False)


TypeExpr = Union[TPrim, TArray, TRecord, TUnion, TName, TLibRef, TVar]


@dataclass
class ArgType:
    type: TypeExpr
    t: str = field(default="Type", init=False)


@dataclass
class ArgScalarStr:
    value: str
    t: str = field(default="ScalarStr", init=False)


@dataclass
class ArgScalarNum:
    value: Union[int, float]
    t: str = field(default="ScalarNum", init=False)


@dataclass
class ArgScalarBool:
    value: bool
    t: str = field(default="ScalarBool", init=False)


@dataclass
class ArgScalarNull:
    t: str = field(default="ScalarNull", init=False)


TypeConstraintArg = Union[ArgType, ArgScalarStr, ArgScalarNum, ArgScalarBool, ArgScalarNull]


# Import parameters -------------------------------------------------------------


@dataclass
class PExpr:
    expr: "Expr"
    t: str = field(default="PExpr", init=False)


@dataclass
class PFromContext:
    path: list[str]
    t: str = field(default="PFromContext", init=False)


@dataclass
class PType:
    type: TypeExpr
    t: str = field(default="PType", init=False)


ParamValue = Union[PExpr, PFromContext, PType]


# Attributes and adaptations ------------------------------------------------------


@dataclass
class Attr:
    name: str
    value: "Expr"
    t: str = field(default="Attr", init=False)


@dataclass
class ActionAttr:
    event: str
    key: str
    payload: "Expr"
    t: str = field(default="ActionAttr", init=False)


Attribute = Union[Attr, ActionAttr]


@dataclass
class Identity:
    t: str = field(default="Identity", init=False)


@dataclass
class Prefix:
    prefix: str
    t: str = field(default="Prefix", init=False)


ActionAdaptation = Union[Identity, Prefix]


def adapt_key(adaptation: ActionAdaptation, key: str) -> str:
    return key if adaptation.t == "Identity" else adaptation.prefix + key


# Expressions ------------------------------------------------------------------


@dataclass
class Path:
    root: str
    fields: list[str]
    t: str = field(default="Path", init=False)


@dataclass
class FieldAccess:
    target: "Expr"
    fields: list[str]
    t: str = field(default="FieldAccess", init=False)


@dataclass
class Call:
    fn: "Expr"
    args: list["Expr"]
    t: str = field(default="Call", init=False)


@dataclass
class Lambda:
    params: list[str]
    body: "Expr"
    t: str = field(default="Lambda", init=False)


@dataclass
class Let:
    name: str
    value: "Expr"
    body: "Expr"
    t: str = field(default="Let", init=False)


@dataclass
class StringLit:
    value: str
    t: str = field(default="StringLit", init=False)


@dataclass
class NumberLit:
    value: Union[int, float]
    t: str = field(default="NumberLit", init=False)


@dataclass
class BoolLit:
    value: bool
    t: str = field(default="BoolLit", init=False)


@dataclass
class NullLit:
    t: str = field(default="NullLit", init=False)


@dataclass
class ArrayLit:
    elements: list["Expr"]
    t: str = field(default="ArrayLit", init=False)


@dataclass
class ObjectLit:
    fields: list[tuple[str, "Expr"]]
    t: str = field(default="ObjectLit", init=False)


@dataclass
class Element:
    tag: str
    attributes: list[Attribute]
    value: "Expr"
    children: list["Expr"]
    t: str = field(default="Element", init=False)


@dataclass
class Fragment:
    children: list["Expr"]
    t: str = field(default="Fragment", init=False)


@dataclass
class Branch:
    condition: "Expr"
    then: "Expr"
    else_: "Expr"
    t: str = field(default="Branch", init=False)


@dataclass
class Map:
    collection: "Expr"
    fn: "Expr"
    t: str = field(default="Map", init=False)


@dataclass
class Filter:
    collection: "Expr"
    fn: "Expr"
    t: str = field(default="Filter", init=False)


@dataclass
class Scan:
    collection: "Expr"
    initial: "Expr"
    fn: "Expr"
    t: str = field(default="Scan", init=False)


@dataclass
class Fold:
    collection: "Expr"
    initial: "Expr"
    fn: "Expr"
    t: str = field(default="Fold", init=False)


@dataclass
class Concat:
    left: "Expr"
    right: "Expr"
    t: str = field(default="Concat", init=False)


@dataclass
class Import:
    name: str
    params: list[tuple[str, ParamValue]]
    t: str = field(default="Import", init=False)


@dataclass
class AdaptActions:
    target: "Expr"
    adaptation: ActionAdaptation
    fn: Optional["Expr"]
    t: str = field(default="AdaptActions", init=False)


@dataclass
class Constrain:
    """``constraint(name, args...)`` (``v3-symbols.md`` section 2.1)."""

    name: str
    args: list["Expr"]
    t: str = field(default="Constrain", init=False)


@dataclass
class Emit:
    """``!expr`` (section 2.2): a statement, nesting into the same chain ``Let`` does."""

    constraint: "Expr"
    body: "Expr"
    t: str = field(default="Emit", init=False)


@dataclass
class Alloc:
    """``?(key)`` (section 1.2). ``site`` is assigned by ``number_allocs`` after
    parsing rather than by the parser, so agreement between implementations
    rests on that one pure function."""

    site: int
    key: "Expr"
    t: str = field(default="Alloc", init=False)


@dataclass
class Demand:
    """``?ctx.a.b`` (section 1.3): the path is always rooted at ``ctx``, which is not stored."""

    path: list[str]
    t: str = field(default="Demand", init=False)


@dataclass
class TypeDecl:
    name: str
    type: TypeExpr
    body: "Expr"
    t: str = field(default="TypeDecl", init=False)


@dataclass
class TypeAnnotate:
    name: str
    type: TypeExpr
    value: "Expr"
    body: "Expr"
    t: str = field(default="TypeAnnotate", init=False)


@dataclass
class TypeEmit:
    name: str
    args: list[TypeConstraintArg]
    body: "Expr"
    t: str = field(default="TypeEmit", init=False)


Expr = Union[
    Path, FieldAccess, Call, Lambda, Let, StringLit, NumberLit, BoolLit, NullLit,
    ArrayLit, ObjectLit, Element, Fragment, Branch, Map, Filter, Scan, Fold,
    Concat, Import, AdaptActions, Constrain, Emit, Alloc, Demand, TypeDecl,
    TypeAnnotate, TypeEmit,
]


def _attribute_exprs(attrs: list[Attribute]) -> list[Expr]:
    return [a.value if a.t == "Attr" else a.payload for a in attrs]


def sub_exprs(e: Expr) -> list[Expr]:
    """The immediately-contained expressions of an expression, in source order."""
    t = e.t
    if t in ("Path", "StringLit", "NumberLit", "BoolLit", "NullLit", "Demand"):
        return []
    if t == "FieldAccess":
        return [e.target]
    if t == "Call":
        return [e.fn, *e.args]
    if t == "Lambda":
        return [e.body]
    if t == "Let":
        return [e.value, e.body]
    if t == "ArrayLit":
        return list(e.elements)
    if t == "ObjectLit":
        return [v for _, v in e.fields]
    if t == "Element":
        return [*_attribute_exprs(e.attributes), e.value, *e.children]
    if t == "Fragment":
        return list(e.children)
    if t == "Branch":
        return [e.condition, e.then, e.else_]
    if t in ("Map", "Filter"):
        return [e.collection, e.fn]
    if t in ("Scan", "Fold"):
        return [e.collection, e.initial, e.fn]
    if t == "Concat":
        return [e.left, e.right]
    if t == "Import":
        return [p.expr for _, p in e.params if p.t == "PExpr"]
    if t == "AdaptActions":
        return [e.target] if e.fn is None else [e.target, e.fn]
    if t == "Constrain":
        return list(e.args)
    if t == "Emit":
        return [e.constraint, e.body]
    if t == "Alloc":
        return [e.key]
    if t == "TypeDecl":
        return [e.body]
    if t == "TypeAnnotate":
        return [e.value, e.body]
    if t == "TypeEmit":
        return [e.body]
    raise AssertionError(f"unknown expression {t}")


def number_allocs(e: Expr) -> None:
    """Assigns each ``Alloc`` the index of its ``?(...)`` among all of them, in
    source order (``v3-symbols.md`` section 1.4): a plain pre-order,
    left-to-right walk over the freshly parsed tree."""
    counter = [0]

    def go(x: Expr) -> None:
        if x.t == "Alloc":
            x.site = counter[0]
            counter[0] += 1
            go(x.key)
            return
        for sub in sub_exprs(x):
            go(sub)

    go(e)


# Statements -----------------------------------------------------------------


@dataclass
class SLet:
    name: str
    value: Expr
    t: str = field(default="Let", init=False)


@dataclass
class SEmit:
    constraint: Expr
    t: str = field(default="Emit", init=False)


@dataclass
class STypeDecl:
    name: str
    type: TypeExpr
    t: str = field(default="TypeDecl", init=False)


@dataclass
class SAnnotate:
    name: str
    type: TypeExpr
    value: Expr
    t: str = field(default="Annotate", init=False)


@dataclass
class STypeEmit:
    name: str
    args: list[TypeConstraintArg]
    t: str = field(default="TypeEmit", init=False)


Stmt = Union[SLet, SEmit, STypeDecl, SAnnotate, STypeEmit]


def unlets(e: Expr) -> tuple[list[Stmt], Expr]:
    """Peels the outermost ``Let``/``Emit``/``TypeDecl``/``TypeAnnotate``/``TypeEmit``
    chain back off, stopping at the first non-statement constructor."""
    statements: list[Stmt] = []
    cur = e
    while True:
        t = cur.t
        if t == "Let":
            statements.append(SLet(cur.name, cur.value))
            cur = cur.body
        elif t == "Emit":
            statements.append(SEmit(cur.constraint))
            cur = cur.body
        elif t == "TypeDecl":
            statements.append(STypeDecl(cur.name, cur.type))
            cur = cur.body
        elif t == "TypeAnnotate":
            statements.append(SAnnotate(cur.name, cur.type, cur.value))
            cur = cur.body
        elif t == "TypeEmit":
            statements.append(STypeEmit(cur.name, cur.args))
            cur = cur.body
        else:
            return statements, cur


def type_decls(stmts: list[Stmt]) -> list[tuple[str, TypeExpr]]:
    return [(s.name, s.type) for s in stmts if s.t == "TypeDecl"]


def let_bindings(stmts: list[Stmt]) -> list[tuple[str, Expr]]:
    """Just the named bindings of a statement block, in order: what an import
    exposes as ``.vals``. An annotated binding still binds its name."""
    return [(s.name, s.value) for s in stmts if s.t in ("Let", "Annotate")]
