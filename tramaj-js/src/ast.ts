/**
 * Core AST (`specs/reference.md` §2, `specs/v3-symbols.md` §3,
 * `specs/v4-types.md` §1). Mirrors `tramaj-rs/src/ast.rs` and
 * `tramaj-hs/src/Tramaj/Ast.hs`.
 */

export type Program =
  | { kind: "document"; root: Expr }
  | { kind: "expression"; root: Expr };

export function documentProgram(root: Expr): Program {
  return { kind: "document", root };
}

export function expressionProgram(root: Expr): Program {
  return { kind: "expression", root };
}

export type Expr =
  | { t: "Path"; root: string; fields: string[] }
  | { t: "FieldAccess"; target: Expr; fields: string[] }
  | { t: "Call"; fn: Expr; args: Expr[] }
  | { t: "Lambda"; params: string[]; body: Expr }
  | { t: "Let"; name: string; value: Expr; body: Expr }
  | { t: "StringLit"; value: string }
  | { t: "NumberLit"; value: number }
  | { t: "BoolLit"; value: boolean }
  | { t: "NullLit" }
  | { t: "ArrayLit"; elements: Expr[] }
  | { t: "ObjectLit"; fields: Array<[string, Expr]> }
  | { t: "Element"; tag: string; attributes: Attribute[]; value: Expr; children: Expr[] }
  | { t: "Fragment"; children: Expr[] }
  | { t: "Branch"; condition: Expr; then: Expr; else: Expr }
  | { t: "Map"; collection: Expr; fn: Expr }
  | { t: "Filter"; collection: Expr; fn: Expr }
  | { t: "Scan"; collection: Expr; initial: Expr; fn: Expr }
  | { t: "Fold"; collection: Expr; initial: Expr; fn: Expr }
  | { t: "Concat"; left: Expr; right: Expr }
  | { t: "Import"; name: string; params: Array<[string, ParamValue]> }
  | { t: "AdaptActions"; target: Expr; adaptation: ActionAdaptation; fn: Expr | null }
  /** `constraint(name, args...)` (`v3-symbols.md` §2.1). */
  | { t: "Constrain"; name: string; args: Expr[] }
  /** `!expr` (`v3-symbols.md` §2.2): a statement, nesting into the same chain `Let` does. */
  | { t: "Emit"; constraint: Expr; body: Expr }
  /**
   * `?(key)` (`v3-symbols.md` §1.2). `site` is assigned by `numberAllocs`
   * after parsing rather than by the parser, so agreement between
   * implementations rests on that one pure function.
   */
  | { t: "Alloc"; site: number; key: Expr }
  /** `?ctx.a.b` (`v3-symbols.md` §1.3): the path is always rooted at `ctx`, which is not stored. */
  | { t: "Demand"; path: string[] }
  | { t: "TypeDecl"; name: string; type: TypeExpr; body: Expr }
  | { t: "TypeAnnotate"; name: string; type: TypeExpr; value: Expr; body: Expr }
  | { t: "TypeEmit"; name: string; args: TypeConstraintArg[]; body: Expr };

/**
 * The type algebra (`v4-types.md` §1) before resolution. `Name` is a bare
 * local name, `LibRef` one reached through an import; telling either from a
 * typo is `types.resolveTypeExpr`'s job, not the parser's.
 */
export type TypeExpr =
  | { t: "Prim"; name: string }
  | { t: "Array"; element: TypeExpr }
  | { t: "Record"; fields: Array<[string, TypeExpr]> }
  | { t: "Union"; arms: Array<[string, TypeExpr | null]> }
  | { t: "Name"; name: string }
  | { t: "LibRef"; lib: string; name: string }
  | { t: "Var"; path: string[] };

export type TypeConstraintArg =
  | { t: "Type"; type: TypeExpr }
  | { t: "ScalarStr"; value: string }
  | { t: "ScalarNum"; value: number }
  | { t: "ScalarBool"; value: boolean }
  | { t: "ScalarNull" };

export type ParamValue =
  | { t: "PExpr"; expr: Expr }
  | { t: "PFromContext"; path: string[] }
  | { t: "PType"; type: TypeExpr };

export type Attribute =
  | { t: "Attr"; name: string; value: Expr }
  | { t: "ActionAttr"; event: string; key: string; payload: Expr };

export type ActionAdaptation = { t: "Identity" } | { t: "Prefix"; prefix: string };

