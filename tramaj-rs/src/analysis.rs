//! Static analysis over the AST alone (`specs/reference.md` §9,
//! `specs/v3-symbols.md` §7). Mirrors `tramaj-hs/src/Tramaj/Analysis.hs`,
//! covering R1 plus R2's symbol/constraint analyses: no v4 type analyses
//! (`typeDeclarations`/`typeParams`/`unsuppliedTypeParams`/
//! `typeParamCollisions`).
//!
//! Not exercised by the corpus harness directly (it drives `eval::run_program`
//! only, which calls `symbol_sites` itself for `AllocationInLibrary`), but
//! kept correct because `tramaj-cli-rs` (a later phase) and R3 build on it.

use std::collections::{HashMap, HashSet};

use crate::ast::{Attribute, Expr, ParamValue, Program};

/// Collects from an expression and every expression inside it.
fn everywhere<T: Eq + std::hash::Hash>(f: &impl Fn(&Expr) -> HashSet<T>, e: &Expr) -> HashSet<T> {
    let mut out = f(e);
    for sub in crate::ast::sub_exprs(e) {
        out.extend(everywhere(f, sub));
    }
    out
}

fn everywhere_in<T: Eq + std::hash::Hash>(
    f: &impl Fn(&Expr) -> HashSet<T>,
    prog: &Program,
) -> HashSet<T> {
    everywhere(f, prog.root())
}

// Imports ---------------------------------------------------------------------

/// Every library this program imports directly.
pub fn static_import_names(prog: &Program) -> HashSet<String> {
    everywhere_in(
        &|e| match e {
            Expr::Import(name, _) => HashSet::from([name.clone()]),
            _ => HashSet::new(),
        },
        prog,
    )
}

/// Every library reachable from this program, directly or through another
/// import. A missing name is still reported; a cycle terminates.
pub fn transitive_import_names(
    libs: &HashMap<String, Program>,
    prog: &Program,
) -> HashSet<String> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut frontier: Vec<String> = static_import_names(prog).into_iter().collect();
    while let Some(name) = frontier.pop() {
        if seen.contains(&name) {
            continue;
        }
        seen.insert(name.clone());
        if let Some(p) = libs.get(&name) {
            for next in static_import_names(p) {
                if !seen.contains(&next) {
                    frontier.push(next);
                }
            }
        }
    }
    seen
}

// Actions -----------------------------------------------------------------------

/// Every action key this program can emit from its own AST. Adaptation is
/// applied, not ignored.
pub fn static_action_keys(prog: &Program) -> HashSet<String> {
    action_keys_in(prog.root())
}

fn action_keys_in(e: &Expr) -> HashSet<String> {
    match e {
        Expr::AdaptActions(target, adaptation, fn_) => {
            let mut out: HashSet<String> = action_keys_in(target)
                .into_iter()
                .map(|k| crate::ast::adapt_key(adaptation, &k))
                .collect();
            if let Some(f) = fn_ {
                out.extend(action_keys_in(f));
            }
            out
        }
        _ => {
            let mut out = own_keys(e);
            for sub in crate::ast::sub_exprs(e) {
                out.extend(action_keys_in(sub));
            }
            out
        }
    }
}

fn own_keys(e: &Expr) -> HashSet<String> {
    match e {
        Expr::Element(_, attrs, _, _) => attrs
            .iter()
            .filter_map(|a| match a {
                Attribute::ActionAttr(_, k, _) => Some(k.clone()),
                Attribute::Attr(_, _) => None,
            })
            .collect(),
        _ => HashSet::new(),
    }
}

/// Every action key this program can emit, following imports. An
/// over-approximation, like the reference implementations: keys under a
/// `Branch` arm that will never be selected are still reported.
pub fn deep_action_keys(libs: &HashMap<String, Program>, prog: &Program) -> HashSet<String> {
    fn go(libs: &HashMap<String, Program>, seen: &mut HashSet<String>, e: &Expr) -> HashSet<String> {
        match e {
            Expr::AdaptActions(target, adaptation, fn_) => {
                let mut out: HashSet<String> = go(libs, seen, target)
                    .into_iter()
                    .map(|k| crate::ast::adapt_key(adaptation, &k))
                    .collect();
                if let Some(f) = fn_ {
                    out.extend(go(libs, seen, f));
                }
                out
            }
            Expr::Import(name, params) => {
                let mut out: HashSet<String> = params
                    .iter()
                    .filter_map(|(_, p)| match p {
                        ParamValue::PExpr(e) => Some(e),
                        ParamValue::PFromContext(_) => None,
                        ParamValue::PType(_) => None,
                    })
                    .flat_map(|e| go(libs, seen, e))
                    .collect();
                if !seen.contains(name) {
                    seen.insert(name.clone());
                    if let Some(p) = libs.get(name) {
                        out.extend(go(libs, seen, p.root()));
                    }
                }
                out
            }
            _ => {
                let mut out = own_keys(e);
                for sub in crate::ast::sub_exprs(e) {
                    out.extend(go(libs, seen, sub));
                }
                out
            }
        }
    }
    go(libs, &mut HashSet::new(), prog.root())
}

