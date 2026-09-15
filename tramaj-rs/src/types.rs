//! v4-types resolution, normalisation, canonical identity, and the closure
//! and constraint machinery output needs (`specs/v4-types.md`). Mirrors
//! `tramaj-hs/src/Tramaj/Types.hs`: a static pass over parsed programs,
//! evaluating nothing, depending only on `ast` and `analysis`.
//!
//! Scope, precisely: v4-types §9 says resolution and identity are the whole
//! of what a type-aware analysis does before evaluation, and §3 fixes the
//! one property every implementation must agree on — two spellings of the
//! same type must produce the *same string*, and two different types must
//! never collide.
//!
//! **Canonical ids and the library segment.** §3's grammar renders a `Ref`
//! as `library ":" name` with `library` inserted directly. But a library key
//! is an arbitrary static string, and §3 requires injectivity. A `name` is
//! always a colon-free identifier, so reconstructing `library`/`name` from
//! `library <> ":" <> name` is unambiguous however many colons `library`
//! itself contains — but the program being resolved itself (an ordinary
//! `type X = ...` at the root) needs some token for "no library", and no
//! plain word is safe, since a library can legally be named `"root"`.
//! `render_library` wraps every real library key in a literal pair of
//! quotes and reserves the bare, unquoted word `root` for "this program,
//! not a library" — a token no quoted key can ever equal.

use std::collections::{HashMap, HashSet};

use crate::analysis::{transitive_import_names, type_exprs_in, type_params};
use crate::ast::{self, Expr, ParamValue, Program, TypeConstraintArg, TypeExpr};

/// The normal form a `TypeExpr` resolves to (v4-types §3). Structurally the
/// same six shapes as `TypeExpr`, but every reference is now a genuine
/// `(library, name)` pair rather than a name that might not exist, record
/// fields and union arms are sorted by name, and a `Ref` carries its
/// resolved type *arguments* rather than none.
///
/// `None` as a `Ref`'s library means "declared in the program being
/// resolved, not reached through an import".
#[derive(Debug, Clone, PartialEq)]
pub enum ResolvedType {
    Prim(String),
    Array(Box<ResolvedType>),
    Record(Vec<(String, ResolvedType)>),
    Union(Vec<(String, Option<ResolvedType>)>),
    Ref(Option<String>, String, Vec<(String, ResolvedType)>),
    Var(Vec<String>),
}

/// v4-types §10's analysis errors.
#[derive(Debug, Clone, PartialEq)]
pub enum TypeError {
    /// A name resolved to neither a primitive nor a declaration in the
    /// scope it was looked up in.
    UnresolvedType(String),
    /// `$lib.types.X` where `lib` is not bound directly to an `import(...)`
    /// in the enclosing chain, or where that import names a library the
    /// table does not contain.
    NotStaticallyResolvable(String),
    /// The root ships a type whose normal form still contains a variable
    /// (v4-types §4): the resolved id, and the first unresolved path found
    /// in it.
    PartialType(String, Vec<String>),
    /// A params key is read both as `$ctx.k` and as `%ctx.k`.
    TypeParamCollision(String),
    /// A declaration's *arguments* cycle through an import chain that never
    /// bottoms out — a recursive body alone is never this.
    TypeCycle(String),
}

impl std::fmt::Display for TypeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TypeError::UnresolvedType(n) => write!(f, "UnresolvedType {n}"),
            TypeError::NotStaticallyResolvable(n) => write!(f, "NotStaticallyResolvable {n}"),
            TypeError::PartialType(id, path) => write!(f, "PartialType {id} {path:?}"),
            TypeError::TypeParamCollision(k) => write!(f, "TypeParamCollision {k}"),
            TypeError::TypeCycle(k) => write!(f, "TypeCycle {k}"),
        }
    }
}

type TResult<T> = Result<T, TypeError>;

/// Just the type declarations at the top of a program's own statement chain
/// (v4-types §1.1), as a lookup table.
pub fn program_type_decls(prog: &Program) -> HashMap<String, TypeExpr> {
    let (stmts, _) = ast::unlets(prog.root());
    ast::type_decls(&stmts).into_iter().collect()
}

