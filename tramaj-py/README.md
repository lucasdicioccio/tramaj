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
| `evaluator` | `run_program`, `eval_program`, `to_json`; the `Value` dataclasses, `EvalError` |
| `node` | `TextNode`/`ElementNode`/`FragmentNode`, `AttributeAttr`/`ActionAttr`; `node_to_json`/`node_from_json`, `node_attribute_to_json`/`node_attribute_from_json`, `map_actions`, `NodeDecodeError` |
| `analysis` | `static_import_names`, `transitive_import_names`, `static_action_keys`, `deep_action_keys`, `context_holes`, `deep_context_holes`, `context_reads`, `unsupplied_params`, `constraint_kinds`, `deep_constraint_kinds`, `symbol_sites`, `symbol_demands`, `deep_symbol_demands`, `type_declarations`, `type_params`, `unsupplied_type_params`, `type_param_collisions`, `program_card`, `program_kind` |
| `typesys` | `resolve_type_expr`, `canonical_id`, `require_closed`, `type_closure`, `erase_types`, `type_constraints`, `deep_type_constraints`, `type_references`, `deep_type_references`, `check_type_param_collisions`, `TramajTypeError` |
| `jsonval` | `json_equal`, `compact_json`, `display_string`, `format_number`, `pretty_json` |

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

Numbers follow the language's double semantics: an exact integer is a Python
`int`, anything else a `float`, and `str`/`format_number` render exactly as
ECMAScript's `Number::toString` does (`1e21` → `1e+21`, `-2.0` → `-2`).

## Command line

The same shape as `tramaj-cli-rs`:

```
python -m tramaj [evaluate] [--lib name=path ...] [--mode concrete|symbolic] <template-file> <context-json-file>
python -m tramaj analyze <imports|actions|holes|unsupplied|constraints|symbols|types|card|all> <template-file> [--lib name=path ...]
```

Evaluation prints the result JSON on stdout: the node-json document, the plain
value, or the symbolic envelope. A parse error exits 2 and an evaluation error
exits 1, each printed on stderr leading with the error kind.

## Tests

```
python3 -m unittest discover -s tests
```

`tests/test_corpus.py` runs every case under `../corpus/cases` in the mode its
`meta.json` names; `tests/test_node_json.py` covers the decoder's rejection
list and the round-trip law; `tests/test_analysis.py` covers the analyses and
the number rendering.
