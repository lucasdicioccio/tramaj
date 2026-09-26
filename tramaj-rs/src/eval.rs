//! `Value`, the environment, and the evaluator — concrete and symbolic modes
//! (`specs/reference.md` §6, §7, §10; `specs/v3-symbols.md` §4-6). Mirrors
//! `tramaj-hs/src/Tramaj/Eval.hs`, covering R1 (core v2) plus R2 (v3
//! symbols/constraints): no v4 types.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};

use serde_json::{Map as JsonMap, Number as JsonNumber, Value as Json};

use crate::analysis::symbol_sites;
use crate::ast::{ActionAdaptation, Attribute, Expr, ParamValue, Program};
use crate::node::{self, Node, NodeAttribute};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Concrete,
    Symbolic,
}

/// Host-supplied library table: import name -> parsed library program.
pub type LibraryTable = HashMap<String, Program>;

/// Error kinds from `specs/reference.md` §12. The corpus harness matches on
/// the first word of `Display` (mirroring `tramaj-hs`'s `errorConstructor`),
/// so every variant's `Display` must lead with its bare constructor name.
#[derive(Debug, Clone, PartialEq)]
pub enum EvalError {
    UnboundName(String),
    PathNotFound(Vec<String>),
    TypeMismatch(String),
    ConcatMismatch(String),
    UnknownLibrary(String),
    ImportCycle(String),
    InLibrary(String, Box<EvalError>),
    /// A symbol would have to be minted in concrete mode: an allocation
    /// (`?(k)`, v3-symbols §5.1) or an unsupplied `?ctx.path` demand at the
    /// root (§1.3). Symbolic mode never raises it.
    SymbolsUnavailable(String),
    /// A symbolic value where the language requires a concrete one
    /// (v3-symbols §1.5's table, and a symbol used as an allocation key).
    NotConcrete(String),
    /// A program containing `?(k)` is loaded as a library (v3-symbols §1.4):
    /// only the root may allocate. Lexical, not data-flow.
    AllocationInLibrary(String),
    /// A static v4-types failure (`v4-types.md` §10), surfaced from either
    /// the erasure pass every entry point below runs before evaluating
    /// anything (§7) or from building the symbolic envelope's
    /// `"types"`/`"type-constraints"` lists (§8). Not a new evaluation
    /// failure mode — nothing here is raised *during* evaluation — but
    /// `types::TypeError` still needs a home in the one error type every
    /// entry point already returns.
    TypeErr(crate::types::TypeError),
}

impl std::fmt::Display for EvalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EvalError::UnboundName(n) => write!(f, "UnboundName {n}"),
            EvalError::PathNotFound(p) => write!(f, "PathNotFound {p:?}"),
            EvalError::TypeMismatch(m) => write!(f, "TypeMismatch {m}"),
            EvalError::ConcatMismatch(m) => write!(f, "ConcatMismatch {m}"),
            EvalError::UnknownLibrary(n) => write!(f, "UnknownLibrary {n}"),
            EvalError::ImportCycle(n) => write!(f, "ImportCycle {n}"),
            EvalError::InLibrary(n, e) => write!(f, "InLibrary {n} ({e})"),
            EvalError::SymbolsUnavailable(m) => write!(f, "SymbolsUnavailable {m}"),
            EvalError::NotConcrete(m) => write!(f, "NotConcrete {m}"),
            EvalError::AllocationInLibrary(n) => write!(f, "AllocationInLibrary {n}"),
            EvalError::TypeErr(e) => write!(f, "TypeErr {e}"),
        }
    }
}

type EResult<T> = Result<T, EvalError>;

// Values ---------------------------------------------------------------------

/// The language's value domain. Arrays/objects hold `Value`, not JSON, so a
/// document node can travel inside a structure like any other value.
#[derive(Debug, Clone)]
pub enum Value {
    Null,
    Bool(bool),
    Number(f64),
    Str(String),
    Array(Vec<Value>),
    Object(HashMap<String, Value>),
    Node(Node),
    Closure(Vec<String>, Expr, Env),
    Builtin(String),
    /// An import's `{rendered, vals}` result, once it has run — reuses `Env`
    /// as the field map, mirroring `tramaj-hs`'s `VEnv`.
    ImportResult(Env),
    Import(Pending),
    /// A symbol (v3-symbols §1.1): opaque data, identified by a `SymbolId`
    /// and a projection path extended one segment at a time by field access
    /// (§1.6). An allocation (`?(k)`) starts with an empty path; so does a
    /// demand (`?ctx.path`) once minted — its own path is baked into the id,
    /// not carried here.
    Symbol(SymbolId, Vec<String>),
    /// `constraint(name, args...)` (v3-symbols §2.1): a value like any
    /// other, so it can be bound, passed around and collected into an
    /// array, right up until it tries to cross a JSON boundary (`to_json`
    /// refuses it) or is left unreached by any `!`.
    Constraint(String, Vec<Value>),
}

/// A symbol's identity (v3-symbols §1.4): a string, identical in every
/// conforming implementation for the same program and key.
pub type SymbolId = String;

impl PartialEq for Value {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Value::Null, Value::Null) => true,
            (Value::Bool(a), Value::Bool(b)) => a == b,
            (Value::Number(a), Value::Number(b)) => a == b,
            (Value::Str(a), Value::Str(b)) => a == b,
            (Value::Array(a), Value::Array(b)) => a == b,
            (Value::Object(a), Value::Object(b)) => a == b,
            (Value::Node(a), Value::Node(b)) => a == b,
            _ => false,
        }
    }
}

pub type Env = HashMap<String, Value>;

#[derive(Debug, Clone)]
pub struct Pending {
    name: String,
    params: HashMap<String, Value>,
    queued: Vec<(ActionAdaptation, Option<Value>)>,
}

/// An entry in the symbol table (v3-symbols §5.2). Only allocations appear
/// there — which includes an unsupplied demand minted at the root (§1.3),
/// since that too is the root allocating — and a symbol the host seeded
/// (§5.4) is never listed, since the language has nothing to add about one
/// it did not mint.
#[derive(Debug, Clone)]
struct SymbolEntry {
    id: SymbolId,
    origin: SymbolOrigin,
    binding: Option<String>,
}

#[derive(Debug, Clone)]
enum SymbolOrigin {
    Alloc(usize, Json),
    Demand(Vec<String>),
}

/// What evaluation accumulates alongside its result (v3-symbols §4):
/// emitted constraints and allocated symbol-table entries, each in
/// evaluation order and deduplicated only once, globally, at the top
/// (`dedupe`) rather than on every append.
#[derive(Default)]
struct Emissions {
    constraints: Vec<Value>,
    symbols: Vec<SymbolEntry>,
}

impl Emissions {
    fn snapshot(&self) -> (usize, usize) {
        (self.constraints.len(), self.symbols.len())
    }

    /// Rolls emissions back to a prior snapshot — used only where
    /// `tryEval`-equivalent code inspects a failed sub-evaluation's error
    /// and continues, so anything it emitted along the way is discarded
    /// with it (mirrors `tramaj-hs`'s `tryEval` returning `mempty` on the
    /// `Left` branch).
    fn restore(&mut self, snap: (usize, usize)) {
        self.constraints.truncate(snap.0);
        self.symbols.truncate(snap.1);
    }
}

struct EvalCtx<'a> {
    libs: &'a LibraryTable,
    in_progress: HashSet<String>,
    mode: Mode,
    /// Whether this is the root program or somewhere inside a library
    /// (v3-symbols §1.3, §1.4) — a library never allocates or mints, no
    /// matter how deep the chain that reached it.
    is_root: bool,
    emissions: &'a RefCell<Emissions>,
}

fn enter_library<'a>(name: &str, ctx: &EvalCtx<'a>) -> EvalCtx<'a> {
    let mut in_progress = ctx.in_progress.clone();
    in_progress.insert(name.to_string());
    EvalCtx {
        libs: ctx.libs,
        in_progress,
        mode: ctx.mode,
        is_root: false,
        emissions: ctx.emissions,
    }
}

fn tell_constraints(ctx: &EvalCtx, vs: Vec<Value>) {
    ctx.emissions.borrow_mut().constraints.extend(vs);
}