// Context holes ---------------------------------------------------------------------

/// Every path this program declares as a hole with `ctx(path)`.
pub fn context_holes(prog: &Program) -> HashSet<Vec<String>> {
    everywhere_in(
        &|e| match e {
            Expr::Import(_, params) => params
                .iter()
                .filter_map(|(_, p)| match p {
                    ParamValue::PFromContext(path) => Some(path.clone()),
                    ParamValue::PExpr(_) => None,
                    ParamValue::PType(_) => None,
                })
                .collect(),
            _ => HashSet::new(),
        },
        prog,
    )
}

/// Context holes of this program and of every library it imports.
pub fn deep_context_holes(
    libs: &HashMap<String, Program>,
    prog: &Program,
) -> HashSet<Vec<String>> {
    let mut out = context_holes(prog);
    for name in transitive_import_names(libs, prog) {
        if let Some(p) = libs.get(&name) {
            out.extend(context_holes(p));
        }
    }
    out
}

/// Every path this program reads out of its own context, however written.
pub fn context_reads(prog: &Program) -> HashSet<Vec<String>> {
    everywhere_in(
        &|e| match e {
            Expr::Path(root, fields) if root == "ctx" => HashSet::from([fields.clone()]),
            Expr::Import(_, params) => params
                .iter()
                .filter_map(|(_, p)| match p {
                    ParamValue::PFromContext(path) => Some(path.clone()),
                    ParamValue::PExpr(_) => None,
                    ParamValue::PType(_) => None,
                })
                .collect(),
            _ => HashSet::new(),
        },
        prog,
    )
}

/// For each import in this program, the paths its library reads from its
/// context that the import does not supply.
pub fn unsupplied_params(
    libs: &HashMap<String, Program>,
    prog: &Program,
) -> Vec<(String, HashSet<Vec<String>>)> {
    fn collect(
        libs: &HashMap<String, Program>,
        e: &Expr,
        out: &mut Vec<(String, HashSet<Vec<String>>)>,
    ) {
        if let Expr::Import(name, params) = e {
            let supplied: HashSet<&str> = params.iter().map(|(k, _)| k.as_str()).collect();
            let reads = libs
                .get(name)
                .map(context_reads)
                .unwrap_or_default();
            let missing: HashSet<Vec<String>> = reads
                .into_iter()
                .filter(|path| match path.first() {
                    None => false,
                    Some(root) => !supplied.contains(root.as_str()),
                })
                .collect();
            out.push((name.clone(), missing));
        }
        for sub in crate::ast::sub_exprs(e) {
            collect(libs, sub, out);
        }
    }
    let mut out = Vec::new();
    collect(libs, prog.root(), &mut out);
    out
}

// Constraints -------------------------------------------------------------------

/// Every constraint name this program can emit from its own AST
/// (`v3-symbols.md` §7). Answerable statically because a `constraint(...)`'s
/// name is a static string, like an action's event and key.
pub fn constraint_kinds(prog: &Program) -> HashSet<String> {
    everywhere_in(
        &|e| match e {
            Expr::Constrain(name, _) => HashSet::from([name.clone()]),
            _ => HashSet::new(),
        },
        prog,
    )
}

/// Every constraint name this program can emit, following imports — the
/// question a host actually wants answered before it decides whether it
/// supports a template. Over-approximates like `deep_action_keys`: a kind
/// emitted only under a `Branch` arm no context will select is still
/// reported, and a missing library contributes nothing rather than failing.
pub fn deep_constraint_kinds(libs: &HashMap<String, Program>, prog: &Program) -> HashSet<String> {
    fn go(libs: &HashMap<String, Program>, seen: &mut HashSet<String>, e: &Expr) -> HashSet<String> {
        match e {
            Expr::Import(name, params) => {
                let mut out: HashSet<String> = params
                    .iter()
                    .filter_map(|(_, p)| match p {
                        ParamValue::PExpr(e) => Some(e),
                        ParamValue::PFromContext(_) => None,
                        ParamValue::PType(_) => None,
                    })
                    .flat_map(|e| go(libs, seen, e))
                    .collect();
                if !seen.contains(name) {
                    seen.insert(name.clone());
                    if let Some(p) = libs.get(name) {
                        out.extend(go(libs, seen, p.root()));
                    }
                }
                out
            }
            _ => {
                let mut out = match e {
                    Expr::Constrain(name, _) => HashSet::from([name.clone()]),
                    _ => HashSet::new(),
                };
                for sub in crate::ast::sub_exprs(e) {
                    out.extend(go(libs, seen, sub));
                }
                out
            }
        }
    }
    go(libs, &mut HashSet::new(), prog.root())
}

