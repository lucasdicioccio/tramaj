//! Core AST (`specs/reference.md` §2, `specs/v3-symbols.md` §3). Mirrors
//! `tramaj-hs/src/Tramaj/Ast.hs`, restricted to the R1+R2 (core v2 plus v3
//! symbols) subset: no v4 types.

#[derive(Debug, Clone, PartialEq)]
pub enum Program {
    DocumentProgram(Expr),
    ExpressionProgram(Expr),
}

impl Program {
    pub fn root(&self) -> &Expr {
        match self {
            Program::DocumentProgram(e) => e,
            Program::ExpressionProgram(e) => e,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Path(String, Vec<String>),
    FieldAccess(Box<Expr>, Vec<String>),
    Call(Box<Expr>, Vec<Expr>),
    Lambda(Vec<String>, Box<Expr>),
    Let(String, Box<Expr>, Box<Expr>),
    StringLit(String),
    NumberLit(f64),
    BoolLit(bool),
    NullLit,
    ArrayLit(Vec<Expr>),
    ObjectLit(Vec<(String, Expr)>),
    Element(String, Vec<Attribute>, Box<Expr>, Vec<Expr>),
    Fragment(Vec<Expr>),
    Branch(Box<Expr>, Box<Expr>, Box<Expr>),
    Map(Box<Expr>, Box<Expr>),
    Filter(Box<Expr>, Box<Expr>),
    Scan(Box<Expr>, Box<Expr>, Box<Expr>),
    Fold(Box<Expr>, Box<Expr>, Box<Expr>),
    Concat(Box<Expr>, Box<Expr>),
    Import(String, Vec<(String, ParamValue)>),
    AdaptActions(Box<Expr>, ActionAdaptation, Option<Box<Expr>>),
    /// `constraint(name, arg1, arg2, ...)` (`v3-symbols.md` §2.1): a static
    /// string name plus any number of ordinary expressions.
    Constrain(String, Vec<Expr>),
    /// `!expr` (`v3-symbols.md` §2.2, §3): a statement, not a value-producing
    /// form. Nests into the same chain `Let` does, so "earlier bindings
    /// only" falls out of ordinary lexical scoping.
    Emit(Box<Expr>, Box<Expr>),
    /// `?(key)` (`v3-symbols.md` §1.2): allocates a symbol. The site is the
    /// n-th `?(...)` in the program's source, assigned by `number_allocs`
    /// after parsing rather than by the parser itself, so that agreement
    /// between implementations rests on this one pure function rather than
    /// on two parsers' internal traversal order.
    Alloc(usize, Box<Expr>),
    /// `?ctx.a.b` (`v3-symbols.md` §1.3): the path MUST be rooted at `ctx`.
    Demand(Vec<String>),
    /// `type Name = TypeExpr` (`v4-types.md` §1.1): a nominal type
    /// declaration. Nests into the same `Let`/`Emit` chain as an ordinary
    /// binding. The `TypeExpr` carries no `Expr`: resolution (§9) is a
    /// separate static pass over the chain, not threaded through evaluation
    /// — the evaluator never needs to know it exists beyond skipping past it.
    TypeDecl(String, TypeExpr, Box<Expr>),
    /// `@x : T = e` (`v4-types.md` §7): an annotated binding. Distinct from
    /// `Let` rather than folding the type into it, since a plain `Let` must
    /// stay meaningful with no type pass ever having run. An erasure pass
    /// (§7, `types::erase_types`), run before evaluation, rewrites every
    /// `TypeAnnotate` into the `Let` plus `Emit` of a `has-type` constraint
    /// §7 specifies; the evaluator itself never matches this constructor in
    /// the normal path (see `eval::eval_expr`'s totality case for it).
    TypeAnnotate(String, TypeExpr, Box<Expr>, Box<Expr>),
    /// `!type-constraint(name, args...)` (`v4-types.md` §5): a sibling of
    /// `Emit` in the type realm. Resolved by the analyser, never evaluated —
    /// §5.1 is explicit that the evaluator's statement fold skips this the
    /// way it skips `TypeDecl`.
    TypeEmit(String, Vec<TypeConstraintArg>, Box<Expr>),
}

/// The type algebra (`v4-types.md` §1), before resolution. `Ref` is split
/// into two pre-resolution forms: `Name` for a bare local name (`Point`) and
/// `LibRef` for a name reached through an import (`$msg.types.Envelope`).
/// Resolution (`types::resolve_type_expr`) is what turns either into a
/// genuine `(library, name)` reference or reports `UnresolvedType` — parsing
/// alone cannot tell a declaration name from a typo.
///
/// `Prim` is recognized at parse time, rather than left for resolution to
/// classify: the five primitive names are a closed, reserved lexical set
/// (§1), not ordinary identifiers that happen to resolve to a primitive.
#[derive(Debug, Clone, PartialEq)]
pub enum TypeExpr {
    Prim(String),
    Array(Box<TypeExpr>),
    Record(Vec<(String, TypeExpr)>),
    Union(Vec<(String, Option<TypeExpr>)>),
    Name(String),
    LibRef(String, String),
    /// `%ctx.a.b` (§1): a type hole. Unlike `Demand`, this never allocates
    /// anything — §4 requires every `Var` to be resolved away before a
    /// program may run at all.
    Var(Vec<String>),
}

/// One argument to `!type-constraint` (`v4-types.md` §5): a `%`-marked type
/// expression, or a literal scalar. A bare `Expr` would overreach — §5 fixes
/// the argument grammar to exactly these two shapes, computed nowhere, which
/// is what keeps a type constraint statically collectible the way an
/// ordinary `constraint`'s *name* is but its arguments are not.
#[derive(Debug, Clone, PartialEq)]
pub enum TypeConstraintArg {
    Type(TypeExpr),
    ScalarStr(String),
    ScalarNum(f64),
    ScalarBool(bool),
    ScalarNull,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ParamValue {
    PExpr(Expr),
    PFromContext(Vec<String>),
    /// `%T` or `%ctx.path` in a params record (`v4-types.md` §2): a type
    /// argument, told apart from `PExpr`/`PFromContext` purely by the
    /// leading `%` the parser already saw.
    PType(TypeExpr),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Attribute {
    Attr(String, Expr),
    ActionAttr(String, String, Expr),
}

#[derive(Debug, Clone, PartialEq)]
pub enum ActionAdaptation {
    Identity,
    Prefix(String),
}

pub fn adapt_key(adaptation: &ActionAdaptation, key: &str) -> String {
    match adaptation {
        ActionAdaptation::Identity => key.to_string(),
        ActionAdaptation::Prefix(p) => format!("{p}{key}"),
    }
}

/// The immediately-contained expressions of an expression, in source order.
/// Mirrors `Ast.hs`'s `subExprs` — used by `analysis.rs`.
pub fn sub_exprs(e: &Expr) -> Vec<&Expr> {
    match e {
        Expr::Path(_, _) => vec![],
        Expr::FieldAccess(target, _) => vec![target],
        Expr::Call(f, args) => {
            let mut v = vec![f.as_ref()];
            v.extend(args.iter());
            v
        }
        Expr::Lambda(_, body) => vec![body],
        Expr::Let(_, value, body) => vec![value, body],
        Expr::StringLit(_) => vec![],
        Expr::NumberLit(_) => vec![],
        Expr::BoolLit(_) => vec![],
        Expr::NullLit => vec![],
        Expr::ArrayLit(elems) => elems.iter().collect(),
        Expr::ObjectLit(entries) => entries.iter().map(|(_, e)| e).collect(),
        Expr::Element(_, attrs, val, children) => {
            let mut v = attribute_exprs(attrs);
            v.push(val.as_ref());
            v.extend(children.iter());
            v
        }
        Expr::Fragment(children) => children.iter().collect(),
        Expr::Branch(c, t, e2) => vec![c, t, e2],
        Expr::Map(coll, f) => vec![coll, f],
        Expr::Filter(coll, f) => vec![coll, f],
        Expr::Scan(coll, init, f) => vec![coll, init, f],
        Expr::Fold(coll, init, f) => vec![coll, init, f],
        Expr::Concat(l, r) => vec![l, r],
        Expr::Import(_, params) => params
            .iter()
            .filter_map(|(_, p)| match p {
                ParamValue::PExpr(e) => Some(e),
                ParamValue::PFromContext(_) => None,
                        ParamValue::PType(_) => None,
            })
            .collect(),
        Expr::AdaptActions(target, _, fn_) => {
            let mut v = vec![target.as_ref()];
            if let Some(f) = fn_ {
                v.push(f.as_ref());
            }
            v
        }
        Expr::Constrain(_, args) => args.iter().collect(),
        Expr::Emit(constraint, body) => vec![constraint, body],
        Expr::Alloc(_, key) => vec![key],
        Expr::Demand(_) => vec![],
        Expr::TypeDecl(_, _, body) => vec![body],
        Expr::TypeAnnotate(_, _, value, body) => vec![value, body],
        Expr::TypeEmit(_, _, body) => vec![body],
    }
}

/// The immediately-contained expressions of an expression, mutably, in the
/// same order `sub_exprs` reports them — used only by `number_allocs`, which
/// needs to rewrite `Alloc` sites in place.
fn sub_exprs_mut(e: &mut Expr) -> Vec<&mut Expr> {
    match e {
        Expr::Path(_, _) => vec![],
        Expr::FieldAccess(target, _) => vec![target],
        Expr::Call(f, args) => {
            let mut v = vec![f.as_mut()];
            v.extend(args.iter_mut());
            v
        }
        Expr::Lambda(_, body) => vec![body],
        Expr::Let(_, value, body) => vec![value, body],
        Expr::StringLit(_) => vec![],
        Expr::NumberLit(_) => vec![],
        Expr::BoolLit(_) => vec![],
        Expr::NullLit => vec![],
        Expr::ArrayLit(elems) => elems.iter_mut().collect(),
        Expr::ObjectLit(entries) => entries.iter_mut().map(|(_, e)| e).collect(),
        Expr::Element(_, attrs, val, children) => {
            let mut v: Vec<&mut Expr> = attrs
                .iter_mut()
                .map(|a| match a {
                    Attribute::Attr(_, e) => e,
                    Attribute::ActionAttr(_, _, e) => e,
                })
                .collect();
            v.push(val.as_mut());
            v.extend(children.iter_mut());
            v
        }
        Expr::Fragment(children) => children.iter_mut().collect(),
        Expr::Branch(c, t, e2) => vec![c, t, e2],
        Expr::Map(coll, f) => vec![coll, f],
        Expr::Filter(coll, f) => vec![coll, f],
        Expr::Scan(coll, init, f) => vec![coll, init, f],
        Expr::Fold(coll, init, f) => vec![coll, init, f],
        Expr::Concat(l, r) => vec![l, r],
        Expr::Import(_, params) => params
            .iter_mut()
            .filter_map(|(_, p)| match p {
                ParamValue::PExpr(e) => Some(e),
                ParamValue::PFromContext(_) => None,
                        ParamValue::PType(_) => None,
            })
            .collect(),
        Expr::AdaptActions(target, _, fn_) => {
            let mut v = vec![target.as_mut()];
            if let Some(f) = fn_ {
                v.push(f.as_mut());
            }
            v
        }
        Expr::Constrain(_, args) => args.iter_mut().collect(),
        Expr::Emit(constraint, body) => vec![constraint, body],
        Expr::Alloc(_, key) => vec![key],
        Expr::Demand(_) => vec![],
        Expr::TypeDecl(_, _, body) => vec![body],
        Expr::TypeAnnotate(_, _, value, body) => vec![value, body],
        Expr::TypeEmit(_, _, body) => vec![body],
    }
}

/// Assigns each `Alloc` in a program the index of its `?(...)` among all of
/// them, in source order (`v3-symbols.md` §1.4) — a plain pre-order,
/// left-to-right walk over the freshly parsed tree, numbering as it goes.
/// Mirrors `Ast.hs`'s `numberAllocs`: done as a rewrite after parsing so two
/// independently written parsers agree on site numbers by construction,
/// rather than by agreeing on a parser-internal traversal order.
pub fn number_allocs(e: &mut Expr) {
    fn go(e: &mut Expr, n: &mut usize) {
        if let Expr::Alloc(site, key) = e {
            *site = *n;
            *n += 1;
            go(key, n);
            return;
        }
        for sub in sub_exprs_mut(e) {
            go(sub, n);
        }
    }
    let mut n = 0usize;
    go(e, &mut n);
}

fn attribute_exprs(attrs: &[Attribute]) -> Vec<&Expr> {
    attrs
        .iter()
        .map(|a| match a {
            Attribute::Attr(_, e) => e,
            Attribute::ActionAttr(_, _, e) => e,
        })
        .collect()
}

/// One statement of a program's surface statement block, after lowering —
/// mirrors `Tramaj.Ast`'s `Stmt`. This is only `unlets`'s view of the
/// `Let`/`Emit`/`TypeDecl`/`TypeAnnotate`/`TypeEmit` chain; both v4's static
/// analyses (`analysis.rs`, `types.rs`) and library evaluation (`eval.rs`)
/// need to walk it.
#[derive(Debug, Clone, PartialEq)]
pub enum Stmt {
    Let(String, Expr),
    Emit(Expr),
    TypeDecl(String, TypeExpr),
    Annotate(String, TypeExpr, Expr),
    TypeEmit(String, Vec<TypeConstraintArg>),
}

/// Peels the outermost `Let`/`Emit`/`TypeDecl`/`TypeAnnotate`/`TypeEmit`
/// chain back off — mirrors `Ast.hs`'s `unlets`. Stopping at the first
/// non-statement constructor, so a binding block with a `!` (or a `type`, or
/// an annotated binding) threaded through it is recovered whole.
pub fn unlets(e: &Expr) -> (Vec<Stmt>, &Expr) {
    let mut out = Vec::new();
    let mut cur = e;
    loop {
        match cur {
            Expr::Let(name, value, body) => {
                out.push(Stmt::Let(name.clone(), (**value).clone()));
                cur = body;
            }
            Expr::Emit(constraint, body) => {
                out.push(Stmt::Emit((**constraint).clone()));
                cur = body;
            }
            Expr::TypeDecl(name, t, body) => {
                out.push(Stmt::TypeDecl(name.clone(), t.clone()));
                cur = body;
            }
            Expr::TypeAnnotate(name, t, value, body) => {
                out.push(Stmt::Annotate(name.clone(), t.clone(), (**value).clone()));
                cur = body;
            }
            Expr::TypeEmit(name, args, body) => {
                out.push(Stmt::TypeEmit(name.clone(), args.clone()));
                cur = body;
            }
            _ => break,
        }
    }
    (out, cur)
}

/// Just the type declarations of a statement block, in order — the
/// type-realm analogue of `let_bindings`.
pub fn type_decls(stmts: &[Stmt]) -> Vec<(String, TypeExpr)> {
    stmts
        .iter()
        .filter_map(|s| match s {
            Stmt::TypeDecl(n, t) => Some((n.clone(), t.clone())),
            _ => None,
        })
        .collect()
}

/// A name the parser invents when lowering a binding pattern
/// (`specs/decisions.md` §17): it starts with `#`, which no surface name
/// can. Such a binding is a lowering detail, so it is never reported as a
/// symbol's `"binding"` and never exposed through a library's `.vals`.
pub fn is_hidden_name(n: &str) -> bool {
    n.starts_with('#')
}

/// Just the named bindings of a statement block, in order — what an import
/// exposes as `.vals`. An annotated binding still binds its name, so it
/// counts here exactly as a plain `Let` does; only emissions and type
/// declarations are discarded positionally.
pub fn let_bindings(stmts: &[Stmt]) -> Vec<(String, Expr)> {
    stmts
        .iter()
        .filter_map(|s| match s {
            Stmt::Let(n, e) => Some((n.clone(), e.clone())),
            Stmt::Annotate(n, _, e) => Some((n.clone(), e.clone())),
            _ => None,
        })
        .collect()
}