fn tell_symbol(ctx: &EvalCtx, entry: SymbolEntry) {
    ctx.emissions.borrow_mut().symbols.push(entry);
}

// Entry points -----------------------------------------------------------

pub enum Output {
    ONode(Node),
    OValue(Json),
}

pub fn eval_program(
    mode: Mode,
    libs: &LibraryTable,
    ctx: &Json,
    program: &Program,
) -> EResult<Output> {
    Ok(eval_program_with_emissions(mode, libs, ctx, program)?.0)
}

/// As `eval_program`, but also returns the deduplicated `Emissions`
/// (v3-symbols §4) — empty for any program that emits or allocates nothing,
/// and always empty in what concrete mode goes on to serialize, since
/// concrete mode discards them (§5.1) and cannot produce a symbol at all.
fn eval_program_with_emissions(
    mode: Mode,
    libs: &LibraryTable,
    ctx: &Json,
    program: &Program,
) -> EResult<(Output, Emissions)> {
    let erased = crate::types::erase_types(libs, program).map_err(EvalError::TypeErr)?;
    let ctx_val = checked_from_json(mode, ctx)?;
    let emissions = RefCell::new(Emissions::default());
    let eval_ctx = EvalCtx {
        libs,
        in_progress: HashSet::new(),
        mode,
        is_root: true,
        emissions: &emissions,
    };
    let env = initial_env(ctx_val);
    let v = eval_expr(&eval_ctx, &env, erased.root())?;
    let output = match v {
        Value::Node(n) => Output::ONode(n),
        other => Output::OValue(to_json(&other)?),
    };
    Ok((output, dedupe(emissions.into_inner())))
}

/// Two constraints with the same name and equal arguments are one
/// constraint, and two symbol-table entries with the same id are one entry
/// — each kept at the position of the first (v3-symbols §4).
fn dedupe(e: Emissions) -> Emissions {
    let mut out_constraints: Vec<Value> = Vec::new();
    for c in e.constraints {
        if !out_constraints.iter().any(|x| constraint_eq(x, &c)) {
            out_constraints.push(c);
        }
    }
    let mut out_symbols: Vec<SymbolEntry> = Vec::new();
    for s in e.symbols {
        if !out_symbols.iter().any(|x| x.id == s.id) {
            out_symbols.push(s);
        }
    }
    Emissions {
        constraints: out_constraints,
        symbols: out_symbols,
    }
}

/// Structural equality restricted to what a constraint's identity is made
/// of: its name and its arguments, each compared as the JSON they will
/// render as.
fn constraint_eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Constraint(n1, as1), Value::Constraint(n2, as2)) => {
            n1 == n2
                && as1.len() == as2.len()
                && as1.iter().zip(as2).all(|(x, y)| match (to_json(x), to_json(y)) {
                    (Ok(jx), Ok(jy)) => jx == jy,
                    _ => false,
                })
        }
        _ => false,
    }
}

/// Evaluates and serializes to the wire JSON a host compares against
/// `expected.json`.
pub fn run_program(
    mode: Mode,
    libs: &LibraryTable,
    ctx: &Json,
    program: &Program,
) -> EResult<Json> {
    let (output, emissions) = eval_program_with_emissions(mode, libs, ctx, program)?;
    match mode {
        Mode::Concrete => Ok(match output {
            Output::ONode(n) => node::node_to_json(&n),
            Output::OValue(v) => v,
        }),
        Mode::Symbolic => {
            let (kind, root) = match output {
                Output::ONode(n) => ("document", node::node_to_json(&n)),
                Output::OValue(v) => ("expression", v),
            };
            let (types_table, type_constraints_list) = build_types_info(libs, program).map_err(EvalError::TypeErr)?;
            let mut m = JsonMap::new();
            m.insert(
                "format".to_string(),
                Json::String("tramaj/symbolic/1".to_string()),
            );
            m.insert("kind".to_string(), Json::String(kind.to_string()));
            m.insert("root".to_string(), root);
            m.insert(
                "symbols".to_string(),
                Json::Array(emissions.symbols.iter().map(symbol_entry_to_json).collect()),
            );
            m.insert(
                "constraints".to_string(),
                Json::Array(emissions.constraints.iter().map(constraint_to_json).collect()),
            );
            let mut sorted_types: Vec<(&String, &crate::types::ResolvedType)> = types_table.iter().collect();
            sorted_types.sort_by(|a, b| a.0.cmp(b.0));
            m.insert(
                "types".to_string(),
                Json::Array(sorted_types.into_iter().map(type_entry_to_json).collect()),
            );
            m.insert(
                "type-constraints".to_string(),
                Json::Array(type_constraints_list.iter().map(type_constraint_to_json).collect()),
            );
            Ok(Json::Object(m))
        }
    }
}

/// The `"types"` table's entries and the deduplicated `"type-constraints"`
/// list (`v4-types.md` §8), computed from `prog` *before* erasure — unlike
/// evaluation, which never needs a `TypeAnnotate`/`TypeEmit` once erasure
/// has run, this is the one place they still matter: the envelope is
/// exactly where a host needs the definitions and constraints those nodes
/// named. Concrete mode never calls this, matching §8's promise that a v3
/// consumer reading a v4 envelope sees nothing new.
type TypesInfo = (
    HashMap<String, crate::types::ResolvedType>,
    Vec<(String, Vec<crate::types::ResolvedConstraintArg>)>,
);

fn build_types_info(libs: &LibraryTable, prog: &Program) -> Result<TypesInfo, crate::types::TypeError> {
    let roots = crate::types::program_type_roots(libs, prog)?;
    let closure = crate::types::type_closure(libs, prog, &roots)?;
    let tcs = crate::types::deep_type_constraints(libs, prog)?;
    Ok((closure, tcs))
}

/// One `"types"` table entry (`v4-types.md` §8): the id, and the definition
/// behind it, rendered by `resolved_type_to_json`.
fn type_entry_to_json((tid, rt): (&String, &crate::types::ResolvedType)) -> Json {
    let mut m = JsonMap::new();
    m.insert("id".to_string(), Json::String(tid.clone()));
    m.insert("definition".to_string(), resolved_type_to_json(rt));
    Json::Object(m)
}

/// A `ResolvedType`'s `"definition"` shape (`v4-types.md` §8's example): a
/// tagged union whose `kind` names which of the six algebra shapes it is. A
/// `Ref` renders as a pointer only — its own definition is a separate entry
/// in the table, not inlined here — which is §3's "stop at declaration
/// boundaries" clause, still honoured at the JSON boundary.
fn resolved_type_to_json(rt: &crate::types::ResolvedType) -> Json {
    use crate::types::ResolvedType;
    match rt {
        ResolvedType::Prim(name) => {
            let mut m = JsonMap::new();
            m.insert("kind".to_string(), Json::String("prim".to_string()));
            m.insert("name".to_string(), Json::String(name.clone()));
            Json::Object(m)
        }
        ResolvedType::Array(t) => {
            let mut m = JsonMap::new();
            m.insert("kind".to_string(), Json::String("array".to_string()));
            m.insert("element".to_string(), resolved_type_to_json(t));
            Json::Object(m)
        }
        ResolvedType::Record(fields) => {
            let mut m = JsonMap::new();
            m.insert("kind".to_string(), Json::String("record".to_string()));
            m.insert(
                "fields".to_string(),
                Json::Array(
                    fields
                        .iter()
                        .map(|(n, t)| {
                            let mut fm = JsonMap::new();
                            fm.insert("name".to_string(), Json::String(n.clone()));
                            fm.insert("type".to_string(), resolved_type_to_json(t));
                            Json::Object(fm)
                        })
                        .collect(),
                ),
            );
            Json::Object(m)
        }
        ResolvedType::Union(arms) => {
            let mut m = JsonMap::new();
            m.insert("kind".to_string(), Json::String("union".to_string()));
            m.insert(
                "arms".to_string(),
                Json::Array(
                    arms.iter()
                        .map(|(n, mt)| {
                            let mut am = JsonMap::new();
                            am.insert("name".to_string(), Json::String(n.clone()));
                            if let Some(t) = mt {
                                am.insert("payload".to_string(), resolved_type_to_json(t));
                            }
                            Json::Object(am)
                        })
                        .collect(),
                ),
            );
            Json::Object(m)
        }
        ResolvedType::Ref(_, _, _) => {
            let mut m = JsonMap::new();
            m.insert("kind".to_string(), Json::String("ref".to_string()));
            m.insert("id".to_string(), Json::String(crate::types::canonical_id(rt)));
            Json::Object(m)
        }
        ResolvedType::Var(path) => {
            let mut m = JsonMap::new();
            m.insert("kind".to_string(), Json::String("var".to_string()));
            m.insert(
                "path".to_string(),
                Json::Array(path.iter().map(|s| Json::String(s.clone())).collect()),
            );
            Json::Object(m)
        }
    }
}

