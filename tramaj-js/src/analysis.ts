/**
 * Static analysis over the AST alone (`specs/reference.md` §9,
 * `specs/v3-symbols.md` §7, `specs/v4-types.md` §9). Answers from the AST
 * alone: no context, no library evaluation, no host code.
 *
 * Every set-valued answer is returned as a sorted array, so two runs over the
 * same program agree on order as well as membership.
 */

import {
  adaptKey,
  subExprs,
  typeDecls,
  unlets,
  type Expr,
  type Program,
  type TypeExpr,
} from "./ast.js";
import { compareStrings } from "./json.js";

type LibraryTable = Map<string, Program>;

function sortedStrings(xs: Iterable<string>): string[] {
  return [...new Set(xs)].sort(compareStrings);
}

function pathKey(path: string[]): string {
  return JSON.stringify(path);
}

function sortedPaths(xs: Iterable<string[]>): string[][] {
  const seen = new Map<string, string[]>();
  for (const p of xs) seen.set(pathKey(p), p);
  return [...seen.entries()].sort((a, b) => compareStrings(a[0], b[0])).map(([, p]) => p);
}

/** Collects from an expression and every expression inside it. */
function everywhere<T>(f: (e: Expr) => T[], e: Expr): T[] {
  return [...f(e), ...subExprs(e).flatMap((sub) => everywhere(f, sub))];
}

// Imports ---------------------------------------------------------------------

/** Every library this program imports directly. */
export function staticImportNames(prog: Program): string[] {
  return sortedStrings(everywhere((e) => (e.t === "Import" ? [e.name] : []), prog.root));
}

/**
 * Every library reachable from this program, directly or through another
 * import. A missing name is still reported; a cycle terminates.
 */
export function transitiveImportNames(libs: LibraryTable, prog: Program): string[] {
  const seen = new Set<string>();
  const frontier = [...staticImportNames(prog)];
  for (;;) {
    const name = frontier.pop();
    if (name === undefined) break;
    if (seen.has(name)) continue;
    seen.add(name);
    const p = libs.get(name);
    if (p === undefined) continue;
    for (const next of staticImportNames(p)) if (!seen.has(next)) frontier.push(next);
  }
  return sortedStrings(seen);
}

// Actions -----------------------------------------------------------------------

function ownKeysOf(e: Expr): string[] {
  return e.t === "Element"
    ? e.attributes.flatMap((a) => (a.t === "ActionAttr" ? [a.key] : []))
    : [];
}

function actionKeysIn(e: Expr): string[] {
  if (e.t === "AdaptActions") {
    const out = actionKeysIn(e.target).map((k) => adaptKey(e.adaptation, k));
    return e.fn === null ? out : [...out, ...actionKeysIn(e.fn)];
  }
  return [...ownKeysOf(e), ...subExprs(e).flatMap(actionKeysIn)];
}

/** Every action key this program can emit from its own AST; adaptation is applied, not ignored. */
export function staticActionKeys(prog: Program): string[] {
  return sortedStrings(actionKeysIn(prog.root));
}

/**
 * Every action key this program can emit, following imports. An
 * over-approximation: keys under a `Branch` arm that will never be selected
 * are still reported.
 */
export function deepActionKeys(libs: LibraryTable, prog: Program): string[] {
  const go = (seen: Set<string>, e: Expr): string[] => {
    if (e.t === "AdaptActions") {
      const out = go(seen, e.target).map((k) => adaptKey(e.adaptation, k));
      return e.fn === null ? out : [...out, ...go(seen, e.fn)];
    }
    if (e.t === "Import") {
      const out = e.params.flatMap(([, p]) => (p.t === "PExpr" ? go(seen, p.expr) : []));
      if (!seen.has(e.name)) {
        seen.add(e.name);
        const p = libs.get(e.name);
        if (p !== undefined) out.push(...go(seen, p.root));
      }
      return out;
    }
    return [...ownKeysOf(e), ...subExprs(e).flatMap((sub) => go(seen, sub))];
  };
  return sortedStrings(go(new Set(), prog.root));
}

// Context holes ---------------------------------------------------------------------