// Symbols -------------------------------------------------------------------

/// The `?(k)` allocation sites this program contains (`v3-symbols.md` §7) —
/// sites, not keys, since the number of symbols a site produces is a
/// runtime fact but the number of sites is not.
///
/// Also the static counterpart of `AllocationInLibrary` (§6): a program
/// with a non-empty `symbol_sites` cannot serve as a library, which is
/// exactly the check `eval::run_library` makes before evaluating one.
pub fn symbol_sites(prog: &Program) -> HashSet<usize> {
    everywhere_in(
        &|e| match e {
            Expr::Alloc(site, _) => HashSet::from([*site]),
            _ => HashSet::new(),
        },
        prog,
    )
}

/// Every context path this program declares symbolic with `?ctx.…` (§7),
/// directly — the demand form's counterpart of `context_holes`.
pub fn symbol_demands(prog: &Program) -> HashSet<Vec<String>> {
    everywhere_in(
        &|e| match e {
            Expr::Demand(path) => HashSet::from([path.clone()]),
            _ => HashSet::new(),
        },
        prog,
    )
}

/// Demands bubbled up through every library this program imports, the way
/// `deep_context_holes` bubbles up `ctx(...)` holes — the counterpart of
/// `unsupplied_params` for this feature (§7).
pub fn deep_symbol_demands(libs: &HashMap<String, Program>, prog: &Program) -> HashSet<Vec<String>> {
    let mut out = symbol_demands(prog);
    for name in transitive_import_names(libs, prog) {
        if let Some(p) = libs.get(&name) {
            out.extend(symbol_demands(p));
        }
    }
    out
}

// Types -----------------------------------------------------------------------

/// Every name this program declares with `type ... = ...` (`v4-types.md`
/// §9) — the type-realm counterpart of a program's own let-bound names, and
/// the source `types::resolve_type_expr` consults for a bare `TypeExpr::Name`.
pub fn type_declarations(prog: &Program) -> HashSet<String> {
    let (stmts, _) = crate::ast::unlets(prog.root());
    crate::ast::type_decls(&stmts).into_iter().map(|(n, _)| n).collect()
}

/// The `%ctx.*` paths one `TypeExpr` mentions directly — `Var` is a leaf,
/// the way `resolve_type_expr` must: a reference's own parameters are not
/// its referent's.
fn type_params_in(t: &crate::ast::TypeExpr) -> HashSet<Vec<String>> {
    use crate::ast::TypeExpr;
    match t {
        TypeExpr::Prim(_) => HashSet::new(),
        TypeExpr::Array(inner) => type_params_in(inner),
        TypeExpr::Record(fields) => fields.iter().flat_map(|(_, t)| type_params_in(t)).collect(),
        TypeExpr::Union(arms) => arms
            .iter()
            .flat_map(|(_, mt)| mt.iter().flat_map(type_params_in))
            .collect(),
        TypeExpr::Name(_) => HashSet::new(),
        TypeExpr::LibRef(_, _) => HashSet::new(),
        TypeExpr::Var(path) => HashSet::from([path.clone()]),
    }
}

/// Every `TypeExpr` sitting in one expression's own syntax, not recursing
/// into subexpressions — a declaration's body, an annotation's type, a type
/// constraint's type-marked arguments, and an import parameter's
/// `%`-marked value are the four positions a `TypeExpr` can occur in at
/// all.
pub fn type_exprs_in(e: &Expr) -> Vec<crate::ast::TypeExpr> {
    use crate::ast::TypeConstraintArg;
    match e {
        Expr::TypeDecl(_, t, _) => vec![t.clone()],
        Expr::TypeAnnotate(_, t, _, _) => vec![t.clone()],
        Expr::TypeEmit(_, args, _) => args
            .iter()
            .filter_map(|a| match a {
                TypeConstraintArg::Type(t) => Some(t.clone()),
                _ => None,
            })
            .collect(),
        Expr::Import(_, params) => params
            .iter()
            .filter_map(|(_, p)| match p {
                ParamValue::PType(t) => Some(t.clone()),
                _ => None,
            })
            .collect(),
        _ => vec![],
    }
}

