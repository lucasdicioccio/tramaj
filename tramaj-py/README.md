# tramaj-py

Python port of the Tramaj language: parser, evaluator (concrete and symbolic
modes), the normative `Node` JSON codec, and the static analyses. Hand-written,
not generated from `tramaj/` (PureScript), `tramaj-hs/` (Haskell),
`tramaj-rs/` (Rust) or `tramaj-js/` (TypeScript); agreement with those is
enforced by the shared corpus at `../corpus/cases`, which `tests/test_corpus.py`
reads directly. Standard library only, Python 3.9+.

Specs: `../specs/reference.md`, `../specs/node-json.md`,
`../specs/v3-symbols.md`, `../specs/v4-types.md`.

## Public API

Everything is re-exported from the `tramaj` package. The module layout mirrors
`tramaj-js/src/*.ts` one-to-one.

| module | exports |
|---|---|
| `ast` | `Program`, the `Expr`/`TypeExpr`/`Attribute`/`ParamValue`/`Stmt` dataclasses; `sub_exprs`, `unlets`, `let_bindings`, `type_decls`, `number_allocs`, `adapt_key` |
| `parser` | `parse_program`, `try_parse_program`, `ParseError` |
| `evaluator` | `run_program`, `eval_program`, `to_json`; the `Value` dataclasses (`VInt` and `VFloat` for the two number types, `VTerm` for a term), `EvalError` |
| `node` | `TextNode`/`ElementNode`/`FragmentNode`, `AttributeAttr`/`ActionAttr`; `node_to_json`/`node_from_json`, `node_attribute_to_json`/`node_attribute_from_json`, `map_actions`, `NodeDecodeError` |
| `analysis` | `static_import_names`, `transitive_import_names`, `static_action_keys`, `deep_action_keys`, `context_holes`, `deep_context_holes`, `context_reads`, `unsupplied_params`, `constraint_kinds`, `deep_constraint_kinds`, `symbol_sites`, `symbol_demands`, `deep_symbol_demands`, `arithmetic_ops`, `deep_arithmetic_ops`, `ARITHMETIC_NAMES`, `type_declarations`, `type_params`, `unsupplied_type_params`, `type_param_collisions`, `program_card`, `program_kind` |
| `typesys` | `resolve_type_expr`, `canonical_id`, `require_closed`, `type_closure`, `erase_types`, `type_constraints`, `deep_type_constraints`, `type_references`, `deep_type_references`, `check_type_param_collisions`, `TramajTypeError` |
| `jsonval` | `parse_json`, `json_equal`, `compact_json`, `display_string`, `format_number`, `pretty_json`, `normalize_numbers`, `MIN_INTEGER`, `MAX_INTEGER` |

```python
from tramaj import parse_program, run_program

program = parse_program('.p($ctx.name)')
run_program("concrete", {}, {"name": "web"}, program)
# {'type': 'element', 'tag': 'p', 'attributes': [], 'value': None,
#  'children': [{'type': 'text', 'value': 'web', 'annotations': {}}], 'annotations': {}}
```

A library table is a `dict` from import name to parsed `Program`; a mode is
`"concrete"` or `"symbolic"`. Every set-valued analysis returns a sorted list,
so two runs over the same program agree on order as well as membership.

## Numbers

There are two number types, an integer and a float (`../specs/reference.md`
§3), and they are the two Python types: an `int` is an integer and a `float`
is a float. That holds for the context passed to `run_program` and for the
result it returns; a `bool` is neither. Nothing converts between the two
unless the program says so, with `real` or `floor`: `eq(1, 1.0)` is `false`
and `gt(1.5, 0)` is a `TypeMismatch`.

**Integer range: signed 64-bit**, `-2^63` to `2^63 - 1` (`int64` in the
corpus; `MIN_INTEGER` and `MAX_INTEGER` here). Python integers are unbounded,
so the range is enforced wherever an integer enters the value domain, and an
integer outside it is refused, never rounded:

