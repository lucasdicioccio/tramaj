"""The ordinary JSON value domain (``specs/node-json.md``) plus the handful of
operations the rest of the port needs over it: order-insensitive structural
equality, the number rules of ``specs/reference.md`` section 3, and section 6's
normative ``str`` rendering.

A JSON value is one of ``None``, ``bool``, ``int``, ``float``, ``str``,
``list`` or ``dict``. The two number types of the language are the two Python
types: an ``int`` is an integer and a ``float`` is a float, and nothing here
ever turns one into the other. ``bool`` is never a number, even though
Python's ``bool`` subclasses ``int``: every predicate below checks for it
first.
"""

from __future__ import annotations

import json
import math
from typing import Any, Union

Json = Union[None, bool, int, float, str, list, dict]

# The integer range this port provides (reference.md section 13): the signed
# 64-bit range, ``int64`` in the corpus. A Python ``int`` is unbounded, so the
# range is enforced wherever an integer enters the value domain: a literal
# (a parse error), a JSON number at a boundary (refused), an arithmetic result
# (``NotRepresentable``). Nothing is ever rounded into the range.
MIN_INTEGER = -(2**63)
MAX_INTEGER = 2**63 - 1


def in_integer_range(n: int) -> bool:
    return MIN_INTEGER <= n <= MAX_INTEGER