/// Every `%ctx.*` path this program mentions in a type-bearing position
/// (`v4-types.md` §9) — its type-level parameter list, the way
/// `context_reads` is for values. Must include a forwarding import's own
/// `%ctx.*` params, not only what a `type ... = ...` declaration mentions
/// directly.
pub fn type_params(prog: &Program) -> HashSet<Vec<String>> {
    fn go(e: &Expr) -> HashSet<Vec<String>> {
        let mut out: HashSet<Vec<String>> = type_exprs_in(e).iter().flat_map(type_params_in).collect();
        for sub in crate::ast::sub_exprs(e) {
            out.extend(go(sub));
        }
        out
    }
    go(prog.root())
}

/// For each import in this program, the type params (`type_params`) its
/// library needs that the import's `%`-marked entries do not supply —
/// `unsupplied_params`'s type-side twin, sharing the same "first segment"
/// imprecision.
pub fn unsupplied_type_params(libs: &HashMap<String, Program>, prog: &Program) -> Vec<(String, HashSet<Vec<String>>)> {
    fn go(libs: &HashMap<String, Program>, e: &Expr, out: &mut Vec<(String, HashSet<Vec<String>>)>) {
        if let Expr::Import(name, params) = e {
            let supplied: HashSet<&str> = params
                .iter()
                .filter_map(|(k, p)| matches!(p, ParamValue::PType(_)).then_some(k.as_str()))
                .collect();
            let wanted = libs.get(name).map(type_params).unwrap_or_default();
            let missing: HashSet<Vec<String>> = wanted
                .into_iter()
                .filter(|p| match p.first() {
                    None => false,
                    Some(root) => !supplied.contains(root.as_str()),
                })
                .collect();
            out.push((name.clone(), missing));
        }
        for sub in crate::ast::sub_exprs(e) {
            go(libs, sub, out);
        }
    }
    let mut out = Vec::new();
    go(libs, prog.root(), &mut out);
    out
}

/// Every params key read both as a value context path (`$ctx.k`/`ctx(k)`)
/// and as a type hole (`%ctx.k`) — v4-types §10's `TypeParamCollision`,
/// keyed by first segment exactly as `unsupplied_params` and
/// `unsupplied_type_params` both are.
pub fn type_param_collisions(prog: &Program) -> HashSet<String> {
    let reads: HashSet<String> = context_reads(prog).into_iter().filter_map(|p| p.into_iter().next()).collect();
    let tparams: HashSet<String> = type_params(prog).into_iter().filter_map(|p| p.into_iter().next()).collect();
    reads.intersection(&tparams).cloned().collect()
}

// Card ------------------------------------------------------------------------

/// What a program's root evaluates to — named for display; carries the same
/// information as which of `Program`'s two variants wraps it, decided by the
/// parser from the root's own syntax, never by running anything. Rust
/// counterpart of `Tramaj.Analysis.Card`'s `ProgramKind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgramKind {
    ProducesDocument,
    ProducesValue,
}

pub fn program_kind(prog: &Program) -> ProgramKind {
    match prog {
        Program::DocumentProgram(_) => ProgramKind::ProducesDocument,
        Program::ExpressionProgram(_) => ProgramKind::ProducesValue,
    }
}

/// A one-glance summary of a program's static interface, assembled from this
/// module's own primitives rather than adding any new AST walk. Rust
/// counterpart of `Tramaj.Analysis.Card`'s `Card`/`programCard` — see that
/// module's doc comment for why `requires` is the shallow `context_reads`,
/// not `deep_context_holes`: a card describes what running *this* program
/// needs from its own caller, not the bubbled-up shape of every library
/// underneath it.
///
/// Not part of the conformance corpus or the `node-json` wire format — this
/// is a presentation-level composition, not a new primitive, so it has no
/// PureScript/Haskell counterpart to keep in lockstep with the way this
/// module's other functions do.
pub struct Card {
    pub produces: ProgramKind,
    pub requires: HashSet<Vec<String>>,
    pub imports: HashSet<String>,
    pub emits: HashSet<String>,
    pub unsupplied: Vec<(String, HashSet<Vec<String>>)>,
}

/// `libs` plays the same role it does throughout this module: the library
/// table a host has so the *deep* fields — `imports`, `emits`, `unsupplied`
/// — can follow `import(...)` sites rather than stopping at this program's
/// own AST.
pub fn program_card(libs: &HashMap<String, Program>, prog: &Program) -> Card {
    Card {
        produces: program_kind(prog),
        requires: context_reads(prog),
        imports: transitive_import_names(libs, prog),
        emits: deep_action_keys(libs, prog),
        unsupplied: unsupplied_params(libs, prog),
    }
}