/// A `"type-constraints"` entry (`v4-types.md` §8): a name and its resolved
/// arguments, a type argument rendered as the erased `{"$type": ...}` tag §7
/// already reserves so a host reads both lists the same way, a scalar
/// argument as the plain JSON it already is.
fn type_constraint_to_json((name, args): &(String, Vec<crate::types::ResolvedConstraintArg>)) -> Json {
    use crate::types::ResolvedConstraintArg;
    let mut m = JsonMap::new();
    m.insert("name".to_string(), Json::String(name.clone()));
    m.insert(
        "arguments".to_string(),
        Json::Array(
            args.iter()
                .map(|a| match a {
                    ResolvedConstraintArg::Type(rt) => {
                        let mut am = JsonMap::new();
                        am.insert("$type".to_string(), Json::String(crate::types::canonical_id(rt)));
                        Json::Object(am)
                    }
                    ResolvedConstraintArg::ScalarStr(s) => Json::String(s.clone()),
                    ResolvedConstraintArg::ScalarNum(n) => number_to_json(*n),
                    ResolvedConstraintArg::ScalarBool(b) => Json::Bool(*b),
                    ResolvedConstraintArg::ScalarNull => Json::Null,
                })
                .collect(),
        ),
    );
    Json::Object(m)
}

/// A constraint's envelope rendering (v3-symbols §5.2): its name and its
/// arguments, each already-evaluated to plain JSON, an argument that is
/// itself a symbol rendering as §5.3's tagged shape via `to_json`.
fn constraint_to_json(v: &Value) -> Json {
    match v {
        Value::Constraint(name, args) => {
            let mut m = JsonMap::new();
            m.insert("name".to_string(), Json::String(name.clone()));
            m.insert(
                "arguments".to_string(),
                Json::Array(args.iter().map(|a| to_json(a).unwrap_or(Json::Null)).collect()),
            );
            Json::Object(m)
        }
        other => to_json(other).unwrap_or(Json::Null),
    }
}

/// A symbol table entry's envelope rendering (v3-symbols §5.2): id, origin
/// (the structured form of the id, so a host never has to parse it) and
/// binding.
fn symbol_entry_to_json(e: &SymbolEntry) -> Json {
    let mut m = JsonMap::new();
    m.insert("id".to_string(), Json::String(e.id.clone()));
    let origin = match &e.origin {
        SymbolOrigin::Alloc(site, key) => {
            let mut om = JsonMap::new();
            om.insert("kind".to_string(), Json::String("alloc".to_string()));
            om.insert("site".to_string(), Json::Number(JsonNumber::from(*site as u64)));
            om.insert("key".to_string(), key.clone());
            Json::Object(om)
        }
        SymbolOrigin::Demand(path) => {
            let mut om = JsonMap::new();
            om.insert("kind".to_string(), Json::String("demand".to_string()));
            om.insert(
                "path".to_string(),
                Json::Array(path.iter().map(|s| Json::String(s.clone())).collect()),
            );
            Json::Object(om)
        }
    };
    m.insert("origin".to_string(), origin);
    m.insert(
        "binding".to_string(),
        e.binding.clone().map(Json::String).unwrap_or(Json::Null),
    );
    Json::Object(m)
}

fn initial_env(ctx_val: Value) -> Env {
    let mut env: Env = builtin_names()
        .iter()
        .map(|n| (n.to_string(), Value::Builtin(n.to_string())))
        .collect();
    env.insert("ctx".to_string(), ctx_val);
    env
}

fn builtin_names() -> &'static [&'static str] {
    &[
        "cardinality",
        "count",
        "str",
        "not",
        "and",
        "or",
        "eq",
        "lt",
        "lte",
        "gt",
        "gte",
        "has",
        "lookup",
        "concat",
        "append",
    ]
}

// Core evaluation --------------------------------------------------------