function ownContextHoles(e: Expr): string[][] {
  return e.t === "Import"
    ? e.params.flatMap(([, p]) => (p.t === "PFromContext" ? [p.path] : []))
    : [];
}

/** Every path this program declares as a hole with `ctx(path)`. */
export function contextHoles(prog: Program): string[][] {
  return sortedPaths(everywhere(ownContextHoles, prog.root));
}

/** Context holes of this program and of every library it imports. */
export function deepContextHoles(libs: LibraryTable, prog: Program): string[][] {
  const out = [...contextHoles(prog)];
  for (const name of transitiveImportNames(libs, prog)) {
    const p = libs.get(name);
    if (p !== undefined) out.push(...contextHoles(p));
  }
  return sortedPaths(out);
}

/** Every path this program reads out of its own context, however written. */
export function contextReads(prog: Program): string[][] {
  return sortedPaths(
    everywhere(
      (e) => (e.t === "Path" && e.root === "ctx" ? [e.fields] : ownContextHoles(e)),
      prog.root,
    ),
  );
}

/**
 * For each import in this program, the paths its library reads from its context
 * that the import does not supply. Attributed by the read's first segment.
 */
export function unsuppliedParams(
  libs: LibraryTable,
  prog: Program,
): Array<[string, string[][]]> {
  const out: Array<[string, string[][]]> = [];
  const collect = (e: Expr): void => {
    if (e.t === "Import") {
      const supplied = new Set(e.params.map(([k]) => k));
      const p = libs.get(e.name);
      const reads = p === undefined ? [] : contextReads(p);
      out.push([
        e.name,
        reads.filter((path) => path.length > 0 && !supplied.has(path[0] as string)),
      ]);
    }
    for (const sub of subExprs(e)) collect(sub);
  };
  collect(prog.root);
  return out;
}

// Constraints -------------------------------------------------------------------

/** Every constraint name this program can emit from its own AST (`v3-symbols.md` §7). */
export function constraintKinds(prog: Program): string[] {
  return sortedStrings(everywhere((e) => (e.t === "Constrain" ? [e.name] : []), prog.root));
}

/** Every constraint name this program can emit, following imports. Over-approximates. */
export function deepConstraintKinds(libs: LibraryTable, prog: Program): string[] {
  const go = (seen: Set<string>, e: Expr): string[] => {
    if (e.t === "Import") {
      const out = e.params.flatMap(([, p]) => (p.t === "PExpr" ? go(seen, p.expr) : []));
      if (!seen.has(e.name)) {
        seen.add(e.name);
        const p = libs.get(e.name);
        if (p !== undefined) out.push(...go(seen, p.root));
      }
      return out;
    }
    const own = e.t === "Constrain" ? [e.name] : [];
    return [...own, ...subExprs(e).flatMap((sub) => go(seen, sub))];
  };
  return sortedStrings(go(new Set(), prog.root));
}

// Symbols -------------------------------------------------------------------

/**
 * The `?(k)` allocation sites this program contains (`v3-symbols.md` §7) —
 * sites, not keys. Also the static counterpart of `AllocationInLibrary` (§6):
 * a program with a non-empty `symbolSites` cannot serve as a library.
 */
export function symbolSites(prog: Program): number[] {
  const sites = everywhere((e) => (e.t === "Alloc" ? [e.site] : []), prog.root);
  return [...new Set(sites)].sort((a, b) => a - b);
}

/** Every context path this program declares symbolic with `?ctx.…` (§7), directly. */
export function symbolDemands(prog: Program): string[][] {
  return sortedPaths(everywhere((e) => (e.t === "Demand" ? [e.path] : []), prog.root));
}

/** Demands bubbled up through every library this program imports. */
export function deepSymbolDemands(libs: LibraryTable, prog: Program): string[][] {
  const out = [...symbolDemands(prog)];
  for (const name of transitiveImportNames(libs, prog)) {
    const p = libs.get(name);
    if (p !== undefined) out.push(...symbolDemands(p));
  }
  return sortedPaths(out);
}

// Types -----------------------------------------------------------------------

/** Every name this program declares with `type ... = ...` (`v4-types.md` §9). */
export function typeDeclarations(prog: Program): string[] {
  return sortedStrings(typeDecls(unlets(prog.root).statements).map(([n]) => n));
}

