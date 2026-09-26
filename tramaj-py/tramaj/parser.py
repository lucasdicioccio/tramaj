"""Hand-written recursive-descent lexer + parser for the surface syntax
(``specs/reference.md`` sections 5 and 8; ``specs/v3-symbols.md`` sections 1-2;
``specs/v4-types.md`` sections 1, 5, 7). Mirrors ``tramaj-js/src/parser.ts``,
including its "name recognition backtracks; the shape does not" rule for the
special forms and the static-position (no-interpolation) restrictions."""

from __future__ import annotations

from typing import Callable, Optional, TypeVar

from . import ast as A
from .jsonval import MAX_SAFE_INTEGER

T = TypeVar("T")


class ParseError(Exception):
    pass


SPECIAL_FORM_NAMES = {
    "map", "filter", "scan", "fold", "branch", "import", "adapt-actions", "constraint",
}

# The five value-domain shapes ``v4-types.md`` section 1 reserves as type primitives.
PRIM_NAMES = {"string", "number", "bool", "null", "document"}


def _is_alpha(c: str) -> bool:
    return c.isalpha()


def _is_alnum(c: str) -> bool:
    return c.isalpha() or c.isnumeric()


def _is_space(c: str) -> bool:
    return c.isspace()


def _is_digit(c: str) -> bool:
    return "0" <= c <= "9"


def _is_hex(c: str) -> bool:
    return _is_digit(c) or "a" <= c <= "f" or "A" <= c <= "F"


class _Fail:
    pass


FAIL = _Fail()