/// Resolves a `TypeExpr` written somewhere in `prog`'s own statement chain
/// against `prog`'s own scope: its own declarations for a bare `Name`, and
/// the libraries in `libs`, reached through `prog`'s own direct
/// `import(...)` bindings, for a `LibRef` (v4-types §9's `$lib.types.X`
/// rule). No library in `libs` is evaluated.
pub fn resolve_type_expr(libs: &HashMap<String, Program>, prog: &Program, t: &TypeExpr) -> TResult<ResolvedType> {
    resolve_with(libs, prog, &HashMap::new(), &HashSet::new(), t)
}

/// As `resolve_type_expr`, but under a substitution (`subst`, keyed by a
/// single-segment `%ctx` variable's name) and a set of library keys
/// (`visiting`) already being expanded on this chain, for `TypeCycle` to
/// check against before expanding another. A supplied entry substitutes
/// structurally — v4-types §6's "supply" — while an unmatched `Var` stays a
/// hole, exactly what "forward" (§6) needs when the substitution itself came
/// from another `%ctx.*` read.
fn resolve_with(
    libs: &HashMap<String, Program>,
    prog: &Program,
    subst: &HashMap<String, ResolvedType>,
    visiting: &HashSet<String>,
    t: &TypeExpr,
) -> TResult<ResolvedType> {
    match t {
        TypeExpr::Prim(name) => Ok(ResolvedType::Prim(name.clone())),
        TypeExpr::Array(inner) => Ok(ResolvedType::Array(Box::new(resolve_with(
            libs, prog, subst, visiting, inner,
        )?))),
        TypeExpr::Record(fields) => {
            let mut out = Vec::new();
            for (n, ft) in fields {
                out.push((n.clone(), resolve_with(libs, prog, subst, visiting, ft)?));
            }
            out.sort_by(|a, b| a.0.cmp(&b.0));
            Ok(ResolvedType::Record(out))
        }
        TypeExpr::Union(arms) => {
            let mut out = Vec::new();
            for (n, mt) in arms {
                let rt = match mt {
                    Some(at) => Some(resolve_with(libs, prog, subst, visiting, at)?),
                    None => None,
                };
                out.push((n.clone(), rt));
            }
            out.sort_by(|a, b| a.0.cmp(&b.0));
            Ok(ResolvedType::Union(out))
        }
        // Only a single-segment path is ever substituted: v4-types has no
        // notion of projecting into a type parameter, so a longer path is
        // left as a `Var` rather than guessing at a meaning the spec does
        // not give it.
        TypeExpr::Var(path) => {
            if path.len() == 1 {
                if let Some(rt) = subst.get(&path[0]) {
                    return Ok(rt.clone());
                }
            }
            Ok(ResolvedType::Var(path.clone()))
        }
        TypeExpr::Name(name) => {
            let own_decls = program_type_decls(prog);
            if own_decls.contains_key(name) {
                Ok(ResolvedType::Ref(None, name.clone(), vec![]))
            } else {
                Err(TypeError::UnresolvedType(name.clone()))
            }
        }
        TypeExpr::LibRef(lib_binding, name) => {
            let (own_stmts, _) = ast::unlets(prog.root());
            let (key, lib_prog, params) = resolve_lib_binding(libs, &own_stmts, lib_binding)?;
            if !program_type_decls(lib_prog).contains_key(name) {
                return Err(TypeError::UnresolvedType(name.clone()));
            }
            if visiting.contains(&key) {
                return Err(TypeError::TypeCycle(key));
            }
            let mut visiting2 = visiting.clone();
            visiting2.insert(key.clone());
            // Every type parameter the target library has, not only the
            // ones this import happens to supply: an unsupplied one still
            // needs a slot in `args`, rendered as its own `Var`.
            let wanted: HashSet<String> = type_params(lib_prog)
                .into_iter()
                .map(|p| p.first().cloned().unwrap_or_default())
                .collect();
            let supplied_types: HashMap<String, TypeExpr> = params
                .iter()
                .filter_map(|(k, v)| match v {
                    ParamValue::PType(te) => Some((k.clone(), te.clone())),
                    _ => None,
                })
                .collect();
            let mut wanted_sorted: Vec<String> = wanted.into_iter().collect();
            wanted_sorted.sort();
            let mut args = Vec::new();
            for k in wanted_sorted {
                let arg = match supplied_types.get(&k) {
                    Some(te) => resolve_with(libs, prog, subst, &visiting2, te)?,
                    None => ResolvedType::Var(vec![k.clone()]),
                };
                args.push((k, arg));
            }
            Ok(ResolvedType::Ref(Some(key), name.clone(), args))
        }
    }
}