fn eval_expr(ctx: &EvalCtx, env: &Env, e: &Expr) -> EResult<Value> {
    match e {
        Expr::Path(root, fields) => {
            let v = env
                .get(root)
                .cloned()
                .ok_or_else(|| EvalError::UnboundName(root.clone()))?;
            let mut context = vec![root.clone()];
            context.extend(fields.iter().cloned());
            walk_fields(ctx, &context, v, fields)
        }
        Expr::FieldAccess(target, fields) => {
            let v = eval_expr(ctx, env, target)?;
            walk_fields(ctx, fields, v, fields)
        }
        Expr::Call(fn_expr, arg_exprs) => {
            let fn_val = eval_expr(ctx, env, fn_expr)?;
            let arg_vals = arg_exprs
                .iter()
                .map(|a| eval_expr(ctx, env, a))
                .collect::<EResult<Vec<_>>>()?;
            apply(ctx, &describe_callee(fn_expr), fn_val, arg_vals)
        }
        Expr::Lambda(params, body) => Ok(Value::Closure(params.clone(), (**body).clone(), env.clone())),
        // `@name=?(k)` or `@name=?ctx.path` binds the allocation/demand
        // directly to a name, which is what the symbol table's `"binding"`
        // field (v3-symbols §5.2) reports; anything else evaluates exactly
        // as it always has (`eval_bindable`).
        Expr::Let(name, value_expr, body) => {
            let binding = if crate::ast::is_hidden_name(name) { None } else { Some(name.clone()) };
            let v = eval_bindable(ctx, env, binding, value_expr)?;
            let mut env2 = env.clone();
            env2.insert(name.clone(), v);
            eval_expr(ctx, &env2, body)
        }
        Expr::StringLit(s) => Ok(Value::Str(s.clone())),
        Expr::NumberLit(n) => Ok(Value::Number(*n)),
        Expr::BoolLit(b) => Ok(Value::Bool(*b)),
        Expr::NullLit => Ok(Value::Null),
        Expr::ArrayLit(elems) => Ok(Value::Array(
            elems
                .iter()
                .map(|e| eval_expr(ctx, env, e))
                .collect::<EResult<Vec<_>>>()?,
        )),
        Expr::ObjectLit(entries) => {
            let mut m = HashMap::new();
            for (k, e) in entries {
                m.insert(k.clone(), eval_expr(ctx, env, e)?);
            }
            Ok(Value::Object(m))
        }
        Expr::Element(tag, attrs, val_expr, children) => {
            let attrs2 = attrs
                .iter()
                .map(|a| eval_attribute(ctx, env, a))
                .collect::<EResult<Vec<_>>>()?;
            let val = to_json(&eval_expr(ctx, env, val_expr)?)?;
            let children2 = eval_children(ctx, env, children)?;
            Ok(Value::Node(Node::Element(
                tag.clone(),
                attrs2,
                val,
                children2,
                node::no_annotations(),
            )))
        }
        Expr::Fragment(children) => {
            let children2 = eval_children(ctx, env, children)?;
            Ok(Value::Node(Node::Fragment(children2, node::no_annotations())))
        }
        Expr::Branch(cond_expr, then_expr, else_expr) => {
            let cond = require_bool("a branch condition", eval_expr(ctx, env, cond_expr)?)?;
            eval_expr(ctx, env, if cond { then_expr } else { else_expr })
        }
        Expr::Map(coll_expr, fn_expr) => {
            let items = eval_collection(ctx, env, "map", coll_expr)?;
            let fn_val = eval_expr(ctx, env, fn_expr)?;
            let out = items
                .into_iter()
                .map(|item| apply(ctx, "map", fn_val.clone(), vec![item]))
                .collect::<EResult<Vec<_>>>()?;
            Ok(Value::Array(out))
        }
        Expr::Filter(coll_expr, fn_expr) => {
            let items = eval_collection(ctx, env, "filter", coll_expr)?;
            let fn_val = eval_expr(ctx, env, fn_expr)?;
            let mut kept = Vec::new();
            for item in items {
                let r = apply(ctx, "filter", fn_val.clone(), vec![item.clone()])?;
                if require_bool("a filter predicate", r)? {
                    kept.push(item);
                }
            }
            Ok(Value::Array(kept))
        }
        Expr::Scan(coll_expr, init_expr, fn_expr) => {
            let items = eval_collection(ctx, env, "scan", coll_expr)?;
            let acc0 = eval_expr(ctx, env, init_expr)?;
            let fn_val = eval_expr(ctx, env, fn_expr)?;
            let mut out = vec![acc0.clone()];
            let mut acc = acc0;
            for item in items {
                acc = apply(ctx, "scan", fn_val.clone(), vec![acc, item])?;
                out.push(acc.clone());
            }
            Ok(Value::Array(out))
        }
        Expr::Fold(coll_expr, init_expr, fn_expr) => {
            let items = eval_collection(ctx, env, "fold", coll_expr)?;
            let mut acc = eval_expr(ctx, env, init_expr)?;
            let fn_val = eval_expr(ctx, env, fn_expr)?;
            for item in items {
                acc = apply(ctx, "fold", fn_val.clone(), vec![acc, item])?;
            }
            Ok(acc)
        }
        Expr::Concat(l, r) => {
            let lv = eval_expr(ctx, env, l)?;
            let rv = eval_expr(ctx, env, r)?;
            concat_values(lv, rv)
        }
        Expr::Import(name, params) => {
            let mut supplied = HashMap::new();
            for (k, p) in params {
                match p {
                    ParamValue::PExpr(e) => {
                        supplied.insert(k.clone(), eval_expr(ctx, env, e)?);
                    }
                    ParamValue::PFromContext(path) => {
                        let mut context = vec!["ctx".to_string()];
                        context.extend(path.iter().cloned());
                        let ctx_val = env
                            .get("ctx")
                            .cloned()
                            .ok_or_else(|| EvalError::UnboundName("ctx".to_string()))?;
                        supplied.insert(k.clone(), walk_fields(ctx, &context, ctx_val, path)?);
                    }
                    // A `%`-marked entry (`v4-types.md` §2) supplies a type,
                    // not a value, so it never reaches the library's own
                    // `$ctx` — dropped here, the same way the two channels
                    // sharing one params record share no runtime
                    // representation at all, one being erased entirely
                    // before evaluation (§7).
                    ParamValue::PType(_) => {}
                }
            }
            Ok(Value::Import(Pending {
                name: name.clone(),
                params: supplied,
                queued: vec![],
            }))
        }
        Expr::AdaptActions(target_expr, adaptation, fn_expr) => {
            let target = eval_expr(ctx, env, target_expr)?;
            let fn_val = fn_expr
                .as_ref()
                .map(|f| eval_expr(ctx, env, f))
                .transpose()?;
            adapt_value(ctx, adaptation, fn_val.as_ref(), target)
        }
        // `constraint(name, args...)` (v3-symbols §2.1). Each argument must
        // be something that can cross a JSON boundary — the same rule
        // `to_json` already enforces everywhere else — checked here rather
        // than deferred, since a constraint carrying a closure would
        // otherwise sit unnoticed until whatever `!` eventually reaches it.
        Expr::Constrain(name, arg_exprs) => {
            let arg_vals = arg_exprs
                .iter()
                .map(|a| eval_expr(ctx, env, a))
                .collect::<EResult<Vec<_>>>()?;
            for a in &arg_vals {
                to_json(a)?;
            }
            Ok(Value::Constraint(name.clone(), arg_vals))
        }
        // `!expr` (v3-symbols §2.2): evaluates the constraint expression,
        // collects from its value by the coercion table `collect_constraints`
        // encodes, records what it collected, then continues into the body.
        Expr::Emit(constraint_expr, body) => {
            let cv = eval_expr(ctx, env, constraint_expr)?;
            let collected = collect_constraints(cv)?;
            tell_constraints(ctx, collected);
            eval_expr(ctx, env, body)
        }
        Expr::Alloc(_, _) | Expr::Demand(_) => eval_bindable(ctx, env, None, e),
        // `type Name = TypeExpr` (`v4-types.md` §1.1): means nothing to
        // evaluation — resolution is a static pass (§9) — so this simply
        // continues into the body.
        Expr::TypeDecl(_, _, body) => eval_expr(ctx, env, body),
        // `eval_program_with_emissions`/`run_library` both run
        // `types::erase_types` before ever calling `eval_expr`, which
        // rewrites every `TypeAnnotate` into the `Let`/`Emit` pair §7
        // specifies — so this case is not the normal path. Kept total
        // anyway, exactly as `TypeDecl`'s case is total on purpose: matching
        // what erasure would have produced, minus the emission.
        Expr::TypeAnnotate(name, _, value_expr, body) => {
            let v = eval_bindable(ctx, env, Some(name.clone()), value_expr)?;
            let mut env2 = env.clone();
            env2.insert(name.clone(), v);
            eval_expr(ctx, &env2, body)
        }
        // `!type-constraint(...)` (`v4-types.md` §5): resolved by the
        // analyser, never evaluated.
        Expr::TypeEmit(_, _, body) => eval_expr(ctx, env, body),
    }
}

/// `Alloc` and `Demand` are the two forms whose symbol-table entry records
/// the name they were bound to, or `None` when used inline (v3-symbols
/// §5.2's `"binding"` field) — everything else evaluates through plain
/// `eval_expr`, unaffected by whether it happens to sit on a `Let`'s
/// right-hand side.
fn eval_bindable(ctx: &EvalCtx, env: &Env, binding: Option<String>, e: &Expr) -> EResult<Value> {
    match e {
        Expr::Alloc(site, key_expr) => eval_alloc(ctx, env, binding, *site, key_expr),
        Expr::Demand(path) => eval_demand(ctx, env, binding, path),
        other => eval_expr(ctx, env, other),
    }
}

/// `?(key)` (v3-symbols §1.2, §4): the key is evaluated first, in both
/// modes alike, and only *minting* depends on the mode (§5.1).
fn eval_alloc(
    ctx: &EvalCtx,
    env: &Env,
    binding: Option<String>,
    site: usize,
    key_expr: &Expr,
) -> EResult<Value> {
    let key_val = eval_expr(ctx, env, key_expr)?;
    let key_json = require_concrete("?(...)", &key_val)?;
    match ctx.mode {
        Mode::Concrete => Err(EvalError::SymbolsUnavailable(
            "?(...) would have to allocate a symbol, which concrete mode cannot represent".to_string(),
        )),
        Mode::Symbolic => {
            let sid = format!("#{site}:{}", canon(&key_json));
            tell_symbol(
                ctx,
                SymbolEntry {
                    id: sid.clone(),
                    origin: SymbolOrigin::Alloc(site, key_json),
                    binding,
                },
            );
            Ok(Value::Symbol(sid, vec![]))
        }
    }
}

/// `?ctx.a.b` (v3-symbols §1.3): reads exactly as `$ctx.a.b` would when the
/// path is supplied, in either mode. Unsupplied, it allocates at the root
/// (mode permitting) and is an ordinary unsupplied read anywhere else,
/// which `run_library`'s `InLibrary` wrap already tags.
fn eval_demand(ctx: &EvalCtx, env: &Env, binding: Option<String>, path: &[String]) -> EResult<Value> {
    let snapshot = ctx.emissions.borrow().snapshot();
    let attempt = eval_expr(ctx, env, &Expr::Path("ctx".to_string(), path.to_vec()));
    match attempt {
        Ok(v) => Ok(v),
        Err(err) => {
            ctx.emissions.borrow_mut().restore(snapshot);
            match &err {
                EvalError::PathNotFound(_) if ctx.is_root => match ctx.mode {
                    Mode::Concrete => Err(EvalError::SymbolsUnavailable(
                        "?ctx....  unsupplied at the root would have to allocate a symbol, which concrete mode cannot represent".to_string(),
                    )),
                    Mode::Symbolic => {
                        let sid = format!(
                            "#ctx{}",
                            path.iter().map(|p| format!(".{p}")).collect::<String>()
                        );
                        tell_symbol(
                            ctx,
                            SymbolEntry {
                                id: sid.clone(),
                                origin: SymbolOrigin::Demand(path.to_vec()),
                                binding,
                            },
                        );
                        Ok(Value::Symbol(sid, vec![]))
                    }
                },
                _ => Err(err),
            }
        }
    }
}