class _Parser:
    def __init__(self, src: str) -> None:
        self.chars = list(src)
        self.pos = 0

    def err(self, msg: str) -> ParseError:
        return ParseError(f"at char {self.pos}: {msg}")

    def eof(self) -> bool:
        return self.pos >= len(self.chars)

    def peek(self) -> Optional[str]:
        return self.chars[self.pos] if self.pos < len(self.chars) else None

    def peek_at(self, off: int) -> Optional[str]:
        i = self.pos + off
        return self.chars[i] if i < len(self.chars) else None

    def advance(self) -> Optional[str]:
        c = self.peek()
        if c is None:
            return None
        self.pos += 1
        return c

    def attempt(self, f: Callable[[], T]):
        """Full save/restore backtracking around one alternative."""
        save = self.pos
        try:
            return f()
        except ParseError:
            self.pos = save
            return FAIL

    # Lexing -----------------------------------------------------------------

    def skip_spaces(self) -> None:
        while True:
            c = self.peek()
            if c is not None and _is_space(c):
                self.advance()
            elif c == "-" and self.peek_at(1) == "-":
                while self.peek() is not None and self.peek() != "\n":
                    self.advance()
            else:
                return

    def lexeme(self, f: Callable[[], T]) -> T:
        v = f()
        self.skip_spaces()
        return v

    def literal(self, s: str) -> None:
        save = self.pos
        for expected in s:
            if self.advance() != expected:
                self.pos = save
                raise self.err(f'expected "{s}"')

    def symbol(self, s: str) -> None:
        self.lexeme(lambda: self.literal(s))

    def char_lit(self, c: str) -> str:
        if self.peek() == c:
            self.advance()
            return c
        raise self.err(f'expected "{c}"')

    def raw_ident(self) -> str:
        c0 = self.peek()
        if c0 is None or not _is_alpha(c0):
            raise self.err("expected an identifier")
        self.advance()
        s = [c0]
        while True:
            c = self.peek()
            if c is not None and (_is_alnum(c) or c == "_"):
                s.append(c)
                self.advance()
            elif c == "-":
                nxt = self.peek_at(1)
                if nxt is not None and (_is_alnum(nxt) or nxt == "_"):
                    s.append("-")
                    self.advance()
                else:
                    return "".join(s)
            else:
                return "".join(s)

    def identifier(self) -> str:
        return self.lexeme(self.raw_ident)

    def path_tail(self) -> tuple[str, list[str]]:
        root = self.raw_ident()
        return root, self.dotted_path_tail()

    def dotted_path_tail(self) -> list[str]:
        segs: list[str] = []
        while True:
            save = self.pos
            if self.peek() != ".":
                return segs
            self.advance()
            seg = self.attempt(self.raw_ident)
            if seg is FAIL:
                self.pos = save
                return segs
            segs.append(seg)

    def field_access_suffix(self) -> list[str]:
        return self.dotted_path_tail()

    @staticmethod
    def apply_field_access(base: A.Expr, segs: list[str]) -> A.Expr:
        return base if not segs else A.FieldAccess(base, segs)

    # Static strings -----------------------------------------------------------

    def static_string(self) -> str:
        def go() -> str:
            self.char_lit('"')
            s: list[str] = []
            while True:
                c = self.peek()
                if c is None or c == '"' or c == "`":
                    break
                s.append(c)
                self.advance()
            if self.peek() != '"':
                raise self.err(
                    "this position must be a literal string, so it cannot contain an interpolation"
                )
            self.advance()
            return "".join(s)

        return self.lexeme(go)

    # String literals ------------------------------------------------------------

    def string_lit(self) -> A.Expr:
        def go() -> A.Expr:
            self.char_lit('"')
            parts: list[tuple[str, object]] = []
            while True:
                c = self.peek()
                if c is None or c == '"':
                    break
                if c == "`":
                    self.advance()
                    e = self.expr()
                    self.char_lit("`")
                    parts.append(("interp", e))
                else:
                    parts.append(("lit", self.lit_chunk()))
            self.char_lit('"')
            return _desugar_string(parts)

        return self.lexeme(go)

    def lit_chunk(self) -> str:
        s: list[str] = []
        while True:
            c = self.peek()
            if c == "\\":
                self.advance()
                s.append(self.escape_seq())
            elif c is not None and c != '"' and c != "`":
                s.append(c)
                self.advance()
            else:
                break
        if not s:
            raise self.err("expected string content")
        return "".join(s)

    def escape_seq(self) -> str:
        c = self.advance()
        if c is None:
            raise self.err("unterminated escape sequence")
        simple = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "`": "`", "0": "\0"}
        if c in simple:
            return simple[c]
        if c == "u":
            self.char_lit("{")
            digits: list[str] = []
            while True:
                d = self.peek()
                if d is not None and _is_hex(d):
                    digits.append(d)
                    self.advance()
                else:
                    break
            if not digits:
                raise self.err("invalid unicode escape")
            self.char_lit("}")
            n = int("".join(digits), 16)
            if n > 0x10FFFF or 0xD800 <= n <= 0xDFFF:
                raise self.err("invalid unicode escape")
            return chr(n)
        raise self.err(f"unknown escape sequence: \\{c}")

    # Literals -----------------------------------------------------------------

    def number_lit(self) -> A.Expr:
        """``["-"] digits ["." digits] [("e"|"E") ["+"|"-"] digits]``, where a
        ``_`` may sit between two digits. The fraction and exponent are taken
        only when complete; an overflow to infinity is refused and a zero is
        normalized so ``-0`` never escapes."""

        def go() -> A.Expr:
            full = ""
            if self.peek() == "-":
                self.advance()
                full = "-"
            int_part = self.digits()
            if int_part == "":
                raise self.err("expected a digit")
            full += int_part
            is_float = False
            save = self.pos
            if self.peek() == ".":
                self.advance()
                frac = self.digits()
                if frac == "":
                    self.pos = save
                else:
                    full += "." + frac
                    is_float = True
            save = self.pos
            e = self.peek()
            if e == "e" or e == "E":
                self.advance()
                exp = "e"
                sign = self.peek()
                if sign == "+" or sign == "-":
                    self.advance()
                    exp += sign
                exp_digits = self.digits()
                if exp_digits == "":
                    self.pos = save
                else:
                    full += exp + exp_digits
                    is_float = True
            if is_float:
                n = float(full)
                if n != n or n in (float("inf"), float("-inf")):
                    raise self.err("number literal out of range")
                if n == 0:
                    return A.NumberLit(0)
                if n.is_integer() and abs(n) <= MAX_SAFE_INTEGER:
                    return A.NumberLit(int(n))
                return A.NumberLit(n)
            i = int(full)
            if abs(i) > MAX_SAFE_INTEGER:
                f = float(i)
                if f in (float("inf"), float("-inf")):
                    raise self.err("number literal out of range")
                return A.NumberLit(f)
            return A.NumberLit(i)

        return self.lexeme(go)

    def digits(self) -> str:
        """``digit { ["_"] digit }`` with the underscores dropped; ``""`` when no digit is next."""
        out: list[str] = []
        first = self.peek()
        if first is None or not _is_digit(first):
            return ""
        while True:
            c = self.peek()
            if c is not None and _is_digit(c):
                out.append(c)
                self.advance()
                continue
            nxt = self.peek_at(1)
            if c == "_" and nxt is not None and _is_digit(nxt):
                self.advance()
                continue
            return "".join(out)

    def keyword_lit(self) -> A.Expr:
        name = self.identifier()
        if name == "true":
            return A.BoolLit(True)
        if name == "false":
            return A.BoolLit(False)
        if name == "null":
            return A.NullLit()
        raise self.err("not a literal keyword")

    def array_lit(self) -> A.Expr:
        self.symbol("[")
        elements = self.sep_end_by(",", self.expr)
        self.symbol("]")
        return A.ArrayLit(elements)

    def object_lit(self) -> A.Expr:
        self.symbol("{")
        fields = self.sep_end_by(",", self.obj_entry)
        self.symbol("}")
        return A.ObjectLit(fields)

    def obj_entry(self) -> tuple[str, A.Expr]:
        explicit = self.attempt(self.explicit_entry)
        if explicit is not FAIL:
            return explicit
        k = self.identifier()
        return k, A.Path(k, [])

    def explicit_entry(self) -> tuple[str, A.Expr]:
        k = self.object_key()
        self.refuse_reserved_key(k)
        self.symbol(":")
        return k, self.expr()

    def refuse_reserved_key(self, k: str) -> None:
        if k in ("$sym", "$type"):
            raise self.err(f'"{k}" is a reserved key and cannot be used as an object key')

    def object_key(self) -> str:
        s = self.attempt(self.static_string)
        return s if s is not FAIL else self.identifier()

    # Sep-end-by helper ----------------------------------------------------------

    def sep_end_by(self, sep: str, item: Callable[[], T]) -> list[T]:
        out: list[T] = []
        first = self.attempt(item)
        if first is FAIL:
            return out
        out.append(first)
        while True:
            save = self.pos
            sep_ok = self.attempt(lambda: self.symbol(sep))
            if sep_ok is FAIL:
                self.pos = save
                return out
            nxt = self.attempt(item)
            if nxt is FAIL:
                self.pos = save
                return out
            out.append(nxt)

    # Expressions ---------------------------------------------------------------

    def path_expr(self) -> A.Expr:
        def go() -> A.Expr:
            self.char_lit("$")
            root, fields = self.path_tail()
            return A.Path(root, fields)

        return self.lexeme(go)

    def alloc_expr(self) -> A.Expr:
        """``?(key)`` (``v3-symbols.md`` section 1.2); ``number_allocs`` assigns the real site later."""
        self.char_lit("?")
        self.symbol("(")
        key = self.expr()
        self.char_lit(")")
        segs = self.field_access_suffix()
        self.skip_spaces()
        return self.apply_field_access(A.Alloc(0, key), segs)

    def demand_expr(self) -> A.Expr:
        """``?ctx.a.b`` (section 1.3): the path MUST be rooted at ``ctx``."""

        def go() -> A.Expr:
            self.char_lit("?")
            root = self.raw_ident()
            if root != "ctx":
                raise self.err("a demand must be rooted at ctx, as in ?ctx.path")
            return A.Demand(self.dotted_path_tail())

        return self.lexeme(go)

    def call_expr(self) -> A.Expr:
        self.attempt(lambda: self.char_lit("$"))
        root, fields = self.path_tail()
        self.symbol("(")
        args = self.sep_end_by(",", self.expr)
        self.char_lit(")")
        segs = self.field_access_suffix()
        self.skip_spaces()
        return self.apply_field_access(A.Call(A.Path(root, fields), args), segs)

    def lambda_expr(self) -> A.Expr:
        self.symbol("(")
        params = self.sep_end_by(",", self.pattern)
        self.symbol(")")
        self.symbol("=>")
        return _lower_lambda(params, self.expr())

    # Binding patterns (decisions section 17) ---------------------------------------

    def pattern(self) -> Pattern:
        """A name, or an object pattern ``{a, b: c, d: {e}}``. Object patterns
        only: defaults, rest and array patterns are not in the grammar, so they
        are parse errors."""
        n = self.attempt(self.identifier)
        if n is not FAIL:
            return ("name", n)
        return self.object_pattern()

    def object_pattern(self) -> Pattern:
        self.symbol("{")
        fields = self.sep_end_by(",", self.pattern_field)
        if not fields:
            raise self.err("expected a field in a binding pattern")
        self.symbol("}")
        pat: Pattern = ("obj", fields)
        names = _pattern_names(pat)
        if len(set(names)) != len(names):
            raise self.err("duplicate name in a binding pattern")
        return pat

    def pattern_field(self) -> tuple[str, Pattern]:
        """``name`` binds the field to that name; ``name: p`` binds or
        destructures it as ``p``."""
        k = self.identifier()

        def sub_alt() -> Pattern:
            self.symbol(":")
            return self.pattern()

        sub = self.attempt(sub_alt)
        return k, ("name", k) if sub is FAIL else sub

    def paren_expr(self) -> A.Expr:
        self.symbol("(")
        e = self.expr()
        self.symbol(")")
        return e

    def try_special_form_name(self) -> Optional[str]:
        """Soft recognition only: consumes the name (and trailing whitespace)
        iff it is one of the recognized special forms; otherwise fully restores."""
        save = self.pos
        self.attempt(lambda: self.char_lit("$"))
        n = self.attempt(self.identifier)
        if n is not FAIL and n in SPECIAL_FORM_NAMES:
            return n
        self.pos = save
        return None

    def special_form_shape(self, name: str) -> A.Expr:
        """Once the name is recognized the shape does not backtrack: any error
        here is a hard parse error (``reference.md`` section 5)."""
        if name == "map":
            c, f = self.binary_shape()
            base: A.Expr = A.Map(c, f)
        elif name == "filter":
            c, f = self.binary_shape()
            base = A.Filter(c, f)
        elif name == "scan":
            c, i, f = self.ternary_shape()
            base = A.Scan(c, i, f)
        elif name == "fold":
            c, i, f = self.ternary_shape()
            base = A.Fold(c, i, f)
        elif name == "branch":
            base = self.branch_shape()
        elif name == "import":
            base = self.import_shape()
        elif name == "adapt-actions":
            base = self.adapt_actions_shape()
        elif name == "constraint":
            base = self.constraint_shape()
        else:
            raise self.err("unrecognized special form")
        segs = self.field_access_suffix()
        self.skip_spaces()
        return self.apply_field_access(base, segs)

    def binary_shape(self) -> tuple[A.Expr, A.Expr]:
        self.symbol("(")
        a = self.expr()
        self.symbol(",")
        b = self.expr()
        self.char_lit(")")
        return a, b

    def ternary_shape(self) -> tuple[A.Expr, A.Expr, A.Expr]:
        self.symbol("(")
        a = self.expr()
        self.symbol(",")
        b = self.expr()
        self.symbol(",")
        c = self.expr()
        self.char_lit(")")
        return a, b, c

    def branch_shape(self) -> A.Expr:
        self.symbol("(")
        fallback = self.expr()
        arms: list[tuple[A.Expr, A.Expr]] = []
        while True:
            save = self.pos
            sep_ok = self.attempt(lambda: self.symbol(","))
            if sep_ok is FAIL:
                self.pos = save
                break
            arm = self.attempt(self.branch_arm)
            if arm is FAIL:
                self.pos = save
                break
            arms.append(arm)
        self.attempt(lambda: self.symbol(","))
        self.char_lit(")")
        acc = fallback
        for condition, then in reversed(arms):
            acc = A.Branch(condition, then, acc)
        return acc

    def branch_arm(self) -> tuple[A.Expr, A.Expr]:
        p = self.expr()
        self.symbol(",")
        return p, self.expr()

    def import_shape(self) -> A.Expr:
        self.symbol("(")
        name = self.static_string()
        self.symbol(",")
        params = self.import_params()
        self.char_lit(")")
        return A.Import(name, params)

    def import_params(self) -> list[tuple[str, A.ParamValue]]:
        self.symbol("{")
        entries = self.sep_end_by(",", self.param_entry)
        self.symbol("}")
        return entries

    def param_entry(self) -> tuple[str, A.ParamValue]:
        explicit = self.attempt(self.explicit_param)
        if explicit is not FAIL:
            return explicit
        k = self.identifier()
        return k, A.PExpr(A.Path(k, []))

    def explicit_param(self) -> tuple[str, A.ParamValue]:
        k = self.object_key()
        self.symbol(":")
        return k, self.param_value()

    def param_value(self) -> A.ParamValue:
        marked = self.attempt(self.marked_type_expr)
        if marked is not FAIL:
            return A.PType(marked)
        from_ctx = self.attempt(self.ctx_param)
        if from_ctx is not FAIL:
            return from_ctx
        return A.PExpr(self.expr())

    # Types --------------------------------------------------------------------

    def type_expr(self) -> A.TypeExpr:
        for alt in (self.type_var, self.type_union, self.type_array, self.type_record):
            v = self.attempt(alt)
            if v is not FAIL:
                return v
        return self.type_prim_or_ref()

    def type_expr_payload(self) -> A.TypeExpr:
        """Deliberately narrower than ``type_expr``: a bare name is excluded
        because nothing marks where a nullary arm ends."""
        v = self.attempt(self.type_var)
        if v is not FAIL:
            return v
        a = self.attempt(self.type_array)
        if a is not FAIL:
            return a
        return self.type_record()

    def type_var(self) -> A.TypeExpr:
        def go() -> A.TypeExpr:
            self.char_lit("%")
            root = self.raw_ident()
            if root != "ctx":
                raise self.err("a type hole must be rooted at ctx, as in %ctx.path")
            return A.TVar(self.dotted_path_tail())

        return self.lexeme(go)

    def marked_type_expr(self) -> A.TypeExpr:
        """A ``%``-marked type argument (``v4-types.md`` sections 2, 5). Unlike
        ``type_var`` the leading ``%`` does not require what follows to be ``ctx``."""
        self.char_lit("%")
        for alt in (self.ctx_forward, self.type_union, self.type_array, self.type_record):
            v = self.attempt(alt)
            if v is not FAIL:
                return v
        return self.type_prim_or_ref()

    def ctx_forward(self) -> A.TypeExpr:
        def go() -> A.TypeExpr:
            root = self.raw_ident()
            if root != "ctx":
                raise self.err("a %-marked value must be ctx.path or a type expression")
            return A.TVar(self.dotted_path_tail())

        return self.lexeme(go)

    def type_array(self) -> A.TypeExpr:
        self.symbol("[")
        element = self.type_expr()
        self.symbol("]")
        return A.TArray(element)

    def type_record(self) -> A.TypeExpr:
        self.symbol("{")
        fields = self.sep_end_by(",", self.type_field)
        self.symbol("}")
        return A.TRecord(fields)

    def type_field(self) -> tuple[str, A.TypeExpr]:
        k = self.identifier()
        self.symbol(":")
        return k, self.type_expr()

    def type_union(self) -> A.TypeExpr:
        self.symbol("|")
        arms = [self.union_arm()]
        while True:
            save = self.pos
            bar_ok = self.attempt(lambda: self.symbol("|"))
            if bar_ok is FAIL:
                self.pos = save
                break
            arms.append(self.union_arm())
        return A.TUnion(arms)

    def union_arm(self) -> tuple[str, Optional[A.TypeExpr]]:
        name = self.identifier()
        payload = self.attempt(self.type_expr_payload)
        return name, (None if payload is FAIL else payload)

    def type_prim_or_ref(self) -> A.TypeExpr:
        r = self.attempt(self.type_lib_ref)
        if r is not FAIL:
            return r
        return self.type_name_or_prim()

    def type_lib_ref(self) -> A.TypeExpr:
        def go() -> A.TypeExpr:
            self.char_lit("$")
            lib = self.raw_ident()
            self.char_lit(".")
            self.literal("types")
            self.char_lit(".")
            name = self.raw_ident()
            return A.TLibRef(lib, name)

        return self.lexeme(go)

    def type_name_or_prim(self) -> A.TypeExpr:
        name = self.identifier()
        return A.TPrim(name) if name in PRIM_NAMES else A.TName(name)

    def type_constraint_arg(self) -> A.TypeConstraintArg:
        marked = self.attempt(self.marked_type_expr)
        if marked is not FAIL:
            return A.ArgType(marked)
        return self.scalar_arg()

    def scalar_arg(self) -> A.TypeConstraintArg:
        s = self.attempt(self.static_string)
        if s is not FAIL:
            return A.ArgScalarStr(s)
        n = self.attempt(self.number_lit)
        if n is not FAIL:
            return _as_scalar_arg(n)
        k = self.attempt(self.keyword_lit)
        if k is not FAIL:
            return _as_scalar_arg(k)
        raise self.err("expected a type-constraint argument")

    def type_emission(self) -> A.Stmt:
        """``!type-constraint(name, args...)`` (``v4-types.md`` section 5): tried
        before the general ``!expr`` emission, since both share the ``!`` leader."""
        self.char_lit("!")
        kw = self.identifier()
        if kw != "type-constraint":
            raise self.err("not a !type-constraint")
        self.symbol("(")
        name = self.static_string()
        args: list[A.TypeConstraintArg] = []
        while True:
            save = self.pos
            sep_ok = self.attempt(lambda: self.symbol(","))
            if sep_ok is FAIL:
                self.pos = save
                break
            a = self.attempt(self.type_constraint_arg)
            if a is FAIL:
                self.pos = save
                break
            args.append(a)
        self.attempt(lambda: self.symbol(","))
        self.char_lit(")")
        self.skip_spaces()
        return A.STypeEmit(name, args)

    def type_decl_stmt(self) -> A.Stmt:
        """``type Name = TypeExpr`` (``v4-types.md`` section 1.1): a keyword leader."""
        kw = self.identifier()
        if kw != "type":
            raise self.err("not a type declaration")
        name = self.identifier()
        self.symbol("=")
        return A.STypeDecl(name, self.type_expr())

    def ctx_param(self) -> A.ParamValue:
        save = self.pos
        n = self.identifier()
        if n != "ctx" or self.peek() != "(":
            self.pos = save
            raise self.err("not a ctx(...) parameter")
        self.symbol("(")
        root, fields = self.path_tail()
        self.skip_spaces()
        self.char_lit(")")
        self.skip_spaces()
        return A.PFromContext([root, *fields])

    def constraint_shape(self) -> A.Expr:
        """``constraint(name, args...)`` (``v3-symbols.md`` section 2.1)."""
        self.symbol("(")
        name = self.static_string()
        args: list[A.Expr] = []
        while True:
            save = self.pos
            sep_ok = self.attempt(lambda: self.symbol(","))
            if sep_ok is FAIL:
                self.pos = save
                break
            a = self.attempt(self.expr)
            if a is FAIL:
                self.pos = save
                break
            args.append(a)
        self.attempt(lambda: self.symbol(","))
        self.char_lit(")")
        return A.Constrain(name, args)

    def adapt_actions_shape(self) -> A.Expr:
        self.symbol("(")
        target = self.expr()
        self.symbol(",")
        adaptation = self.adaptation_shape()

        def fn_arg() -> A.Expr:
            self.symbol(",")
            return self.expr()

        fn = self.attempt(fn_arg)
        self.attempt(lambda: self.symbol(","))
        self.char_lit(")")
        return A.AdaptActions(target, adaptation, None if fn is FAIL else fn)

    def adaptation_shape(self) -> A.ActionAdaptation:
        name = self.identifier()
        if name == "identity":
            return A.Identity()
        if name == "prefix":
            self.symbol("(")
            prefix = self.static_string()
            self.char_lit(")")
            self.skip_spaces()
            return A.Prefix(prefix)
        raise self.err('an action adaptation must be identity or prefix("...")')

    # Documents -----------------------------------------------------------------

    def document_expr(self) -> A.Expr:
        self.char_lit(".")
        frag = self.attempt(self.fragment_shape)
        if frag is not FAIL:
            return frag
        return self.element_shape()

    def fragment_shape(self) -> A.Expr:
        self.symbol("(")
        children = self.sep_end_by(",", self.expr)
        self.symbol(")")
        return A.Fragment(children)

    def element_shape(self) -> A.Expr:
        tag = self.raw_ident()
        self.skip_spaces()
        self.symbol("(")
        args = self.sep_end_by(",", self.element_arg)
        self.symbol(")")
        return self.build_element(tag, args)

    def element_arg(self) -> tuple[str, object]:
        positional = self.try_attribute_position_arg()
        if positional is not None:
            return positional
        named = self.attempt(self.named_arg)
        if named is not FAIL:
            return ("attr", named)
        return ("child", self.expr())

    def try_attribute_position_arg(self) -> Optional[tuple[str, object]]:
        """``action(...)``/``value(...)``: soft name+lookahead recognition, then a hard-committed shape."""
        save = self.pos
        n = self.attempt(self.identifier)
        if n is FAIL:
            self.pos = save
            return None
        if self.peek() != "(" or (n != "action" and n != "value"):
            self.pos = save
            return None
        if n == "action":
            return ("attr", self.action_shape())
        return ("value", self.value_shape())

    def action_shape(self) -> A.Attribute:
        self.symbol("(")
        event = self.static_string()
        self.symbol(",")
        key = self.static_string()
        self.symbol(",")
        payload = self.expr()
        self.symbol(")")
        return A.ActionAttr(event, key, payload)

    def value_shape(self) -> A.Expr:
        self.symbol("(")
        v = self.expr()
        self.symbol(")")
        return v

    def named_arg(self) -> A.Attribute:
        name = self.object_key()
        self.symbol(":")
        return A.Attr(name, self.expr())

    def build_element(self, tag: str, args: list[tuple[str, object]]) -> A.Expr:
        seen_child = False
        for kind, _ in args:
            if kind == "child":
                seen_child = True
            elif seen_child:
                raise self.err(
                    "attributes, action(...) and value(...) must all come before an element's children"
                )
        values = [v for k, v in args if k == "value"]
        attributes = [v for k, v in args if k == "attr"]
        children = [v for k, v in args if k == "child"]
        if len(values) > 1:
            raise self.err("an element can have at most one value(...)")
        value = values[0] if len(values) == 1 else A.NullLit()
        return A.Element(tag, attributes, value, children)

    # Precedence ------------------------------------------------------------------

    def expr(self) -> A.Expr:
        acc = self.operand()
        while True:
            save = self.pos

            def rhs_alt() -> A.Expr:
                self.symbol("<>")
                return self.operand()

            rhs = self.attempt(rhs_alt)
            if rhs is FAIL:
                self.pos = save
                return acc
            acc = A.Concat(acc, rhs)

    def operand(self) -> A.Expr:
        for alt in (self.keyword_lit, self.lambda_expr, self.paren_expr):
            v = self.attempt(alt)
            if v is not FAIL:
                return v
        special = self.try_special_form_name()
        if special is not None:
            return self.special_form_shape(special)
        for alt in (
            self.call_expr,
            self.path_expr,
            self.alloc_expr,
            self.demand_expr,
            self.document_expr,
            self.string_lit,
            self.number_lit,
            self.array_lit,
            self.object_lit,
        ):
            v = self.attempt(alt)
            if v is not FAIL:
                return v
        raise self.err("expected an expression")

    # Programs --------------------------------------------------------------------

    def binding(self) -> list[A.Stmt]:
        """``@name=expr``, ``@name : T = expr`` (``v4-types.md`` section 7) or
        ``@{a, b: c} = expr`` (decisions section 17), which lowers to several
        statements. An annotation on a pattern is a parse error."""
        self.char_lit("@")
        pat = self.pattern()
        if pat[0] == "obj":
            self.symbol("=")
            return _bind_pattern(pat, self.expr())
        name = pat[1]

        def annot_alt() -> A.TypeExpr:
            self.symbol(":")
            return self.type_expr()

        annot = self.attempt(annot_alt)
        self.symbol("=")
        value = self.expr()
        if annot is not FAIL:
            return [A.SAnnotate(name, annot, value)]
        return [A.SLet(name, value)]

    def emission_stmt(self) -> A.Expr:
        """``!expr`` (``v3-symbols.md`` section 2.2): a statement position only."""
        self.char_lit("!")
        return self.expr()

    def program(self) -> A.Program:
        self.skip_spaces()
        statements: list[A.Stmt] = []
        while True:
            b = self.attempt(self.binding)
            if b is not FAIL:
                statements.extend(b)
                continue
            te = self.attempt(self.type_emission)
            if te is not FAIL:
                statements.append(te)
                continue
            em = self.attempt(self.emission_stmt)
            if em is not FAIL:
                statements.append(A.SEmit(em))
                continue
            td = self.attempt(self.type_decl_stmt)
            if td is not FAIL:
                statements.append(td)
                continue
            break
        root = self.expr()
        self.skip_spaces()
        if not self.eof():
            raise self.err("unexpected trailing input")
        is_document = root.t in ("Element", "Fragment")
        body = root
        for stmt in reversed(statements):
            if stmt.t == "Let":
                body = A.Let(stmt.name, stmt.value, body)
            elif stmt.t == "Emit":
                body = A.Emit(stmt.constraint, body)
            elif stmt.t == "TypeDecl":
                body = A.TypeDecl(stmt.name, stmt.type, body)
            elif stmt.t == "Annotate":
                body = A.TypeAnnotate(stmt.name, stmt.type, stmt.value, body)
            elif stmt.t == "TypeEmit":
                body = A.TypeEmit(stmt.name, stmt.args, body)
        A.number_allocs(body)
        return A.document_program(body) if is_document else A.expression_program(body)