/// `lib` must be bound, in `stmts`, directly to an `import("key", ...)` —
/// not to anything that merely evaluates to one — and `key` must be present
/// in `libs`. Takes the *last* such binding if `lib` is somehow bound more
/// than once.
type LibBinding<'a> = (String, &'a Program, Vec<(String, ParamValue)>);

fn resolve_lib_binding<'a>(
    libs: &'a HashMap<String, Program>,
    stmts: &[ast::Stmt],
    lib: &str,
) -> TResult<LibBinding<'a>> {
    let mut found: Option<(String, Vec<(String, ParamValue)>)> = None;
    for s in stmts {
        if let ast::Stmt::Let(n, Expr::Import(key, params)) = s {
            if n == lib {
                found = Some((key.clone(), params.clone()));
            }
        }
    }
    let (key, params) = found.ok_or_else(|| TypeError::NotStaticallyResolvable(lib.to_string()))?;
    match libs.get(&key) {
        None => Err(TypeError::NotStaticallyResolvable(lib.to_string())),
        Some(lib_prog) => Ok((key, lib_prog, params)),
    }
}

/// v4-types §3's grammar, rendered. Assumes its argument is already
/// normalised the way `resolve_type_expr` produces it — fields, arms and
/// arguments sorted by name — since this only renders the order it is
/// given; it does not sort.
pub fn canonical_id(rt: &ResolvedType) -> String {
    match rt {
        ResolvedType::Prim(name) => name.clone(),
        ResolvedType::Array(t) => format!("[{}]", canonical_id(t)),
        ResolvedType::Record(fields) => {
            let parts: Vec<String> = fields.iter().map(|(n, t)| format!("{n}:{}", canonical_id(t))).collect();
            format!("{{{}}}", parts.join(","))
        }
        ResolvedType::Union(arms) => arms
            .iter()
            .map(|(n, mt)| match mt {
                None => format!("|{n}"),
                Some(t) => format!("|{n} {}", canonical_id(t)),
            })
            .collect::<Vec<_>>()
            .join(""),
        ResolvedType::Ref(lib, name, args) => {
            let head = format!("{}:{name}", render_library(lib));
            if args.is_empty() {
                head
            } else {
                let parts: Vec<String> = args.iter().map(|(k, t)| format!("{k}={}", canonical_id(t))).collect();
                format!("{head}[{}]", parts.join(","))
            }
        }
        // `Var`'s path, like `Demand`'s, excludes the leading `ctx` segment
        // it is always rooted at, so it is reinserted here to render
        // v4-types §3's `var ::= "%" path`.
        ResolvedType::Var(path) => {
            let mut s = "%ctx".to_string();
            for p in path {
                s.push('.');
                s.push_str(p);
            }
            s
        }
    }
}

fn render_library(lib: &Option<String>) -> String {
    match lib {
        None => "root".to_string(),
        Some(key) => format!("\"{key}\""),
    }
}

/// Whether a normal form still contains a `Var` anywhere — inside a `Ref`'s
/// own arguments included, since an unfilled argument is exactly as partial
/// as a bare hole (v4-types §4).
fn contains_var(rt: &ResolvedType) -> bool {
    match rt {
        ResolvedType::Var(_) => true,
        ResolvedType::Array(t) => contains_var(t),
        ResolvedType::Record(fields) => fields.iter().any(|(_, t)| contains_var(t)),
        ResolvedType::Union(arms) => arms.iter().any(|(_, mt)| mt.as_ref().is_some_and(contains_var)),
        ResolvedType::Ref(_, _, args) => args.iter().any(|(_, t)| contains_var(t)),
        ResolvedType::Prim(_) => false,
    }
}