/// The coercion table a `!` collects by (v3-symbols §2.2): a constraint
/// contributes itself; an array contributes each element, recursively;
/// anything else is a `TypeMismatch`.
fn collect_constraints(v: Value) -> EResult<Vec<Value>> {
    match v {
        Value::Constraint(name, args) => Ok(vec![Value::Constraint(name, args)]),
        Value::Array(xs) => {
            let mut out = Vec::new();
            for x in xs {
                out.extend(collect_constraints(x)?);
            }
            Ok(out)
        }
        other => Err(EvalError::TypeMismatch(format!(
            "! expects a constraint or an array of them, got {}",
            describe_value(&other)
        ))),
    }
}

/// v3-symbols §1.4: compact JSON with keys sorted, agreeing with `str` on
/// arrays and objects and differing at the top level for strings, where
/// `str` renders raw and this quotes — the difference that makes it
/// injective.
fn canon(v: &Json) -> String {
    compact_json(v)
}

fn describe_callee(e: &Expr) -> String {
    match e {
        Expr::Path(root, fields) => {
            let mut parts = vec![root.clone()];
            parts.extend(fields.iter().cloned());
            parts.join(".")
        }
        _ => "a call".to_string(),
    }
}

// Documents ----------------------------------------------------------------

fn eval_attribute(ctx: &EvalCtx, env: &Env, a: &Attribute) -> EResult<NodeAttribute> {
    match a {
        Attribute::Attr(name, e) => {
            let v = to_json(&eval_expr(ctx, env, e)?)?;
            Ok(NodeAttribute::Attribute(name.clone(), v))
        }
        Attribute::ActionAttr(event, key, payload_expr) => {
            let v = to_json(&eval_expr(ctx, env, payload_expr)?)?;
            Ok(NodeAttribute::Action(event.clone(), key.clone(), v))
        }
    }
}

fn eval_children(ctx: &EvalCtx, env: &Env, children: &[Expr]) -> EResult<Vec<Node>> {
    let mut out = Vec::new();
    for e in children {
        let v = eval_expr(ctx, env, e)?;
        out.extend(child_nodes(v)?);
    }
    Ok(out)
}

fn child_nodes(v: Value) -> EResult<Vec<Node>> {
    match v {
        Value::Node(n) => Ok(vec![n]),
        Value::Array(xs) => {
            let mut out = Vec::new();
            for x in xs {
                out.extend(child_nodes(x)?);
            }
            Ok(out)
        }
        other => {
            let j = to_json(&other)?;
            Ok(vec![Node::Text(j, node::no_annotations())])
        }
    }
}

// Application ----------------------------------------------------------------

fn apply(ctx: &EvalCtx, who: &str, f: Value, args: Vec<Value>) -> EResult<Value> {
    match f {
        Value::Closure(params, body, closure_env) => {
            if params.len() != args.len() {
                return Err(EvalError::TypeMismatch(format!(
                    "closure expects {} argument(s), got {}",
                    params.len(),
                    args.len()
                )));
            }
            let mut env2 = closure_env;
            for (p, v) in params.into_iter().zip(args) {
                env2.insert(p, v);
            }
            eval_expr(ctx, &env2, &body)
        }
        Value::Builtin(name) => eval_builtin(&name, args),
        Value::Import(mut pending) => match &args[..] {
            [Value::Object(more)] if args.len() == 1 => {
                for (k, v) in more.clone() {
                    pending.params.insert(k, v);
                }
                Ok(Value::Import(pending))
            }
            [other] => Err(EvalError::TypeMismatch(format!(
                "{who}: the import of {:?} takes an object of parameters, got {}",
                pending.name,
                describe_value(other)
            ))),
            _ => Err(EvalError::TypeMismatch(format!(
                "{who}: the import of {:?} expects exactly 1 argument, the parameters to add",
                pending.name
            ))),
        },
        other => Err(EvalError::TypeMismatch(format!(
            "{who} is not callable: {}",
            describe_value(&other)
        ))),
    }
}

fn eval_collection(ctx: &EvalCtx, env: &Env, who: &str, e: &Expr) -> EResult<Vec<Value>> {
    match eval_expr(ctx, env, e)? {
        Value::Array(xs) => Ok(xs),
        Value::Symbol(_, _) => Err(EvalError::NotConcrete(who.to_string())),
        other => Err(EvalError::TypeMismatch(format!(
            "{who} expects an array as its first argument, got {}",
            describe_value(&other)
        ))),
    }
}

// Concat -----------------------------------------------------------------

/// The monoid operation over the three types that have one. Either side
/// being a symbol is `NotConcrete` (v3-symbols §1.5), ahead of the generic
/// mismatch: the spine of a concatenation must be known, unlike an element
/// it might merely carry.
fn concat_values(l: Value, r: Value) -> EResult<Value> {
    if matches!(l, Value::Symbol(_, _)) || matches!(r, Value::Symbol(_, _)) {
        return Err(EvalError::NotConcrete("<>".to_string()));
    }
    match (l, r) {
        (Value::Str(a), Value::Str(b)) => Ok(Value::Str(a + &b)),
        (Value::Array(a), Value::Array(b)) => {
            let mut out = a;
            out.extend(b);
            Ok(Value::Array(out))
        }
        (Value::Object(a), Value::Object(b)) => {
            let mut out = a;
            for (k, v) in b {
                out.insert(k, v);
            }
            Ok(Value::Object(out))
        }
        (l, r) => Err(EvalError::ConcatMismatch(format!(
            "{} and {}",
            describe_value(&l),
            describe_value(&r)
        ))),
    }
}

// Imports --------------------------------------------------------------------

fn force_import(ctx: &EvalCtx, pending: Pending) -> EResult<Value> {
    let params_val = Value::Object(pending.params.clone());
    let result = run_library(ctx, &pending.name, params_val)?;
    apply_queued(ctx, &pending.queued, result)
}

fn run_library(ctx: &EvalCtx, name: &str, ctx_val: Value) -> EResult<Value> {
    if ctx.in_progress.contains(name) {
        return Err(EvalError::ImportCycle(name.to_string()));
    }
    let raw_prog = ctx
        .libs
        .get(name)
        .ok_or_else(|| EvalError::UnknownLibrary(name.to_string()))?;
    // The static counterpart of `AllocationInLibrary` (v3-symbols §6): a
    // program with a non-empty `symbolSites` cannot serve as a library.
    // Checked lexically, before evaluating anything, and *not* wrapped in
    // `InLibrary` below — this is a property of the library's own source.
    if !symbol_sites(raw_prog).is_empty() {
        return Err(EvalError::AllocationInLibrary(name.to_string()));
    }
    let prog = crate::types::erase_types(ctx.libs, raw_prog).map_err(EvalError::TypeErr)?;
    let ctx2 = enter_library(name, ctx);
    let run = || -> EResult<Value> {
        let (statements, root) = crate::ast::unlets(prog.root());
        let mut lib_env = initial_env(ctx_val.clone());
        let mut binding_names = Vec::new();
        for stmt in &statements {
            match stmt {
                crate::ast::Stmt::Let(n, e) => {
                    let v = eval_expr(&ctx2, &lib_env, e)?;
                    lib_env.insert(n.clone(), v);
                    binding_names.push(n.clone());
                }
                // A library's own emissions are collected when a field is
                // read off its import (v3-symbols §2.3) — which is exactly
                // when `run_library` runs, so replaying the chain here
                // collects them at their position, same as the root does.
                crate::ast::Stmt::Emit(e) => {
                    let cv = eval_expr(&ctx2, &lib_env, e)?;
                    let collected = collect_constraints(cv)?;
                    tell_constraints(&ctx2, collected);
                }
                // A type declaration means nothing to the evaluator
                // (`v4-types.md` §1.1) — it exists for static resolution
                // alone, so replaying it here is a no-op.
                crate::ast::Stmt::TypeDecl(_, _) => {}
                // Erasure has already turned an annotated binding into a
                // `Let` plus `Emit` by the time a library's own chain gets
                // here, so this branch, like `TypeDecl`'s, only guards
                // totality.
                crate::ast::Stmt::Annotate(n, _, e) => {
                    let v = eval_expr(&ctx2, &lib_env, e)?;
                    lib_env.insert(n.clone(), v);
                    binding_names.push(n.clone());
                }
                // `!type-constraint(...)`: never evaluated.
                crate::ast::Stmt::TypeEmit(_, _) => {}
            }
        }
        let rendered = eval_expr(&ctx2, &lib_env, root)?;
        let mut vals = Env::new();
        for n in binding_names.into_iter().filter(|n| !crate::ast::is_hidden_name(n)) {
            vals.insert(n.clone(), lib_env.get(&n).cloned().unwrap());
        }
        let mut out = Env::new();
        out.insert("rendered".to_string(), rendered);
        out.insert("vals".to_string(), Value::ImportResult(vals));
        Ok(Value::ImportResult(out))
    };
    run().map_err(|e| EvalError::InLibrary(name.to_string(), Box::new(e)))
}