/**
 * The `%ctx.*` paths one `TypeExpr` mentions directly — `Var` is a leaf, the
 * way `types.resolveTypeExpr` must treat it: a reference's own parameters are
 * not its referent's.
 */
function typeParamsIn(t: TypeExpr): string[][] {
  switch (t.t) {
    case "Array":
      return typeParamsIn(t.element);
    case "Record":
      return t.fields.flatMap(([, ft]) => typeParamsIn(ft));
    case "Union":
      return t.arms.flatMap(([, at]) => (at === null ? [] : typeParamsIn(at)));
    case "Var":
      return [t.path];
    case "Prim":
    case "Name":
    case "LibRef":
      return [];
  }
}

/**
 * Every `TypeExpr` sitting in one expression's own syntax, not recursing into
 * subexpressions — a declaration's body, an annotation's type, a type
 * constraint's type-marked arguments, and an import parameter's `%`-marked
 * value are the four positions a `TypeExpr` can occur in at all.
 */
export function typeExprsIn(e: Expr): TypeExpr[] {
  switch (e.t) {
    case "TypeDecl":
    case "TypeAnnotate":
      return [e.type];
    case "TypeEmit":
      return e.args.flatMap((a) => (a.t === "Type" ? [a.type] : []));
    case "Import":
      return e.params.flatMap(([, p]) => (p.t === "PType" ? [p.type] : []));
    default:
      return [];
  }
}

/**
 * Every `%ctx.*` path this program mentions in a type-bearing position
 * (`v4-types.md` §9) — its type-level parameter list, the way `contextReads` is
 * for values.
 */
export function typeParams(prog: Program): string[][] {
  return sortedPaths(everywhere((e) => typeExprsIn(e).flatMap(typeParamsIn), prog.root));
}

/**
 * For each import in this program, the type params its library needs that the
 * import's `%`-marked entries do not supply.
 */
export function unsuppliedTypeParams(
  libs: LibraryTable,
  prog: Program,
): Array<[string, string[][]]> {
  const out: Array<[string, string[][]]> = [];
  const go = (e: Expr): void => {
    if (e.t === "Import") {
      const supplied = new Set(e.params.flatMap(([k, p]) => (p.t === "PType" ? [k] : [])));
      const p = libs.get(e.name);
      const wanted = p === undefined ? [] : typeParams(p);
      out.push([
        e.name,
        wanted.filter((path) => path.length > 0 && !supplied.has(path[0] as string)),
      ]);
    }
    for (const sub of subExprs(e)) go(sub);
  };
  go(prog.root);
  return out;
}

/**
 * Every params key read both as a value context path (`$ctx.k`/`ctx(k)`) and as
 * a type hole (`%ctx.k`) — `v4-types.md` §10's `TypeParamCollision`, keyed by
 * first segment.
 */
export function typeParamCollisions(prog: Program): string[] {
  const reads = new Set(contextReads(prog).flatMap((p) => (p.length > 0 ? [p[0] as string] : [])));
  const tparams = typeParams(prog).flatMap((p) => (p.length > 0 ? [p[0] as string] : []));
  return sortedStrings(tparams.filter((k) => reads.has(k)));
}

// Card --------------------------------------------------------------------

export type ProgramKind = "document" | "value";

export interface Card {
  produces: ProgramKind;
  requires: string[][];
  imports: string[];
  emits: string[];
  unsupplied: Array<[string, string[][]]>;
}

export function programKind(prog: Program): ProgramKind {
  return prog.kind === "document" ? "document" : "value";
}

/**
 * A one-glance summary of a program's static interface, composed from the
 * primitives above rather than adding a new AST walk. `requires` is
 * deliberately the shallow, root-only `contextReads`: a card describes what
 * running *this* program needs from its own caller.
 */
export function programCard(libs: LibraryTable, prog: Program): Card {
  return {
    produces: programKind(prog),
    requires: contextReads(prog),
    imports: transitiveImportNames(libs, prog),
    emits: deepActionKeys(libs, prog),
    unsupplied: unsuppliedParams(libs, prog),
  };
}