/// The path of the first `Var` found, left-to-right — what `PartialType`
/// reports alongside the id.
fn first_var_path(rt: &ResolvedType) -> Vec<String> {
    match rt {
        ResolvedType::Var(path) => path.clone(),
        ResolvedType::Array(t) => first_var_path(t),
        ResolvedType::Record(fields) => fields
            .iter()
            .find(|(_, t)| contains_var(t))
            .map(|(_, t)| first_var_path(t))
            .expect("unreachable: first_var_path called on a type with no variable"),
        ResolvedType::Union(arms) => arms
            .iter()
            .filter_map(|(_, mt)| mt.as_ref())
            .find(|t| contains_var(t))
            .map(first_var_path)
            .expect("unreachable: first_var_path called on a type with no variable"),
        ResolvedType::Ref(_, _, args) => args
            .iter()
            .find(|(_, t)| contains_var(t))
            .map(|(_, t)| first_var_path(t))
            .expect("unreachable: first_var_path called on a type with no variable"),
        ResolvedType::Prim(_) => unreachable!("first_var_path called on a type with no variable"),
    }
}

/// v4-types §4: a type reaching the root — an annotation, the closure of a
/// program's own output — must be closed. Everything else may stay partial;
/// only a caller at the root need ever call this.
pub fn require_closed(rt: ResolvedType) -> TResult<ResolvedType> {
    if contains_var(&rt) {
        Err(TypeError::PartialType(canonical_id(&rt), first_var_path(&rt)))
    } else {
        Ok(rt)
    }
}

/// v4-types §10's `TypeParamCollision`, surfaced as a proper `TypeError`
/// from `analysis::type_param_collisions`' plain set.
pub fn check_type_param_collisions(prog: &Program) -> TResult<()> {
    let mut xs: Vec<String> = crate::analysis::type_param_collisions(prog).into_iter().collect();
    xs.sort();
    match xs.into_iter().next() {
        Some(k) => Err(TypeError::TypeParamCollision(k)),
        None => Ok(()),
    }
}

// Output: the transitive closure of referenced types (v4-types §8) --------

/// Every `Ref` reachable from a resolved type, including inside another
/// `Ref`'s own arguments — what a caller must expand to build the
/// `"types"` table's next layer.
fn collect_refs(rt: &ResolvedType) -> Vec<ResolvedType> {
    match rt {
        r @ ResolvedType::Ref(_, _, args) => {
            let mut out = vec![r.clone()];
            for (_, a) in args {
                out.extend(collect_refs(a));
            }
            out
        }
        ResolvedType::Array(t) => collect_refs(t),
        ResolvedType::Record(fields) => fields.iter().flat_map(|(_, t)| collect_refs(t)).collect(),
        ResolvedType::Union(arms) => arms
            .iter()
            .flat_map(|(_, mt)| mt.iter().flat_map(collect_refs))
            .collect(),
        ResolvedType::Prim(_) | ResolvedType::Var(_) => vec![],
    }
}

/// The program and raw declaration body a `Ref` names — `None` means `prog`
/// itself (v4-types §1.1); `Some(key)` means whatever program `key` names in
/// `libs`.
fn lookup_decl<'a>(
    libs: &'a HashMap<String, Program>,
    prog: &'a Program,
    lib_key: &Option<String>,
    name: &str,
) -> TResult<(&'a Program, TypeExpr)> {
    match lib_key {
        None => program_type_decls(prog)
            .get(name)
            .cloned()
            .map(|t| (prog, t))
            .ok_or_else(|| TypeError::UnresolvedType(name.to_string())),
        Some(key) => {
            let lib_prog = libs
                .get(key)
                .ok_or_else(|| TypeError::NotStaticallyResolvable(key.clone()))?;
            program_type_decls(lib_prog)
                .get(name)
                .cloned()
                .map(|t| (lib_prog, t))
                .ok_or_else(|| TypeError::UnresolvedType(name.to_string()))
        }
    }
}

/// The transitive closure of every type referenced from `roots` (v4-types
/// §8): a record's field types, a union's payloads, and theirs, cut by id so
/// a cycle terminates. Keyed by canonical id rather than by
/// `(library, name)`: two applications of the same generic library at
/// different arguments are two different entries.
pub fn type_closure(
    libs: &HashMap<String, Program>,
    prog: &Program,
    roots: &[ResolvedType],
) -> TResult<HashMap<String, ResolvedType>> {
    let mut acc: HashMap<String, ResolvedType> = HashMap::new();
    let mut queue: Vec<ResolvedType> = roots.iter().flat_map(collect_refs).collect();
    while let Some(r) = queue.pop() {
        if let ResolvedType::Ref(lib_key, name, args) = &r {
            let cid = canonical_id(&r);
            if acc.contains_key(&cid) {
                continue;
            }
            let (decl_prog, decl_body) = lookup_decl(libs, prog, lib_key, name)?;
            let subst: HashMap<String, ResolvedType> = args.iter().cloned().collect();
            let def = resolve_with(libs, decl_prog, &subst, &HashSet::new(), &decl_body)?;
            queue.extend(collect_refs(&def));
            acc.insert(cid, def);
        }
    }
    Ok(acc)
}