export function adaptKey(adaptation: ActionAdaptation, key: string): string {
  return adaptation.t === "Identity" ? key : adaptation.prefix + key;
}

function attributeExprs(attrs: Attribute[]): Expr[] {
  return attrs.map((a) => (a.t === "Attr" ? a.value : a.payload));
}

/** The immediately-contained expressions of an expression, in source order. */
export function subExprs(e: Expr): Expr[] {
  switch (e.t) {
    case "Path":
    case "StringLit":
    case "NumberLit":
    case "BoolLit":
    case "NullLit":
    case "Demand":
      return [];
    case "FieldAccess":
      return [e.target];
    case "Call":
      return [e.fn, ...e.args];
    case "Lambda":
      return [e.body];
    case "Let":
      return [e.value, e.body];
    case "ArrayLit":
      return e.elements;
    case "ObjectLit":
      return e.fields.map(([, v]) => v);
    case "Element":
      return [...attributeExprs(e.attributes), e.value, ...e.children];
    case "Fragment":
      return e.children;
    case "Branch":
      return [e.condition, e.then, e.else];
    case "Map":
    case "Filter":
      return [e.collection, e.fn];
    case "Scan":
    case "Fold":
      return [e.collection, e.initial, e.fn];
    case "Concat":
      return [e.left, e.right];
    case "Import":
      return e.params.flatMap(([, p]) => (p.t === "PExpr" ? [p.expr] : []));
    case "AdaptActions":
      return e.fn === null ? [e.target] : [e.target, e.fn];
    case "Constrain":
      return e.args;
    case "Emit":
      return [e.constraint, e.body];
    case "Alloc":
      return [e.key];
    case "TypeDecl":
      return [e.body];
    case "TypeAnnotate":
      return [e.value, e.body];
    case "TypeEmit":
      return [e.body];
  }
}

/**
 * Assigns each `Alloc` the index of its `?(...)` among all of them, in source
 * order (`v3-symbols.md` §1.4): a plain pre-order, left-to-right walk over the
 * freshly parsed tree. Done as a rewrite after parsing so two independently
 * written parsers agree on site numbers by construction.
 */
export function numberAllocs(e: Expr): void {
  let n = 0;
  const go = (x: Expr): void => {
    if (x.t === "Alloc") {
      x.site = n;
      n += 1;
      go(x.key);
      return;
    }
    for (const sub of subExprs(x)) go(sub);
  };
  go(e);
}

export type Stmt =
  | { t: "Let"; name: string; value: Expr }
  | { t: "Emit"; constraint: Expr }
  | { t: "TypeDecl"; name: string; type: TypeExpr }
  | { t: "Annotate"; name: string; type: TypeExpr; value: Expr }
  | { t: "TypeEmit"; name: string; args: TypeConstraintArg[] };

/**
 * Peels the outermost `Let`/`Emit`/`TypeDecl`/`TypeAnnotate`/`TypeEmit` chain
 * back off, stopping at the first non-statement constructor.
 */
export function unlets(e: Expr): { statements: Stmt[]; root: Expr } {
  const statements: Stmt[] = [];
  let cur = e;
  for (;;) {
    switch (cur.t) {
      case "Let":
        statements.push({ t: "Let", name: cur.name, value: cur.value });
        cur = cur.body;
        continue;
      case "Emit":
        statements.push({ t: "Emit", constraint: cur.constraint });
        cur = cur.body;
        continue;
      case "TypeDecl":
        statements.push({ t: "TypeDecl", name: cur.name, type: cur.type });
        cur = cur.body;
        continue;
      case "TypeAnnotate":
        statements.push({ t: "Annotate", name: cur.name, type: cur.type, value: cur.value });
        cur = cur.body;
        continue;
      case "TypeEmit":
        statements.push({ t: "TypeEmit", name: cur.name, args: cur.args });
        cur = cur.body;
        continue;
      default:
        return { statements, root: cur };
    }
  }
}

export function typeDecls(stmts: Stmt[]): Array<[string, TypeExpr]> {
  return stmts.flatMap((s) => (s.t === "TypeDecl" ? [[s.name, s.type] as [string, TypeExpr]] : []));
}

/**
 * Just the named bindings of a statement block, in order — what an import
 * exposes as `.vals`. An annotated binding still binds its name.
 */
export function letBindings(stmts: Stmt[]): Array<[string, Expr]> {
  return stmts.flatMap((s) =>
    s.t === "Let" || s.t === "Annotate" ? [[s.name, s.value] as [string, Expr]] : [],
  );
}