# A binding pattern (decisions section 17): ``("name", n)`` or ``("obj", [(field, pattern)])``.
Pattern = tuple


def _pattern_names(pat: Pattern) -> list[str]:
    if pat[0] == "name":
        return [pat[1]]
    return [n for _, p in pat[1] for n in _pattern_names(p)]


def _read_field(source: A.Expr, k: str) -> A.Expr:
    if source.t == "Path":
        return A.Path(source.root, source.fields + [k])
    return A.FieldAccess(source, [k])


def _bind_pattern(pat: Pattern, source: A.Expr) -> list[A.Stmt]:
    """Lowers ``pattern = source`` to plain bindings, in written order. A source
    that is a path is read directly (``$ctx.item.a``), so errors and static
    analyses see the reads a hand-written program would make; anything else is
    bound once to the hidden name ``#src`` first. Hidden names start with ``#``,
    which no surface name can (``A.is_hidden_name``)."""
    if pat[0] == "name":
        return [A.SLet(pat[1], source)]
    out: list[A.Stmt] = []
    if source.t != "Path":
        out.append(A.SLet("#src", source))
        source = A.Path("#src", [])
    for k, p in pat[1]:
        out.extend(_bind_pattern(p, _read_field(source, k)))
    return out


def _lower_lambda(params: list[Pattern], body: A.Expr) -> A.Expr:
    """A pattern parameter becomes a hidden parameter ``#argN``; the body is
    wrapped in the bindings that read the pattern's names out of it."""
    names: list[str] = []
    bound: list[A.Stmt] = []
    for i, p in enumerate(params):
        if p[0] == "name":
            names.append(p[1])
        else:
            names.append(f"#arg{i}")
            bound.extend(_bind_pattern(p, A.Path(f"#arg{i}", [])))
    for stmt in reversed(bound):
        body = A.Let(stmt.name, stmt.value, body)
    return A.Lambda(names, body)