// Action adaptation -----------------------------------------------------------

fn adapt_value(
    ctx: &EvalCtx,
    adaptation: &ActionAdaptation,
    fn_val: Option<&Value>,
    v: Value,
) -> EResult<Value> {
    match v {
        Value::Node(n) => {
            let mut f = |event: &str, key: &str, payload: &Json| {
                adapt_action(ctx, adaptation, fn_val, event, key, payload)
            };
            Ok(Value::Node(node::map_actions(&n, &mut f)?))
        }
        Value::ImportResult(e) => {
            let mut out = Env::new();
            for (k, v) in e {
                out.insert(k, adapt_value(ctx, adaptation, fn_val, v)?);
            }
            Ok(Value::ImportResult(out))
        }
        Value::Array(xs) => {
            let out = xs
                .into_iter()
                .map(|x| adapt_value(ctx, adaptation, fn_val, x))
                .collect::<EResult<Vec<_>>>()?;
            Ok(Value::Array(out))
        }
        Value::Object(o) => {
            let mut out = HashMap::new();
            for (k, v) in o {
                out.insert(k, adapt_value(ctx, adaptation, fn_val, v)?);
            }
            Ok(Value::Object(out))
        }
        Value::Import(mut pending) => {
            pending
                .queued
                .push((adaptation.clone(), fn_val.cloned()));
            Ok(Value::Import(pending))
        }
        v => Ok(v),
    }
}

fn apply_queued(
    ctx: &EvalCtx,
    queued: &[(ActionAdaptation, Option<Value>)],
    v0: Value,
) -> EResult<Value> {
    let mut v = v0;
    for (adaptation, fn_val) in queued {
        v = adapt_value(ctx, adaptation, fn_val.as_ref(), v)?;
    }
    Ok(v)
}

fn adapt_action(
    ctx: &EvalCtx,
    adaptation: &ActionAdaptation,
    fn_val: Option<&Value>,
    event: &str,
    key: &str,
    payload: &Json,
) -> EResult<NodeAttribute> {
    let key2 = crate::ast::adapt_key(adaptation, key);
    match fn_val {
        None => Ok(NodeAttribute::Action(event.to_string(), key2, payload.clone())),
        Some(fn_v) => {
            let mut action_obj = HashMap::new();
            action_obj.insert("eventType".to_string(), Value::Str(event.to_string()));
            action_obj.insert("key".to_string(), Value::Str(key2.clone()));
            action_obj.insert("payload".to_string(), from_json(payload));
            let result = apply(ctx, "adapt-actions", fn_v.clone(), vec![Value::Object(action_obj)])?;
            let result_json = to_json(&result)?;
            match result_json {
                Json::Object(obj) => {
                    let event2 = match obj.get("eventType") {
                        Some(Json::String(s)) => s.clone(),
                        _ => {
                            return Err(EvalError::TypeMismatch(
                                "adapt-actions: the function's result needs a string \"eventType\" field"
                                    .to_string(),
                            ))
                        }
                    };
                    let payload2 = obj.get("payload").cloned().unwrap_or(Json::Null);
                    Ok(NodeAttribute::Action(event2, key2, payload2))
                }
                _ => Err(EvalError::TypeMismatch(
                    "adapt-actions: the function must return an object with an eventType field".to_string(),
                )),
            }
        }
    }
}

// Paths and fields -----------------------------------------------------------

fn walk_fields(ctx: &EvalCtx, context: &[String], v: Value, fields: &[String]) -> EResult<Value> {
    if fields.is_empty() {
        return Ok(v);
    }
    let field = &fields[0];
    let rest = &fields[1..];
    match v {
        Value::Object(o) => match o.get(field) {
            None => Err(EvalError::PathNotFound(context.to_vec())),
            Some(v2) => walk_fields(ctx, context, v2.clone(), rest),
        },
        Value::ImportResult(e) => match e.get(field) {
            None => Err(EvalError::PathNotFound(context.to_vec())),
            Some(v2) => walk_fields(ctx, context, v2.clone(), rest),
        },
        Value::Import(pending) => {
            let result = force_import(ctx, pending)?;
            walk_fields(ctx, context, result, fields)
        }
        // Projection (v3-symbols §1.6): reads nothing, and is never
        // rejected — whether the thing a symbol stands for has this field
        // is a question for whoever owns its meaning, not the language.
        // Consumes every remaining segment at once, since a projection just
        // extends the path.
        Value::Symbol(sid, path) => {
            let mut p2 = path;
            p2.extend(fields.iter().cloned());
            Ok(Value::Symbol(sid, p2))
        }
        other => Err(EvalError::TypeMismatch(format!(
            "cannot read field {field:?} of {} in path {:?}",
            describe_value(&other),
            context.join(".")
        ))),
    }
}

// Conversion ------------------------------------------------------------------

/// Down to JSON, at the boundaries where only JSON is meaningful.
fn to_json(v: &Value) -> EResult<Json> {
    match v {
        Value::Null => Ok(Json::Null),
        Value::Bool(b) => Ok(Json::Bool(*b)),
        Value::Number(n) => Ok(number_to_json(*n)),
        Value::Str(s) => Ok(Json::String(s.clone())),
        Value::Array(xs) => Ok(Json::Array(
            xs.iter().map(to_json).collect::<EResult<Vec<_>>>()?,
        )),
        Value::Object(o) => {
            let mut m = JsonMap::new();
            for (k, v) in o {
                m.insert(k.clone(), to_json(v)?);
            }
            Ok(Json::Object(m))
        }
        Value::Node(_) => Err(EvalError::TypeMismatch(
            "a document node is not a plain value -- nest it as a child rather than using it where a value is expected".to_string(),
        )),
        Value::Closure(_, _, _) => Err(EvalError::TypeMismatch(
            "expected a value, got a function -- call it first, e.g. $my-fn(...)".to_string(),
        )),
        Value::Builtin(name) => Err(EvalError::TypeMismatch(format!(
            "expected a value, got the builtin {name:?} -- call it first"
        ))),
        Value::ImportResult(_) => Err(EvalError::TypeMismatch(
            "expected a value, got an import result -- read .rendered, .vals, or a binding name from it first"
                .to_string(),
        )),
        Value::Import(pending) => Err(EvalError::TypeMismatch(format!(
            "expected a value, got the import of {:?} -- read .rendered or .vals from it to run it first",
            pending.name
        ))),
        // A symbol may sit in an attribute, a payload, a value slot or a
        // text child (v3-symbols §1.5), so this always succeeds — it is
        // `require_concrete` that refuses one, for the handful of forms
        // that need to. §5.3's tagged shape: both fields required.
        Value::Symbol(sid, path) => {
            let mut m = JsonMap::new();
            m.insert("$sym".to_string(), Json::String(sid.clone()));
            m.insert(
                "path".to_string(),
                Json::Array(path.iter().map(|s| Json::String(s.clone())).collect()),
            );
            Ok(Json::Object(m))
        }
        Value::Constraint(name, _) => Err(EvalError::TypeMismatch(format!(
            "a constraint ({name:?}) cannot cross a JSON boundary -- only \"!\" may consume it"
        ))),
    }
}