// Erasure (v4-types §7) ----------------------------------------------------

/// Rewrites every `TypeAnnotate` in `prog` into the `Let` plus `Emit` §7
/// specifies, resolving and closing its type first (an annotation whose type
/// is partial is `PartialType`, per §7's own note that this is what makes
/// erasure safe). Everything else is rebuilt unchanged; a `TypeDecl` and a
/// resolved `TypeEmit` are left in place rather than stripped, since both
/// are already inert to `eval::eval_expr` — only `TypeAnnotate` produces
/// something the evaluator cannot already ignore on its own.
///
/// Run once, up front, by every one of `eval.rs`'s entry points (including a
/// library, the moment it loads) rather than baked into evaluation itself —
/// this is what keeps `Value` free of a type constructor: by the time
/// `eval::eval_expr` runs, there is no `TypeAnnotate` left for it to match in
/// the normal path.
pub fn erase_types(libs: &HashMap<String, Program>, prog: &Program) -> TResult<Program> {
    let root2 = erase_expr(libs, prog, prog.root())?;
    Ok(match prog {
        Program::DocumentProgram(_) => Program::DocumentProgram(root2),
        Program::ExpressionProgram(_) => Program::ExpressionProgram(root2),
    })
}

fn erase_expr(libs: &HashMap<String, Program>, prog: &Program, e: &Expr) -> TResult<Expr> {
    let boxed = |x: TResult<Expr>| x.map(Box::new);
    match e {
        Expr::Path(a, b) => Ok(Expr::Path(a.clone(), b.clone())),
        Expr::FieldAccess(t, f) => Ok(Expr::FieldAccess(boxed(erase_expr(libs, prog, t))?, f.clone())),
        Expr::Call(f, args) => Ok(Expr::Call(
            boxed(erase_expr(libs, prog, f))?,
            args.iter().map(|a| erase_expr(libs, prog, a)).collect::<TResult<_>>()?,
        )),
        Expr::Lambda(p, body) => Ok(Expr::Lambda(p.clone(), boxed(erase_expr(libs, prog, body))?)),
        Expr::Let(n, v, body) => Ok(Expr::Let(
            n.clone(),
            boxed(erase_expr(libs, prog, v))?,
            boxed(erase_expr(libs, prog, body))?,
        )),
        Expr::StringLit(_) | Expr::NumberLit(_) | Expr::BoolLit(_) | Expr::NullLit => Ok(e.clone()),
        Expr::ArrayLit(es) => Ok(Expr::ArrayLit(
            es.iter().map(|x| erase_expr(libs, prog, x)).collect::<TResult<_>>()?,
        )),
        Expr::ObjectLit(entries) => Ok(Expr::ObjectLit(
            entries
                .iter()
                .map(|(k, v)| Ok((k.clone(), erase_expr(libs, prog, v)?)))
                .collect::<TResult<_>>()?,
        )),
        Expr::Element(tag, attrs, val, children) => Ok(Expr::Element(
            tag.clone(),
            attrs
                .iter()
                .map(|a| erase_attr(libs, prog, a))
                .collect::<TResult<_>>()?,
            boxed(erase_expr(libs, prog, val))?,
            children
                .iter()
                .map(|c| erase_expr(libs, prog, c))
                .collect::<TResult<_>>()?,
        )),
        Expr::Fragment(cs) => Ok(Expr::Fragment(
            cs.iter().map(|c| erase_expr(libs, prog, c)).collect::<TResult<_>>()?,
        )),
        Expr::Branch(c, t, el) => Ok(Expr::Branch(
            boxed(erase_expr(libs, prog, c))?,
            boxed(erase_expr(libs, prog, t))?,
            boxed(erase_expr(libs, prog, el))?,
        )),
        Expr::Map(c, f) => Ok(Expr::Map(boxed(erase_expr(libs, prog, c))?, boxed(erase_expr(libs, prog, f))?)),
        Expr::Filter(c, f) => Ok(Expr::Filter(boxed(erase_expr(libs, prog, c))?, boxed(erase_expr(libs, prog, f))?)),
        Expr::Scan(c, i, f) => Ok(Expr::Scan(
            boxed(erase_expr(libs, prog, c))?,
            boxed(erase_expr(libs, prog, i))?,
            boxed(erase_expr(libs, prog, f))?,
        )),
        Expr::Fold(c, i, f) => Ok(Expr::Fold(
            boxed(erase_expr(libs, prog, c))?,
            boxed(erase_expr(libs, prog, i))?,
            boxed(erase_expr(libs, prog, f))?,
        )),
        Expr::Concat(l, r) => Ok(Expr::Concat(boxed(erase_expr(libs, prog, l))?, boxed(erase_expr(libs, prog, r))?)),
        Expr::Import(name, params) => Ok(Expr::Import(
            name.clone(),
            params
                .iter()
                .map(|(k, p)| {
                    Ok((
                        k.clone(),
                        match p {
                            ParamValue::PExpr(e) => ParamValue::PExpr(erase_expr(libs, prog, e)?),
                            ParamValue::PFromContext(path) => ParamValue::PFromContext(path.clone()),
                            ParamValue::PType(t) => ParamValue::PType(t.clone()),
                        },
                    ))
                })
                .collect::<TResult<_>>()?,
        )),
        Expr::AdaptActions(t, a, f) => Ok(Expr::AdaptActions(
            boxed(erase_expr(libs, prog, t))?,
            a.clone(),
            match f {
                Some(fe) => Some(boxed(erase_expr(libs, prog, fe))?),
                None => None,
            },
        )),
        Expr::Constrain(n, args) => Ok(Expr::Constrain(
            n.clone(),
            args.iter().map(|a| erase_expr(libs, prog, a)).collect::<TResult<_>>()?,
        )),
        Expr::Emit(c, body) => Ok(Expr::Emit(boxed(erase_expr(libs, prog, c))?, boxed(erase_expr(libs, prog, body))?)),
        Expr::Alloc(site, k) => Ok(Expr::Alloc(*site, boxed(erase_expr(libs, prog, k))?)),
        Expr::Demand(p) => Ok(Expr::Demand(p.clone())),
        Expr::TypeDecl(n, t, body) => Ok(Expr::TypeDecl(n.clone(), t.clone(), boxed(erase_expr(libs, prog, body))?)),
        Expr::TypeAnnotate(name, t, value, body) => {
            let rt = require_closed(resolve_type_expr(libs, prog, t)?)?;
            let value2 = erase_expr(libs, prog, value)?;
            let body2 = erase_expr(libs, prog, body)?;
            let has_type = Expr::Constrain(
                "has-type".to_string(),
                vec![
                    Expr::Path(name.clone(), vec![]),
                    Expr::ObjectLit(vec![("$type".to_string(), Expr::StringLit(canonical_id(&rt)))]),
                ],
            );
            Ok(Expr::Let(
                name.clone(),
                Box::new(value2),
                Box::new(Expr::Emit(Box::new(has_type), Box::new(body2))),
            ))
        }
        Expr::TypeEmit(_, _, body) => erase_expr(libs, prog, body),
    }
}

