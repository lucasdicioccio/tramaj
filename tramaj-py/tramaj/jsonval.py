"""The ordinary JSON value domain (``specs/node-json.md``) plus the handful of
operations the rest of the port needs over it: order-insensitive structural
equality, and ``specs/reference.md`` section 6's normative ``str`` rendering.

A JSON value is one of ``None``, ``bool``, ``int``/``float``, ``str``,
``list`` or ``dict``. ``bool`` is never a number here, even though Python's
``bool`` subclasses ``int``: every predicate below checks for it first.
"""

from __future__ import annotations

import math
from typing import Any, Union

Json = Union[None, bool, int, float, str, list, dict]

# ECMAScript's Number is a double: an integer beyond this magnitude is no
# longer exact, and the other implementations round it the way a double does.
MAX_SAFE_INTEGER = 2**53


def is_number(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def is_json_object(v: Any) -> bool:
    return isinstance(v, dict)


def normalize_number(n: Union[int, float]) -> Union[int, float]:
    """Keeps a number in the shape a double would hold: an exact integer stays
    an ``int``, an integral float becomes one, ``-0`` becomes ``0``."""
    if isinstance(n, bool):
        raise TypeError("a bool is not a number")
    if isinstance(n, float):
        if math.isnan(n) or math.isinf(n):
            return n
        if n == 0:
            return 0
        if n.is_integer() and abs(n) <= MAX_SAFE_INTEGER:
            return int(n)
        return n
    if abs(n) > MAX_SAFE_INTEGER:
        return float(n)
    return n


def json_equal(a: Json, b: Json) -> bool:
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if is_number(a) and is_number(b):
        return a == b
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
    """``specs/reference.md`` section 6: exactly as ECMAScript's
    ``Number::toString`` renders a double."""
    if isinstance(n, bool):
        raise TypeError("a bool is not a number")
    if isinstance(n, int):
        if abs(n) <= MAX_SAFE_INTEGER:
            return str(n)
        n = float(n)
    if math.isnan(n):
        return "NaN"
    if math.isinf(n):
        return "Infinity" if n > 0 else "-Infinity"
    if n == 0:
        return "0"
    sign = "-" if n < 0 else ""
    digits, point = _shortest_digits(abs(n))
    k = len(digits)
    # ECMAScript Number::toString, steps 5-10, with n = point.
    if k <= point <= 21:
        return sign + digits + "0" * (point - k)
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
    """Indented JSON in source key order, rendering numbers the way the
    language does (an integral double prints without a fraction)."""
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