| where | outside the range |
|---|---|
| an integer literal | `ParseError` |
| an `int` in the context, at any depth | `EvalError`, kind `TypeMismatch` |
| an arithmetic result, at each step of a `sum` or `product` | `EvalError`, kind `NotRepresentable` |
| a number in a node given to `node_from_json` | `NodeDecodeError` |

A float is a finite double with no negative zero: `inf` and `nan` are refused
at the same four places, and `-0.0` becomes `0.0`.

**JSON text.** A JSON number is typed by its text: `3` is an integer, `3.0`
and `3e0` are floats. `parse_json` reads text that way and keeps every digit
of an integer; it is the standard `json` module with `NaN` and `Infinity`
refused, so `json.loads` output works as a context too. To write a result,
use `compact_json` or `pretty_json`: an integer is written as its digits and
a float always with a fraction or an exponent, by ECMAScript's
`Number::toString` plus `.0` where that has neither (`1.0`,
`100000000000.0`, `1e+21`), as every implementation with the split writes it.
`json.dumps` keeps the two types apart as well, with a different spelling of
some floats (`1e-07`).

## Arithmetic

The arithmetic profile (`../specs/reference.md` §11) is an option of each
evaluation, off by default:

```python
program = parse_program('sum($ctx.compute, $ctx.storage, negate($ctx.credit))')
run_program("concrete", {}, {"compute": 40, "storage": 5, "credit": 3}, program, arithmetic=True)
# 42
run_program("concrete", {}, {"compute": 40, "storage": 5, "credit": 3}, program)
# EvalError: UnboundName sum
```

With it on, nine names are in the initial environment of the program and of
every library it imports: `sum`, `product`, `negate`, `inverse`, `quotient`,
`floor-quotient`, `modulo`, `floor` and `real`. `round`, the tenth name of
the profile, is not implemented in this port yet, and neither are `sort-by`,
`sort-by-descending` and `format-number`. Without the option the names are
unbound, and `deep_arithmetic_ops(libs, program)` lists the ones a program
references so a host can refuse it before running it.

Over a symbol, in symbolic mode, a builtin does not compute: it returns a term,
`{"$term": "sum", "arguments": [...]}`, with its operands as written
(`../specs/v3-symbols.md` §1.9). A well-formed term in the context is read
back as a term when the option is on.

## Command line

The same shape as `tramaj-cli-rs`:

```
python -m tramaj [evaluate] [--lib name=path ...] [--mode concrete|symbolic] [--arithmetic] <template-file> <context-json-file>
python -m tramaj analyze <imports|actions|holes|unsupplied|constraints|symbols|arithmetic|types|card|all> <template-file> [--lib name=path ...]
```

Evaluation prints the result JSON on stdout: the node-json document, the plain
value, or the symbolic envelope. A parse error exits 2 and an evaluation error
exits 1, each printed on stderr leading with the error kind.

`--arithmetic` turns the arithmetic profile on for the run. When an
evaluation fails without it and the program references one of the nine names,
the error names them and the flag. `analyze arithmetic` prints
`deep_arithmetic_ops`. Numbers keep the type their text has, in the context
file and in the output.

## Tests

```
uv run --no-project python -m unittest discover -s tests
```

or `python3 -m unittest discover -s tests`; nothing needs installing.

`tests/test_corpus.py` runs every case under `../corpus/cases` in the mode its
`meta.json` names, with the arithmetic profile on only for a case that lists
`arithmetic`. It declares the profiles `base`, `int-float`, `arithmetic` and
`int64`, and skips a case that lists any other (`sort`, `format-number`,
`round`, `int53`), counted in `OK (skipped=N)`. `tests/test_node_json.py`
covers the decoder's rejection list and the round-trip law;
`tests/test_analysis.py` covers the analyses and the number rendering;
`tests/test_numbers.py` covers the integer range, the Python binding of the
two number types, the arithmetic option and the command line.