fn erase_attr(libs: &HashMap<String, Program>, prog: &Program, a: &crate::ast::Attribute) -> TResult<crate::ast::Attribute> {
    use crate::ast::Attribute;
    match a {
        Attribute::Attr(n, e) => Ok(Attribute::Attr(n.clone(), erase_expr(libs, prog, e)?)),
        Attribute::ActionAttr(ev, k, e) => Ok(Attribute::ActionAttr(ev.clone(), k.clone(), erase_expr(libs, prog, e)?)),
    }
}

// Type constraints (v4-types §5) -------------------------------------------

/// A resolved `!type-constraint` argument: a type, or one of the four
/// scalar shapes §5 allows — the type-realm counterpart of the
/// already-evaluated `Value` a v3 constraint's argument becomes.
#[derive(Debug, Clone, PartialEq)]
pub enum ResolvedConstraintArg {
    Type(ResolvedType),
    ScalarStr(String),
    ScalarNum(f64),
    ScalarBool(bool),
    ScalarNull,
}

fn resolve_constraint_arg(
    libs: &HashMap<String, Program>,
    prog: &Program,
    a: &TypeConstraintArg,
) -> TResult<ResolvedConstraintArg> {
    match a {
        TypeConstraintArg::Type(t) => Ok(ResolvedConstraintArg::Type(resolve_type_expr(libs, prog, t)?)),
        TypeConstraintArg::ScalarStr(s) => Ok(ResolvedConstraintArg::ScalarStr(s.clone())),
        TypeConstraintArg::ScalarNum(n) => Ok(ResolvedConstraintArg::ScalarNum(*n)),
        TypeConstraintArg::ScalarBool(b) => Ok(ResolvedConstraintArg::ScalarBool(*b)),
        TypeConstraintArg::ScalarNull => Ok(ResolvedConstraintArg::ScalarNull),
    }
}