def _as_scalar_arg(e: A.Expr) -> A.TypeConstraintArg:
    if e.t == "NumberLit":
        return A.ArgScalarNum(e.value)
    if e.t == "BoolLit":
        return A.ArgScalarBool(e.value)
    if e.t == "StringLit":
        return A.ArgScalarStr(e.value)
    return A.ArgScalarNull()


def _desugar_string(parts: list[tuple[str, object]]) -> A.Expr:
    coalesced: list[tuple[str, object]] = []
    for kind, v in parts:
        if coalesced and coalesced[-1][0] == "lit" and kind == "lit":
            coalesced[-1] = ("lit", coalesced[-1][1] + v)
        else:
            coalesced.append((kind, v))
    if not coalesced:
        return A.StringLit("")

    def part_expr(p: tuple[str, object]) -> A.Expr:
        kind, v = p
        if kind == "lit":
            return A.StringLit(v)
        return A.Call(A.Path("str", []), [v])

    acc = part_expr(coalesced[0])
    for p in coalesced[1:]:
        acc = A.Concat(acc, part_expr(p))
    return acc


def parse_program(src: str) -> A.Program:
    return _Parser(src).program()


def try_parse_program(src: str):
    """``parse_program``, returning ``(program, None)`` or ``(None, error)``."""
    try:
        return parse_program(src), None
    except ParseError as e:
        return None, e