def is_integer(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def is_float(v: Any) -> bool:
    return isinstance(v, float)


def is_number(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def is_json_object(v: Any) -> bool:
    return isinstance(v, dict)


def normalize_integer(n: int) -> int:
    """An integer-form number as the value it denotes: one outside the integer
    range is refused, never rounded (reference.md sections 3 and 13)."""
    if not in_integer_range(n):
        raise ValueError(f"the integer {n} is outside the signed 64-bit range")
    return n


def normalize_float(x: float) -> float:
    """A float-form number as the value it denotes. One too large for a double
    is refused, as the literal ``1e400`` is a parse error; a negative zero is
    zero, as the literal ``-0.0`` evaluates to ``0.0``."""
    if math.isnan(x) or math.isinf(x):
        raise ValueError("a float is too large for a double")
    return 0.0 if x == 0 else x


def normalize_numbers(v: Json) -> Json:
    """What a decoder does to the numbers of a JSON value it is about to treat
    as a Tramaj value, at any depth: ``normalize_integer`` for each integer and
    ``normalize_float`` for each float. Raises ``ValueError`` for a number the
    value domain does not hold. The context decoder and ``node_from_json``
    both go through these rules."""
    if isinstance(v, bool) or v is None or isinstance(v, str):
        return v
    if isinstance(v, int):
        return normalize_integer(v)
    if isinstance(v, float):
        return normalize_float(v)
    if isinstance(v, list):
        return [normalize_numbers(x) for x in v]
    if isinstance(v, dict):
        return {k: normalize_numbers(x) for k, x in v.items()}
    raise ValueError(f"not a JSON value: {v!r}")


def _refuse_constant(name: str):
    raise ValueError(f"{name} is not JSON")


def parse_json(text: str) -> Json:
    """JSON text as a ``Json`` value whose numbers keep the type their text
    gives them (reference.md section 3): one with neither a fraction nor an
    exponent is an ``int``, with all of its digits, and one with either is a
    ``float``, so ``3`` and ``3.0`` stay apart. This is what the standard
    ``json`` module already does; the one thing changed is that ``NaN`` and
    ``Infinity``, which are not JSON, are refused.

    Nothing is refused for its size here: an integer beyond 64 bits comes back
    whole and ``1e400`` comes back as an infinity, and it is the boundary that
    reads the value (``run_program`` for a context, ``node_from_json`` for a
    node) that refuses them. Raises ``ValueError`` on malformed text."""
    return json.loads(text, parse_constant=_refuse_constant)


def json_equal(a: Json, b: Json) -> bool:
    """Structural equality, insensitive to key order. An integer and a float
    are never equal, whatever their values: ``1`` and ``1.0`` are two values."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if is_number(a) and is_number(b):
        return isinstance(a, float) == isinstance(b, float) and a == b
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(json_equal(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return len(a) == len(b) and all(k in b and json_equal(a[k], b[k]) for k in a)
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, str) and isinstance(b, str):
        return a == b
    return False


def _shortest_digits(x: float) -> tuple[str, int]:
    """The shortest round-tripping decimal digits of a positive finite float,
    as ``(digits, exponent)`` with the value ``0.digits * 10**exponent``."""
    r = repr(x)
    if "e" in r:
        mant, exp = r.split("e")
        e = int(exp)
    else:
        mant, e = r, 0
    if "." in mant:
        ip, fp = mant.split(".")
    else:
        ip, fp = mant, ""
    digits = (ip + fp).lstrip("0")
    # position of the decimal point relative to the start of `digits`
    point = len(ip) - (len(ip + fp) - len((ip + fp).lstrip("0"))) + e
    digits = digits.rstrip("0")
    if digits == "":
        return "0", 1
    return digits, point


def format_number(n: Union[int, float]) -> str:
    """How a number is written, in ``str`` (reference.md section 6) and in
    JSON (node-json.md, *Numbers*) alike, so the text keeps the type.

    An integer is its decimal digits, with a ``-`` when negative. A float is
    the shortest round-trip text of ECMAScript's ``Number::toString``, with
    ``.0`` appended when that text has neither a fraction nor an exponent:
    ``1.0``, ``0.1``, ``100000000000.0``, ``1e+21``, ``1e-7``."""
    if isinstance(n, bool):
        raise TypeError("a bool is not a number")
    if isinstance(n, int):
        return str(n)
    if math.isnan(n) or math.isinf(n):
        raise ValueError("a float value is finite")
    if n == 0:
        return "0.0"
    sign = "-" if n < 0 else ""
    digits, point = _shortest_digits(abs(n))
    k = len(digits)
    # ECMAScript Number::toString, steps 5-10, with n = point.
    if k <= point <= 21:
        return sign + digits + "0" * (point - k) + ".0"
    if 0 < point <= 21:
        return sign + digits[:point] + "." + digits[point:]
    if -6 < point <= 0:
        return sign + "0." + "0" * (-point) + digits
    e = point - 1
    exp = ("+" if e >= 0 else "-") + str(abs(e))
    if k == 1:
        return sign + digits + "e" + exp
    return sign + digits[0] + "." + digits[1:] + "e" + exp


def quote_string(s: str) -> str:
    """JSON string quoting as ``JSON.stringify`` does it: only the characters
    JSON requires are escaped, everything else stays raw."""
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\b":
            out.append("\\b")
        elif ch == "\f":
            out.append("\\f")
        elif o < 0x20 or 0xD800 <= o <= 0xDFFF:
            out.append("\\u%04x" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def utf16_key(s: str) -> bytes:
    """Sort key giving the UTF-16 code-unit order ECMAScript's ``<`` uses on
    strings, so two implementations agree on the order of astral characters."""
    return s.encode("utf-16-be", "surrogatepass")


def sorted_strings(xs) -> list[str]:
    return sorted(set(xs), key=utf16_key)


def compact_json(v: Json) -> str:
    """Compact JSON with object keys sorted (``specs/reference.md`` section 6)."""
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if is_number(v):
        return format_number(v)
    if isinstance(v, str):
        return quote_string(v)
    if isinstance(v, list):
        return "[" + ",".join(compact_json(x) for x in v) + "]"
    keys = sorted(v.keys(), key=utf16_key)
    return "{" + ",".join(quote_string(k) + ":" + compact_json(v[k]) for k in keys) + "}"


def display_string(v: Json) -> str:
    """``str``'s rendering (section 6): raw at the top level, compact below it."""
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if is_number(v):
        return format_number(v)
    if isinstance(v, str):
        return v
    return compact_json(v)


def pretty_json(v: Json, indent: int = 2) -> str:
    """Indented JSON in source key order, with each number written by
    ``format_number``: an integer as its digits, a float always with a
    fraction or an exponent, so the text can be read back with its types."""
    pad = " " * indent

    def go(x: Json, depth: int) -> str:
        if isinstance(x, list):
            if not x:
                return "[]"
            inner = ",\n".join(pad * (depth + 1) + go(i, depth + 1) for i in x)
            return "[\n" + inner + "\n" + pad * depth + "]"
        if isinstance(x, dict):
            if not x:
                return "{}"
            inner = ",\n".join(
                pad * (depth + 1) + quote_string(k) + ": " + go(x[k], depth + 1) for k in x
            )
            return "{\n" + inner + "\n" + pad * depth + "}"
        return compact_json(x)

    return go(v, 0)