fn collect_type_emits(e: &Expr) -> Vec<(String, Vec<TypeConstraintArg>)> {
    let mut out = match e {
        Expr::TypeEmit(name, args, _) => vec![(name.clone(), args.clone())],
        _ => vec![],
    };
    for sub in ast::sub_exprs(e) {
        out.extend(collect_type_emits(sub));
    }
    out
}

fn dedupe_first<T: PartialEq>(xs: Vec<T>) -> Vec<T> {
    let mut out: Vec<T> = Vec::new();
    for x in xs {
        if !out.contains(&x) {
            out.push(x);
        }
    }
    out
}

/// Every `!type-constraint` this program's own statement chain collects
/// (v4-types §5), each argument resolved, deduplicated by name and
/// already-resolved arguments.
pub fn type_constraints(
    libs: &HashMap<String, Program>,
    prog: &Program,
) -> TResult<Vec<(String, Vec<ResolvedConstraintArg>)>> {
    let raw = collect_type_emits(prog.root());
    let mut resolved = Vec::new();
    for (name, args) in raw {
        let mut rargs = Vec::new();
        for a in &args {
            rargs.push(resolve_constraint_arg(libs, prog, a)?);
        }
        resolved.push((name, rargs));
    }
    Ok(dedupe_first(resolved))
}

/// `type_constraints`, over-approximated by following every transitively
/// imported library.
pub fn deep_type_constraints(
    libs: &HashMap<String, Program>,
    prog: &Program,
) -> TResult<Vec<(String, Vec<ResolvedConstraintArg>)>> {
    let mut own = type_constraints(libs, prog)?;
    for name in transitive_import_names(libs, prog) {
        if let Some(p) = libs.get(&name) {
            own.extend(type_constraints(libs, p)?);
        }
    }
    Ok(dedupe_first(own))
}

// Type references (v4-types §9) --------------------------------------------

/// Every `TypeExpr` sitting in a type-bearing position of `prog`'s own
/// syntax — a declaration's body, an annotation's type, a type constraint's
/// type-marked arguments, an import's `%`-marked param — resolved.
pub fn program_type_roots(libs: &HashMap<String, Program>, prog: &Program) -> TResult<Vec<ResolvedType>> {
    fn everywhere(e: &Expr) -> Vec<TypeExpr> {
        let mut out = type_exprs_in(e);
        for sub in ast::sub_exprs(e) {
            out.extend(everywhere(sub));
        }
        out
    }
    everywhere(prog.root())
        .iter()
        .map(|t| resolve_type_expr(libs, prog, t))
        .collect()
}

/// Every type this program's own statement chain refers to, normalised to
/// its canonical id.
pub fn type_references(libs: &HashMap<String, Program>, prog: &Program) -> TResult<HashSet<String>> {
    Ok(program_type_roots(libs, prog)?.iter().map(canonical_id).collect())
}

/// `type_references`, following every transitively imported library.
pub fn deep_type_references(libs: &HashMap<String, Program>, prog: &Program) -> TResult<HashSet<String>> {
    let mut out = type_references(libs, prog)?;
    for name in transitive_import_names(libs, prog) {
        if let Some(p) = libs.get(&name) {
            out.extend(type_references(libs, p)?);
        }
    }
    Ok(out)
}
