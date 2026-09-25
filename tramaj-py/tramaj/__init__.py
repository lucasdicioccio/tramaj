"""Python port of the Tramaj language (``specs/reference.md``,
``specs/v3-symbols.md``, ``specs/v4-types.md``, ``specs/node-json.md``).
Hand-written, not generated from ``tramaj/``, ``tramaj-hs/``, ``tramaj-rs/`` or
``tramaj-js/``; agreement with those implementations is enforced by the shared
corpus at ``corpus/cases/`` (see ``tests/test_corpus.py``).

Module layout mirrors ``tramaj-js/src/*.ts`` one-to-one: ``ast``, ``jsonval``
(json), ``node``, ``parser``, ``evaluator`` (eval), ``analysis``, ``typesys``
(types). Nothing here depends on anything outside the standard library.
"""

from . import analysis, ast, evaluator, jsonval, node, parser, typesys
from .analysis import (
    constraint_kinds,
    context_holes,
    context_reads,
    deep_action_keys,
    deep_constraint_kinds,
    deep_context_holes,
    deep_symbol_demands,
    program_card,
    program_kind,
    static_action_keys,
    static_import_names,
    symbol_demands,
    symbol_sites,
    transitive_import_names,
    type_declarations,
    type_exprs_in,
    type_param_collisions,
    type_params,
    unsupplied_params,
    unsupplied_type_params,
)
from .ast import (
    Program,
    adapt_key,
    document_program,
    expression_program,
    let_bindings,
    number_allocs,
    sub_exprs,
    type_decls,
    unlets,
)
from .evaluator import EvalError, eval_program, run_program, to_json
from .jsonval import compact_json, display_string, format_number, json_equal, pretty_json
from .node import (
    NodeDecodeError,
    element_node,
    fragment_node,
    map_actions,
    no_annotations,
    node_attribute_from_json,
    node_attribute_to_json,
    node_from_json,
    node_to_json,
    text_node,
)
from .parser import ParseError, parse_program, try_parse_program
from .typesys import (
    TramajTypeError,
    canonical_id,
    check_type_param_collisions,
    deep_type_constraints,
    deep_type_references,
    erase_types,
    program_type_decls,
    program_type_roots,
    require_closed,
    resolve_type_expr,
    resolved_type_equal,
    type_closure,
    type_constraints,
    type_references,
)

__all__ = [n for n in dir() if not n.startswith("_")]
__version__ = "0.1.0"