/// Whether a value is, or contains, a symbol — what makes a value
/// concrete's negation (v3-symbols §1.5, §1.7): a structure built of
/// concrete pieces is itself concrete; only a symbol itself, wherever it
/// sits, makes the whole not concrete.
fn contains_symbol(v: &Value) -> bool {
    match v {
        Value::Symbol(_, _) => true,
        Value::Array(xs) => xs.iter().any(contains_symbol),
        Value::Object(o) => o.values().any(contains_symbol),
        _ => false,
    }
}

/// Requires a value with no symbol anywhere in it, for the handful of
/// operations §1.5 lists as needing to *know* something about their
/// argument rather than merely carry it: `str`, `eq`, and an allocation
/// key. Everything else about crossing a JSON boundary is `to_json`'s
/// ordinary business, which this defers to once a symbol is ruled out.
fn require_concrete(who: &str, v: &Value) -> EResult<Json> {
    if contains_symbol(v) {
        Err(EvalError::NotConcrete(who.to_string()))
    } else {
        to_json(v)
    }
}

/// serde_json's `Number` carries its integer-vs-float representation
/// through equality (`Number::from(2u64) != Number::from_f64(2.0)`), and
/// `expected.json`'s literal `2` parses as the integer variant — so a whole
/// double must round-trip to the same variant `serde_json` itself would
/// have parsed, not always the float one.
fn number_to_json(n: f64) -> Json {
    if n.is_finite() && n.fract() == 0.0 && n.abs() < 9e18 {
        if n >= 0.0 {
            Json::Number(JsonNumber::from(n as u64))
        } else {
            Json::Number(JsonNumber::from(n as i64))
        }
    } else {
        JsonNumber::from_f64(n)
            .map(Json::Number)
            .unwrap_or(Json::Null)
    }
}

fn from_json(v: &Json) -> Value {
    match v {
        Json::Null => Value::Null,
        Json::Bool(b) => Value::Bool(*b),
        Json::Number(n) => Value::Number(n.as_f64().unwrap_or(0.0)),
        Json::String(s) => Value::Str(s.clone()),
        Json::Array(a) => Value::Array(a.iter().map(from_json).collect()),
        Json::Object(o) => {
            Value::Object(o.iter().map(|(k, v)| (k.clone(), from_json(v))).collect())
        }
    }
}

/// The input context's boundary: as `from_json`, but recursively refusing
/// `"$sym"` and `"$type"` as ordinary object keys (v3-symbols §5.3). In
/// concrete mode either key is refused unconditionally. In symbolic mode,
/// seeding (§5.4) accepts a well-formed `{"$sym": ..., "path": [...]}` back
/// as an actual symbol — anything else carrying `"$sym"`, or `"$type"` at
/// all, is still refused.
fn checked_from_json(mode: Mode, v: &Json) -> EResult<Value> {
    match v {
        Json::Null => Ok(Value::Null),
        Json::Bool(b) => Ok(Value::Bool(*b)),
        Json::Number(n) => Ok(Value::Number(n.as_f64().unwrap_or(0.0))),
        Json::String(s) => Ok(Value::Str(s.clone())),
        Json::Array(a) => Ok(Value::Array(
            a.iter()
                .map(|x| checked_from_json(mode, x))
                .collect::<EResult<Vec<_>>>()?,
        )),
        Json::Object(o) => {
            if o.contains_key("$type") {
                return Err(EvalError::TypeMismatch(
                    "the context carries the reserved key \"$type\", which only a typed envelope may use"
                        .to_string(),
                ));
            }
            if let Some(sym_val) = o.get("$sym") {
                return match mode {
                    Mode::Concrete => Err(EvalError::TypeMismatch(
                        "the context carries the reserved key \"$sym\", which only a symbolic envelope may use"
                            .to_string(),
                    )),
                    Mode::Symbolic => decode_symbol_ref(sym_val, o),
                };
            }
            let mut m = HashMap::new();
            for (k, v) in o {
                m.insert(k.clone(), checked_from_json(mode, v)?);
            }
            Ok(Value::Object(m))
        }
    }
}

/// Decodes a `{"$sym": <id>, "path": [<segment>, ...]}` object back into a
/// `Value::Symbol` (v3-symbols §5.4). Both fields are required, and no
/// other key may be present.
fn decode_symbol_ref(sym_val: &Json, obj: &JsonMap<String, Json>) -> EResult<Value> {
    let bad_shape = || {
        EvalError::TypeMismatch(
            "a \"$sym\" object must be exactly {\"$sym\": <id>, \"path\": [<segment>, ...]}".to_string(),
        )
    };
    let sid = match sym_val {
        Json::String(s) => s.clone(),
        _ => return Err(bad_shape()),
    };
    if obj.len() != 2 {
        return Err(bad_shape());
    }
    let path_arr = match obj.get("path") {
        Some(Json::Array(a)) => a,
        _ => return Err(bad_shape()),
    };
    let path = path_arr
        .iter()
        .map(|x| match x {
            Json::String(s) => Ok(s.clone()),
            _ => Err(EvalError::TypeMismatch(
                "a symbol reference's \"path\" must be an array of strings".to_string(),
            )),
        })
        .collect::<EResult<Vec<_>>>()?;
    Ok(Value::Symbol(sid, path))
}

fn describe_value(v: &Value) -> String {
    match v {
        Value::Null => "null".to_string(),
        Value::Bool(_) => "a boolean".to_string(),
        Value::Number(_) => "a number".to_string(),
        Value::Str(_) => "a string".to_string(),
        Value::Array(_) => "an array".to_string(),
        Value::Object(_) => "an object".to_string(),
        Value::Node(_) => "a document node".to_string(),
        Value::Closure(_, _, _) => "a function".to_string(),
        Value::Builtin(name) => format!("the builtin {name:?}"),
        Value::ImportResult(_) => "an import result".to_string(),
        Value::Import(pending) => format!("the not-yet-run import of {:?}", pending.name),
        Value::Symbol(_, _) => "a symbol".to_string(),
        Value::Constraint(name, _) => format!("a constraint ({name:?})"),
    }
}

/// Control flow must be concrete (v3-symbols §1.5): a symbolic condition is
/// `NotConcrete`, not merely the wrong type.
fn require_bool(who: &str, v: Value) -> EResult<bool> {
    match v {
        Value::Bool(b) => Ok(b),
        Value::Symbol(_, _) => Err(EvalError::NotConcrete(who.to_string())),
        other => Err(EvalError::TypeMismatch(format!(
            "{who} must be a boolean, got {}",
            describe_value(&other)
        ))),
    }
}

// Builtins ------------------------------------------------------------------

fn eval_builtin(name: &str, args: Vec<Value>) -> EResult<Value> {
    let arity_err = |n: usize| {
        EvalError::TypeMismatch(format!(
            "{name} expects exactly {n} argument(s), got {}",
            args.len()
        ))
    };
    match name {
        "cardinality" | "count" => {
            if args.len() != 1 {
                return Err(arity_err(1));
            }
            match &args[0] {
                Value::Array(xs) => Ok(Value::Number(xs.len() as f64)),
                Value::Object(o) => Ok(Value::Number(o.len() as f64)),
                Value::Symbol(_, _) => Err(EvalError::NotConcrete(name.to_string())),
                other => Err(EvalError::TypeMismatch(format!(
                    "{name} expects an array or object, got {}",
                    describe_value(other)
                ))),
            }
        }
        "str" => {
            if args.len() != 1 {
                return Err(arity_err(1));
            }
            let j = require_concrete(name, &args[0])?;
            Ok(Value::Str(display_string(&j)))
        }
        "not" => {
            if args.len() != 1 {
                return Err(arity_err(1));
            }
            Ok(Value::Bool(!as_bool(name, &args[0])?))
        }
        "and" => {
            let mut acc = true;
            for a in &args {
                acc = acc && as_bool(name, a)?;
            }
            Ok(Value::Bool(acc))
        }
        "or" => {
            let mut acc = false;
            for a in &args {
                acc = acc || as_bool(name, a)?;
            }
            Ok(Value::Bool(acc))
        }
        "eq" => {
            if args.len() != 2 {
                return Err(arity_err(2));
            }
            let a = require_concrete(name, &args[0])?;
            let b = require_concrete(name, &args[1])?;
            Ok(Value::Bool(a == b))
        }
        "lt" | "lte" | "gt" | "gte" => {
            if args.len() != 2 {
                return Err(arity_err(2));
            }
            let a = as_number(name, &args[0])?;
            let b = as_number(name, &args[1])?;
            let r = match name {
                "lt" => a < b,
                "lte" => a <= b,
                "gt" => a > b,
                _ => a >= b,
            };
            Ok(Value::Bool(r))
        }
        "has" => {
            if args.len() != 2 {
                return Err(arity_err(2));
            }
            Ok(Value::Bool(has_impl(name, &args[0], &args[1])?))
        }
        "lookup" => {
            if args.len() != 3 {
                return Err(arity_err(3));
            }
            lookup_impl(name, &args[0], &args[1], args[2].clone())
        }
        "concat" => {
            let mut out = Vec::new();
            for a in &args {
                out.extend(as_array(name, a)?);
            }
            Ok(Value::Array(out))
        }
        "append" => {
            if args.len() != 2 {
                return Err(arity_err(2));
            }
            let mut xs = as_array(name, &args[0])?;
            xs.push(args[1].clone());
            Ok(Value::Array(xs))
        }
        _ => Err(EvalError::UnboundName(name.to_string())),
    }
}

fn as_bool(name: &str, v: &Value) -> EResult<bool> {
    match v {
        Value::Bool(b) => Ok(*b),
        other => Err(EvalError::TypeMismatch(format!(
            "{name} expects a boolean argument, got {}",
            describe_value(other)
        ))),
    }
}

fn as_number(name: &str, v: &Value) -> EResult<f64> {
    match v {
        Value::Number(n) => Ok(*n),
        Value::Symbol(_, _) => Err(EvalError::NotConcrete(name.to_string())),
        other => Err(EvalError::TypeMismatch(format!(
            "{name} expects a number argument, got {}",
            describe_value(other)
        ))),
    }
}

fn as_array(name: &str, v: &Value) -> EResult<Vec<Value>> {
    match v {
        Value::Array(xs) => Ok(xs.clone()),
        other => Err(EvalError::TypeMismatch(format!(
            "{name} expects an array argument, got {}",
            describe_value(other)
        ))),
    }
}

fn as_index(n: f64) -> Option<usize> {
    if n.is_finite() && n >= 0.0 && n.fract() == 0.0 {
        Some(n as usize)
    } else {
        None
    }
}

/// Deliberately tolerant: a missing key, an out-of-range index, or a
/// container of the wrong shape all answer `false` rather than erroring —
/// except a symbolic container, which is `NotConcrete` rather than a lie
/// (v3-symbols §1.5): the tolerant `false` would claim to know something
/// about a container the language cannot see into.
fn has_impl(name: &str, container: &Value, key: &Value) -> EResult<bool> {
    if let Value::Symbol(_, _) = container {
        return Err(EvalError::NotConcrete(name.to_string()));
    }
    Ok(match (container, key) {
        (Value::Object(o), Value::Str(k)) => o.contains_key(k),
        (Value::Array(xs), Value::Number(n)) => as_index(*n).is_some_and(|i| i < xs.len()),
        _ => false,
    })
}

/// A symbolic container is `NotConcrete` rather than falling back to the
/// fallback value, which would silently discard the symbol (v3-symbols
/// §1.5).
fn lookup_impl(name: &str, container: &Value, key: &Value, fallback: Value) -> EResult<Value> {
    if let Value::Symbol(_, _) = container {
        return Err(EvalError::NotConcrete(name.to_string()));
    }
    Ok(match (container, key) {
        (Value::Object(o), Value::Str(k)) => o.get(k).cloned().unwrap_or(fallback),
        (Value::Array(xs), Value::Number(n)) => as_index(*n)
            .and_then(|i| xs.get(i).cloned())
            .unwrap_or(fallback),
        _ => fallback,
    })
}

// str rendering ---------------------------------------------------------------

fn display_string(v: &Json) -> String {
    match v {
        Json::Null => String::new(),
        Json::Bool(b) => if *b { "true" } else { "false" }.to_string(),
        Json::Number(n) => format_number(n.as_f64().unwrap_or(0.0)),
        Json::String(s) => s.clone(),
        v => compact_json(v),
    }
}

fn compact_json(v: &Json) -> String {
    match v {
        Json::Null => "null".to_string(),
        Json::Bool(b) => if *b { "true" } else { "false" }.to_string(),
        Json::Number(n) => format_number(n.as_f64().unwrap_or(0.0)),
        Json::String(s) => quote_string(s),
        Json::Array(xs) => {
            let parts: Vec<String> = xs.iter().map(compact_json).collect();
            format!("[{}]", parts.join(","))
        }
        Json::Object(o) => {
            let mut keys: Vec<&String> = o.keys().collect();
            keys.sort();
            let parts: Vec<String> = keys
                .into_iter()
                .map(|k| format!("{}:{}", quote_string(k), compact_json(&o[k])))
                .collect();
            format!("{{{}}}", parts.join(","))
        }
    }
}

fn quote_string(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

fn format_number(d: f64) -> String {
    if d.is_nan() {
        return "NaN".to_string();
    }
    if d.is_infinite() {
        return if d < 0.0 { "-Infinity" } else { "Infinity" }.to_string();
    }
    if d == 0.0 {
        return "0".to_string();
    }
    if d < 0.0 {
        return format!("-{}", format_positive(-d));
    }
    format_positive(d)
}

/// ECMAScript's `Number::toString` digit-placement rules, given the
/// shortest round-tripping decimal digit sequence and exponent that Rust's
/// own `{:e}` formatting (backed by the Grisu/Ryu-family shortest-repr
/// algorithm `f64::to_string` uses) already computes for us — we only need
/// to place the digits the way ECMA-262 does, not re-derive them.
fn format_positive(d: f64) -> String {
    let (digits, n) = shortest_digits(d);
    let k = digits.len() as i32;
    if n >= k && n <= 21 {
        format!("{}{}", digits, "0".repeat((n - k) as usize))
    } else if n > 0 && n <= 21 {
        let n = n as usize;
        format!("{}.{}", &digits[..n], &digits[n..])
    } else if n > -6 && n <= 0 {
        format!("0.{}{}", "0".repeat((-n) as usize), digits)
    } else {
        let e = n - 1;
        let mantissa = if k == 1 {
            digits
        } else {
            format!("{}.{}", &digits[..1], &digits[1..])
        };
        let sign = if e >= 0 { "+" } else { "-" };
        format!("{mantissa}e{sign}{}", e.abs())
    }
}

/// Returns (digit string with no leading/trailing zeros beyond what the
/// shortest round-tripping representation needs, exponent `n`) such that
/// the value equals `0.<digits> * 10^n` — exactly what Haskell's
/// `floatToDigits 10` returns and what `format_positive` is written
/// against.
fn shortest_digits(d: f64) -> (String, i32) {
    // Rust's `{:e}` gives the shortest round-tripping decimal mantissa and
    // exponent for a positive finite f64: "d.dddde<exp>" meaning
    // value == mantissa * 10^exp, mantissa in [1, 10).
    let s = format!("{d:e}");
    let (mantissa, exp) = s.split_once('e').expect("exponential form has an 'e'");
    let exp: i32 = exp.parse().expect("exponent is an integer");
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let digits = digits.trim_end_matches('0');
    let digits = if digits.is_empty() { "0" } else { digits };
    // mantissa is d.ddd with exactly one digit before the point, so
    // value == 0.<digits> * 10^(exp+1).
    (digits.to_string(), exp + 1)
}
