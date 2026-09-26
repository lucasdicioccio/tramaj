/**
 * `Value`, the environment, and the evaluator — concrete and symbolic modes
 * (`specs/reference.md` §6, §7, §10; `specs/v3-symbols.md` §4-6;
 * `specs/v4-types.md` §7-8). Mirrors `tramaj-rs/src/eval.rs`.
 */

import { symbolSites } from "./analysis.js";
import {
  adaptKey,
  isHiddenName,
  unlets,
  type ActionAdaptation,
  type Attribute,
  type Expr,
  type Program,
} from "./ast.js";
import {
  compactJson,
  compareStrings,
  displayString,
  getField,
  hasField,
  isJsonObject,
  jsonEqual,
  jsonObjectFrom,
  ownKeys,
  type Json,
  type JsonObject,
} from "./json.js";
import {
  mapActions,
  noAnnotations,
  nodeToJson,
  type Node,
  type NodeAttribute,
} from "./node.js";
import {
  canonicalId,
  deepTypeConstraints,
  eraseTypes,
  programTypeRoots,
  typeClosure,
  TypeError as TramajTypeError,
  type ResolvedConstraintArg,
  type ResolvedType,
} from "./types.js";

export type Mode = "concrete" | "symbolic";

/** Host-supplied library table: import name -> parsed library program. */
export type LibraryTable = Map<string, Program>;

export type EvalErrorKind =
  | "UnboundName"
  | "PathNotFound"
  | "TypeMismatch"
  | "ConcatMismatch"
  | "UnknownLibrary"
  | "ImportCycle"
  | "InLibrary"
  | "SymbolsUnavailable"
  | "NotConcrete"
  | "AllocationInLibrary"
  | "TypeErr";

/**
 * Error kinds from `specs/reference.md` §12, plus v3's symbol kinds and the
 * one v4 static failure. `message` always leads with the bare kind, which is
 * what the corpus harness matches on.
 */
export class EvalError extends Error {
  override readonly name = "EvalError";
  readonly kind: EvalErrorKind;
  readonly detail: string;
  override readonly cause: EvalError | undefined;

  constructor(kind: EvalErrorKind, detail: string, cause?: EvalError) {
    super(detail === "" ? kind : `${kind} ${detail}`);
    this.kind = kind;
    this.detail = detail;
    this.cause = cause;
  }

  static unboundName(name: string): EvalError {
    return new EvalError("UnboundName", name);
  }

  static pathNotFound(path: string[]): EvalError {
    return new EvalError("PathNotFound", JSON.stringify(path));
  }

  static typeMismatch(m: string): EvalError {
    return new EvalError("TypeMismatch", m);
  }

  static concatMismatch(m: string): EvalError {
    return new EvalError("ConcatMismatch", m);
  }

  static unknownLibrary(name: string): EvalError {
    return new EvalError("UnknownLibrary", name);
  }

  static importCycle(name: string): EvalError {
    return new EvalError("ImportCycle", name);
  }

  static inLibrary(name: string, e: EvalError): EvalError {
    return new EvalError("InLibrary", `${name} (${e.message})`, e);
  }

  static symbolsUnavailable(m: string): EvalError {
    return new EvalError("SymbolsUnavailable", m);
  }

  static notConcrete(who: string): EvalError {
    return new EvalError("NotConcrete", who);
  }

  static allocationInLibrary(name: string): EvalError {
    return new EvalError("AllocationInLibrary", name);
  }

  static typeErr(e: TramajTypeError): EvalError {
    return new EvalError("TypeErr", e.message);
  }
}

// Values ---------------------------------------------------------------------

/**
 * The language's value domain. Arrays/objects hold `Value`, not JSON, so a
 * document node can travel inside a structure like any other value.
 */
export type Value =
  | { t: "null" }
  | { t: "bool"; value: boolean }
  | { t: "number"; value: number }
  | { t: "str"; value: string }
  | { t: "array"; items: Value[] }
  | { t: "object"; fields: Env }
  | { t: "node"; node: Node }
  | { t: "closure"; params: string[]; body: Expr; env: Env }
  | { t: "builtin"; name: string }
  | { t: "importResult"; fields: Env }
  | { t: "import"; pending: Pending }
  /** A symbol (`v3-symbols.md` §1.1): an id plus a projection path (§1.6). */
  | { t: "symbol"; id: string; path: string[] }
  /** `constraint(name, args...)` (`v3-symbols.md` §2.1). */
  | { t: "constraint"; name: string; args: Value[] };

export type Env = Map<string, Value>;

export interface Pending {
  name: string;
  params: Map<string, Value>;
  queued: Array<{ adaptation: ActionAdaptation; fn: Value | null }>;
}

type SymbolOrigin =
  | { t: "alloc"; site: number; key: Json }
  | { t: "demand"; path: string[] };

interface SymbolEntry {
  id: string;
  origin: SymbolOrigin;
  binding: string | null;
}

/**
 * What evaluation accumulates alongside its result (`v3-symbols.md` §4):
 * emitted constraints and allocated symbol-table entries, each in evaluation
 * order and deduplicated once, globally, at the top.
 */
interface Emissions {
  constraints: Value[];
  symbols: SymbolEntry[];
}

interface EvalCtx {
  libs: LibraryTable;
  inProgress: Set<string>;
  mode: Mode;
  /** Whether this is the root program or somewhere inside a library (§1.3, §1.4). */
  isRoot: boolean;
  emissions: Emissions;
}

function enterLibrary(name: string, ctx: EvalCtx): EvalCtx {
  const inProgress = new Set(ctx.inProgress);
  inProgress.add(name);
  return { libs: ctx.libs, inProgress, mode: ctx.mode, isRoot: false, emissions: ctx.emissions };
}

// Entry points -----------------------------------------------------------

export type Output = { t: "node"; node: Node } | { t: "value"; value: Json };

export function evalProgram(
  mode: Mode,
  libs: LibraryTable,
  ctx: Json,
  program: Program,
): Output {
  return evalProgramWithEmissions(mode, libs, ctx, program).output;
}

function evalProgramWithEmissions(
  mode: Mode,
  libs: LibraryTable,
  ctx: Json,
  program: Program,
): { output: Output; emissions: Emissions } {
  const erased = withTypeErrors(() => eraseTypes(libs, program));
  const ctxVal = checkedFromJson(mode, ctx);
  const emissions: Emissions = { constraints: [], symbols: [] };
  const evalCtx: EvalCtx = {
    libs,
    inProgress: new Set(),
    mode,
    isRoot: true,
    emissions,
  };
  const env = initialEnv(ctxVal);
  const v = evalExpr(evalCtx, env, erased.root);
  const output: Output =
    v.t === "node" ? { t: "node", node: v.node } : { t: "value", value: toJson(v) };
  return { output, emissions: dedupe(emissions) };
}

function withTypeErrors<T>(f: () => T): T {
  try {
    return f();
  } catch (e) {
    if (e instanceof TramajTypeError) throw EvalError.typeErr(e);
    throw e;
  }
}

/**
 * Two constraints with the same name and equal arguments are one constraint,
 * and two symbol-table entries with the same id are one entry — each kept at
 * the position of the first (`v3-symbols.md` §4).
 */
function dedupe(e: Emissions): Emissions {
  const constraints: Value[] = [];
  for (const c of e.constraints) {
    if (!constraints.some((x) => constraintEq(x, c))) constraints.push(c);
  }
  const symbols: SymbolEntry[] = [];
  for (const s of e.symbols) {
    if (!symbols.some((x) => x.id === s.id)) symbols.push(s);
  }
  return { constraints, symbols };
}

function constraintEq(a: Value, b: Value): boolean {
  if (a.t !== "constraint" || b.t !== "constraint") return false;
  if (a.name !== b.name || a.args.length !== b.args.length) return false;
  return a.args.every((x, i) => {
    try {
      return jsonEqual(toJson(x), toJson(b.args[i] as Value));
    } catch {
      return false;
    }
  });
}

/** Evaluates and serializes to the wire JSON a host compares against `expected.json`. */
export function runProgram(
  mode: Mode,
  libs: LibraryTable,
  ctx: Json,
  program: Program,
): Json {
  const { output, emissions } = evalProgramWithEmissions(mode, libs, ctx, program);
  if (mode === "concrete") {
    return output.t === "node" ? nodeToJson(output.node) : output.value;
  }
  const kind = output.t === "node" ? "document" : "expression";
  const root = output.t === "node" ? nodeToJson(output.node) : output.value;
  const { types, typeConstraints } = withTypeErrors(() => buildTypesInfo(libs, program));
  const sortedTypes = [...types.entries()].sort((a, b) => compareStrings(a[0], b[0]));
  return {
    format: "tramaj/symbolic/1",
    kind,
    root,
    symbols: emissions.symbols.map(symbolEntryToJson),
    constraints: emissions.constraints.map(constraintToJson),
    types: sortedTypes.map(([id, rt]) => ({ id, definition: resolvedTypeToJson(rt) })),
    "type-constraints": typeConstraints.map(typeConstraintToJson),
  };
}

function buildTypesInfo(
  libs: LibraryTable,
  prog: Program,
): { types: Map<string, ResolvedType>; typeConstraints: Array<[string, ResolvedConstraintArg[]]> } {
  const roots = programTypeRoots(libs, prog);
  return {
    types: typeClosure(libs, prog, roots),
    typeConstraints: deepTypeConstraints(libs, prog),
  };
}

/** A `ResolvedType`'s `"definition"` shape (`v4-types.md` §8). */
function resolvedTypeToJson(rt: ResolvedType): Json {
  switch (rt.t) {
    case "Prim":
      return { kind: "prim", name: rt.name };
    case "Array":
      return { kind: "array", element: resolvedTypeToJson(rt.element) };
    case "Record":
      return {
        kind: "record",
        fields: rt.fields.map(([name, t]) => ({ name, type: resolvedTypeToJson(t) })),
      };
    case "Union":
      return {
        kind: "union",
        arms: rt.arms.map(([name, payload]) =>
          payload === null ? { name } : { name, payload: resolvedTypeToJson(payload) },
        ),
      };
    // A `Ref` renders as a pointer only — its definition is a separate entry
    // in the table, which is §3's "stop at declaration boundaries" clause.
    case "Ref":
      return { kind: "ref", id: canonicalId(rt) };
    case "Var":
      return { kind: "var", path: [...rt.path] };
  }
}

function typeConstraintToJson([name, args]: [string, ResolvedConstraintArg[]]): Json {
  return {
    name,
    arguments: args.map((a): Json => {
      switch (a.t) {
        case "Type":
          return { $type: canonicalId(a.type) };
        case "ScalarStr":
          return a.value;
        case "ScalarNum":
          return a.value;
        case "ScalarBool":
          return a.value;
        case "ScalarNull":
          return null;
      }
    }),
  };
}

function constraintToJson(v: Value): Json {
  if (v.t !== "constraint") return tryToJson(v);
  return { name: v.name, arguments: v.args.map(tryToJson) };
}

function tryToJson(v: Value): Json {
  try {
    return toJson(v);
  } catch {
    return null;
  }
}

function symbolEntryToJson(e: SymbolEntry): Json {
  const origin: Json =
    e.origin.t === "alloc"
      ? { kind: "alloc", site: e.origin.site, key: e.origin.key }
      : { kind: "demand", path: [...e.origin.path] };
  return { id: e.id, origin, binding: e.binding };
}

const BUILTIN_NAMES = [
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
] as const;

function initialEnv(ctxVal: Value): Env {
  const env: Env = new Map();
  for (const n of BUILTIN_NAMES) env.set(n, { t: "builtin", name: n });
  env.set("ctx", ctxVal);
  return env;
}

// Core evaluation --------------------------------------------------------

function evalExpr(ctx: EvalCtx, env: Env, e: Expr): Value {
  switch (e.t) {
    case "Path": {
      const v = env.get(e.root);
      if (v === undefined) throw EvalError.unboundName(e.root);
      return walkFields(ctx, [e.root, ...e.fields], v, e.fields);
    }
    case "FieldAccess":
      return walkFields(ctx, e.fields, evalExpr(ctx, env, e.target), e.fields);
    case "Call": {
      const fnVal = evalExpr(ctx, env, e.fn);
      const argVals = e.args.map((a) => evalExpr(ctx, env, a));
      return apply(ctx, describeCallee(e.fn), fnVal, argVals);
    }
    case "Lambda":
      return { t: "closure", params: e.params, body: e.body, env: new Map(env) };
    // `@name=?(k)` or `@name=?ctx.path` binds the allocation/demand directly to
    // a name, which is what the symbol table's `"binding"` field reports.
    case "Let": {
      const v = evalBindable(ctx, env, isHiddenName(e.name) ? null : e.name, e.value);
      const env2 = new Map(env);
      env2.set(e.name, v);
      return evalExpr(ctx, env2, e.body);
    }
    case "StringLit":
      return { t: "str", value: e.value };
    case "NumberLit":
      return { t: "number", value: e.value };
    case "BoolLit":
      return { t: "bool", value: e.value };
    case "NullLit":
      return { t: "null" };
    case "ArrayLit":
      return { t: "array", items: e.elements.map((x) => evalExpr(ctx, env, x)) };
    case "ObjectLit": {
      const fields: Env = new Map();
      for (const [k, sub] of e.fields) fields.set(k, evalExpr(ctx, env, sub));
      return { t: "object", fields };
    }
    case "Element": {
      const attributes = e.attributes.map((a) => evalAttribute(ctx, env, a));
      const value = toJson(evalExpr(ctx, env, e.value));
      const children = evalChildren(ctx, env, e.children);
      return {
        t: "node",
        node: {
          t: "element",
          tag: e.tag,
          attributes,
          value,
          children,
          annotations: noAnnotations(),
        },
      };
    }
    case "Fragment":
      return {
        t: "node",
        node: { t: "fragment", children: evalChildren(ctx, env, e.children), annotations: noAnnotations() },
      };
    case "Branch": {
      const cond = requireBool("a branch condition", evalExpr(ctx, env, e.condition));
      return evalExpr(ctx, env, cond ? e.then : e.else);
    }
    case "Map": {
      const items = evalCollection(ctx, env, "map", e.collection);
      const fnVal = evalExpr(ctx, env, e.fn);
      return { t: "array", items: items.map((item) => apply(ctx, "map", fnVal, [item])) };
    }
    case "Filter": {
      const items = evalCollection(ctx, env, "filter", e.collection);
      const fnVal = evalExpr(ctx, env, e.fn);
      const kept: Value[] = [];
      for (const item of items) {
        if (requireBool("a filter predicate", apply(ctx, "filter", fnVal, [item]))) kept.push(item);
      }
      return { t: "array", items: kept };
    }
    case "Scan": {
      const items = evalCollection(ctx, env, "scan", e.collection);
      let acc = evalExpr(ctx, env, e.initial);
      const fnVal = evalExpr(ctx, env, e.fn);
      const out: Value[] = [acc];
      for (const item of items) {
        acc = apply(ctx, "scan", fnVal, [acc, item]);
        out.push(acc);
      }
      return { t: "array", items: out };
    }
    case "Fold": {
      const items = evalCollection(ctx, env, "fold", e.collection);
      let acc = evalExpr(ctx, env, e.initial);
      const fnVal = evalExpr(ctx, env, e.fn);
      for (const item of items) acc = apply(ctx, "fold", fnVal, [acc, item]);
      return acc;
    }
    case "Concat":
      return concatValues(evalExpr(ctx, env, e.left), evalExpr(ctx, env, e.right));
    case "Import": {
      const params: Map<string, Value> = new Map();
      for (const [k, p] of e.params) {
        if (p.t === "PExpr") {
          params.set(k, evalExpr(ctx, env, p.expr));
        } else if (p.t === "PFromContext") {
          const ctxVal = env.get("ctx");
          if (ctxVal === undefined) throw EvalError.unboundName("ctx");
          params.set(k, walkFields(ctx, ["ctx", ...p.path], ctxVal, p.path));
        }
        // A `%`-marked entry (`v4-types.md` §2) supplies a type, not a value,
        // so it never reaches the library's own `$ctx`.
      }
      return { t: "import", pending: { name: e.name, params, queued: [] } };
    }
    case "AdaptActions": {
      const target = evalExpr(ctx, env, e.target);
      const fnVal = e.fn === null ? null : evalExpr(ctx, env, e.fn);
      return adaptValue(ctx, e.adaptation, fnVal, target);
    }
    // Each argument must be able to cross a JSON boundary, checked here rather
    // than deferred: a constraint carrying a closure would otherwise sit
    // unnoticed until whatever `!` eventually reaches it.
    case "Constrain": {
      const args = e.args.map((a) => evalExpr(ctx, env, a));
      for (const a of args) toJson(a);
      return { t: "constraint", name: e.name, args };
    }
    case "Emit": {
      const cv = evalExpr(ctx, env, e.constraint);
      ctx.emissions.constraints.push(...collectConstraints(cv));
      return evalExpr(ctx, env, e.body);
    }
    case "Alloc":
    case "Demand":
      return evalBindable(ctx, env, null, e);
    // A type declaration means nothing to evaluation (`v4-types.md` §1.1).
    case "TypeDecl":
      return evalExpr(ctx, env, e.body);
    // Erasure rewrites every `TypeAnnotate` before evaluation, so this case is
    // not the normal path; kept total, matching what erasure would produce
    // minus the emission.
    case "TypeAnnotate": {
      const v = evalBindable(ctx, env, e.name, e.value);
      const env2 = new Map(env);
      env2.set(e.name, v);
      return evalExpr(ctx, env2, e.body);
    }
    case "TypeEmit":
      return evalExpr(ctx, env, e.body);
  }
}

/**
 * `Alloc` and `Demand` are the two forms whose symbol-table entry records the
 * name they were bound to, or `null` when used inline (`v3-symbols.md` §5.2).
 */
function evalBindable(ctx: EvalCtx, env: Env, binding: string | null, e: Expr): Value {
  if (e.t === "Alloc") return evalAlloc(ctx, env, binding, e.site, e.key);
  if (e.t === "Demand") return evalDemand(ctx, env, binding, e.path);
  return evalExpr(ctx, env, e);
}

/** `?(key)` (`v3-symbols.md` §1.2, §4): the key evaluates in both modes; only minting differs. */
function evalAlloc(
  ctx: EvalCtx,
  env: Env,
  binding: string | null,
  site: number,
  keyExpr: Expr,
): Value {
  const keyJson = requireConcrete("?(...)", evalExpr(ctx, env, keyExpr));
  if (ctx.mode === "concrete") {
    throw EvalError.symbolsUnavailable(
      "?(...) would have to allocate a symbol, which concrete mode cannot represent",
    );
  }
  const id = `#${site}:${compactJson(keyJson)}`;
  ctx.emissions.symbols.push({ id, origin: { t: "alloc", site, key: keyJson }, binding });
  return { t: "symbol", id, path: [] };
}

/**
 * `?ctx.a.b` (`v3-symbols.md` §1.3): reads exactly as `$ctx.a.b` would when
 * supplied. Unsupplied, it allocates at the root (mode permitting) and is an
 * ordinary unsupplied read anywhere else.
 */
function evalDemand(
  ctx: EvalCtx,
  env: Env,
  binding: string | null,
  path: string[],
): Value {
  const snapshot = {
    constraints: ctx.emissions.constraints.length,
    symbols: ctx.emissions.symbols.length,
  };
  try {
    return evalExpr(ctx, env, { t: "Path", root: "ctx", fields: path });
  } catch (err) {
    if (!(err instanceof EvalError)) throw err;
    // Anything the failed sub-evaluation emitted along the way is discarded
    // with it.
    ctx.emissions.constraints.length = snapshot.constraints;
    ctx.emissions.symbols.length = snapshot.symbols;
    if (err.kind !== "PathNotFound" || !ctx.isRoot) throw err;
    if (ctx.mode === "concrete") {
      throw EvalError.symbolsUnavailable(
        "?ctx....  unsupplied at the root would have to allocate a symbol, which concrete mode cannot represent",
      );
    }
    const id = `#ctx${path.map((p) => `.${p}`).join("")}`;
    ctx.emissions.symbols.push({ id, origin: { t: "demand", path: [...path] }, binding });
    return { t: "symbol", id, path: [] };
  }
}

/** The coercion table a `!` collects by (`v3-symbols.md` §2.2). */
function collectConstraints(v: Value): Value[] {
  if (v.t === "constraint") return [v];
  if (v.t === "array") return v.items.flatMap(collectConstraints);
  throw EvalError.typeMismatch(
    `! expects a constraint or an array of them, got ${describeValue(v)}`,
  );
}

function describeCallee(e: Expr): string {
  return e.t === "Path" ? [e.root, ...e.fields].join(".") : "a call";
}

// Documents ----------------------------------------------------------------

function evalAttribute(ctx: EvalCtx, env: Env, a: Attribute): NodeAttribute {
  if (a.t === "Attr") {
    return { t: "attribute", name: a.name, value: toJson(evalExpr(ctx, env, a.value)) };
  }
  return {
    t: "action",
    event: a.event,
    key: a.key,
    payload: toJson(evalExpr(ctx, env, a.payload)),
  };
}

function evalChildren(ctx: EvalCtx, env: Env, children: Expr[]): Node[] {
  return children.flatMap((e) => childNodes(evalExpr(ctx, env, e)));
}

function childNodes(v: Value): Node[] {
  if (v.t === "node") return [v.node];
  if (v.t === "array") return v.items.flatMap(childNodes);
  return [{ t: "text", value: toJson(v), annotations: noAnnotations() }];
}

// Application ----------------------------------------------------------------

function apply(ctx: EvalCtx, who: string, f: Value, args: Value[]): Value {
  switch (f.t) {
    case "closure": {
      if (f.params.length !== args.length) {
        throw EvalError.typeMismatch(
          `closure expects ${f.params.length} argument(s), got ${args.length}`,
        );
      }
      const env2 = new Map(f.env);
      f.params.forEach((p, i) => env2.set(p, args[i] as Value));
      return evalExpr(ctx, env2, f.body);
    }
    case "builtin":
      return evalBuiltin(f.name, args);
    case "import": {
      const only = args.length === 1 ? args[0] : undefined;
      if (only === undefined) {
        throw EvalError.typeMismatch(
          `${who}: the import of ${JSON.stringify(f.pending.name)} expects exactly 1 argument, the parameters to add`,
        );
      }
      if (only.t !== "object") {
        throw EvalError.typeMismatch(
          `${who}: the import of ${JSON.stringify(f.pending.name)} takes an object of parameters, got ${describeValue(only)}`,
        );
      }
      const params = new Map(f.pending.params);
      for (const [k, v] of only.fields) params.set(k, v);
      return { t: "import", pending: { ...f.pending, params } };
    }
    default:
      throw EvalError.typeMismatch(`${who} is not callable: ${describeValue(f)}`);
  }
}

function evalCollection(ctx: EvalCtx, env: Env, who: string, e: Expr): Value[] {
  const v = evalExpr(ctx, env, e);
  if (v.t === "array") return v.items;
  if (v.t === "symbol") throw EvalError.notConcrete(who);
  throw EvalError.typeMismatch(
    `${who} expects an array as its first argument, got ${describeValue(v)}`,
  );
}

// Concat -----------------------------------------------------------------

/**
 * The monoid operation over the three types that have one. Either side being a
 * symbol is `NotConcrete` (`v3-symbols.md` §1.5), ahead of the generic
 * mismatch: the spine of a concatenation must be known.
 */
function concatValues(l: Value, r: Value): Value {
  if (l.t === "symbol" || r.t === "symbol") throw EvalError.notConcrete("<>");
  if (l.t === "str" && r.t === "str") return { t: "str", value: l.value + r.value };
  if (l.t === "array" && r.t === "array") return { t: "array", items: [...l.items, ...r.items] };
  if (l.t === "object" && r.t === "object") {
    const fields = new Map(l.fields);
    for (const [k, v] of r.fields) fields.set(k, v);
    return { t: "object", fields };
  }
  throw EvalError.concatMismatch(`${describeValue(l)} and ${describeValue(r)}`);
}

// Imports --------------------------------------------------------------------

function forceImport(ctx: EvalCtx, pending: Pending): Value {
  const result = runLibrary(ctx, pending.name, { t: "object", fields: new Map(pending.params) });
  return applyQueued(ctx, pending.queued, result);
}

function runLibrary(ctx: EvalCtx, name: string, ctxVal: Value): Value {
  if (ctx.inProgress.has(name)) throw EvalError.importCycle(name);
  const rawProg = ctx.libs.get(name);
  if (rawProg === undefined) throw EvalError.unknownLibrary(name);
  // The static counterpart of `AllocationInLibrary` (`v3-symbols.md` §6),
  // checked lexically before evaluating anything and deliberately *not*
  // wrapped in `InLibrary`: this is a property of the library's own source.
  if (symbolSites(rawProg).length !== 0) throw EvalError.allocationInLibrary(name);
  const prog = withTypeErrors(() => eraseTypes(ctx.libs, rawProg));
  const ctx2 = enterLibrary(name, ctx);
  try {
    const { statements, root } = unlets(prog.root);
    const libEnv = initialEnv(ctxVal);
    const bindingNames: string[] = [];
    for (const stmt of statements) {
      switch (stmt.t) {
        case "Let":
        // Erasure has already turned an annotated binding into a `Let` plus
        // `Emit` by the time a library's chain gets here; this branch, like
        // `TypeDecl`'s, only guards totality.
        case "Annotate":
          libEnv.set(stmt.name, evalExpr(ctx2, libEnv, stmt.value));
          if (!isHiddenName(stmt.name)) bindingNames.push(stmt.name);
          break;
        // A library's own emissions are collected when a field is read off its
        // import (`v3-symbols.md` §2.3) — which is exactly when this runs.
        case "Emit":
          ctx2.emissions.constraints.push(
            ...collectConstraints(evalExpr(ctx2, libEnv, stmt.constraint)),
          );
          break;
        case "TypeDecl":
        case "TypeEmit":
          break;
      }
    }
    const rendered = evalExpr(ctx2, libEnv, root);
    const vals: Env = new Map();
    for (const n of bindingNames) vals.set(n, libEnv.get(n) as Value);
    const out: Env = new Map();
    out.set("rendered", rendered);
    out.set("vals", { t: "importResult", fields: vals });
    return { t: "importResult", fields: out };
  } catch (e) {
    if (e instanceof EvalError) throw EvalError.inLibrary(name, e);
    throw e;
  }
}

// Action adaptation -----------------------------------------------------------

function adaptValue(
  ctx: EvalCtx,
  adaptation: ActionAdaptation,
  fnVal: Value | null,
  v: Value,
): Value {
  switch (v.t) {
    case "node":
      return {
        t: "node",
        node: mapActions(v.node, (event, key, payload) =>
          adaptAction(ctx, adaptation, fnVal, event, key, payload),
        ),
      };
    case "importResult": {
      const fields: Env = new Map();
      for (const [k, x] of v.fields) fields.set(k, adaptValue(ctx, adaptation, fnVal, x));
      return { t: "importResult", fields };
    }
    case "array":
      return { t: "array", items: v.items.map((x) => adaptValue(ctx, adaptation, fnVal, x)) };
    case "object": {
      const fields: Env = new Map();
      for (const [k, x] of v.fields) fields.set(k, adaptValue(ctx, adaptation, fnVal, x));
      return { t: "object", fields };
    }
    case "import":
      return {
        t: "import",
        pending: { ...v.pending, queued: [...v.pending.queued, { adaptation, fn: fnVal }] },
      };
    default:
      return v;
  }
}

function applyQueued(
  ctx: EvalCtx,
  queued: Array<{ adaptation: ActionAdaptation; fn: Value | null }>,
  v0: Value,
): Value {
  let v = v0;
  for (const q of queued) v = adaptValue(ctx, q.adaptation, q.fn, v);
  return v;
}

function adaptAction(
  ctx: EvalCtx,
  adaptation: ActionAdaptation,
  fnVal: Value | null,
  event: string,
  key: string,
  payload: Json,
): NodeAttribute {
  const key2 = adaptKey(adaptation, key);
  if (fnVal === null) return { t: "action", event, key: key2, payload };
  const actionObj: Env = new Map();
  actionObj.set("eventType", { t: "str", value: event });
  actionObj.set("key", { t: "str", value: key2 });
  actionObj.set("payload", fromJson(payload));
  const result = toJson(
    apply(ctx, "adapt-actions", fnVal, [{ t: "object", fields: actionObj }]),
  );
  if (!isJsonObject(result)) {
    throw EvalError.typeMismatch(
      "adapt-actions: the function must return an object with an eventType field",
    );
  }
  const event2 = getField(result, "eventType");
  if (typeof event2 !== "string") {
    throw EvalError.typeMismatch(
      'adapt-actions: the function\'s result needs a string "eventType" field',
    );
  }
  const payload2 = hasField(result, "payload") ? (result["payload"] as Json) : null;
  return { t: "action", event: event2, key: key2, payload: payload2 };
}

// Paths and fields -----------------------------------------------------------

function walkFields(ctx: EvalCtx, context: string[], v: Value, fields: string[]): Value {
  if (fields.length === 0) return v;
  const field = fields[0] as string;
  const rest = fields.slice(1);
  switch (v.t) {
    case "object":
    case "importResult": {
      const next = v.fields.get(field);
      if (next === undefined) throw EvalError.pathNotFound(context);
      return walkFields(ctx, context, next, rest);
    }
    case "import":
      return walkFields(ctx, context, forceImport(ctx, v.pending), fields);
    // Projection (`v3-symbols.md` §1.6): reads nothing, and is never rejected.
    // Consumes every remaining segment at once, since a projection just
    // extends the path.
    case "symbol":
      return { t: "symbol", id: v.id, path: [...v.path, ...fields] };
    default:
      throw EvalError.typeMismatch(
        `cannot read field ${JSON.stringify(field)} of ${describeValue(v)} in path ${JSON.stringify(context.join("."))}`,
      );
  }
}

// Conversion ------------------------------------------------------------------

/** Down to JSON, at the boundaries where only JSON is meaningful. */
export function toJson(v: Value): Json {
  switch (v.t) {
    case "null":
      return null;
    case "bool":
      return v.value;
    case "number":
      return v.value;
    case "str":
      return v.value;
    case "array":
      return v.items.map(toJson);
    case "object":
      return jsonObjectFrom([...v.fields].map(([k, x]) => [k, toJson(x)] as const));
    case "node":
      throw EvalError.typeMismatch(
        "a document node is not a plain value -- nest it as a child rather than using it where a value is expected",
      );
    case "closure":
      throw EvalError.typeMismatch(
        "expected a value, got a function -- call it first, e.g. $my-fn(...)",
      );
    case "builtin":
      throw EvalError.typeMismatch(
        `expected a value, got the builtin ${JSON.stringify(v.name)} -- call it first`,
      );
    case "importResult":
      throw EvalError.typeMismatch(
        "expected a value, got an import result -- read .rendered, .vals, or a binding name from it first",
      );
    case "import":
      throw EvalError.typeMismatch(
        `expected a value, got the import of ${JSON.stringify(v.pending.name)} -- read .rendered or .vals from it to run it first`,
      );
    // A symbol may sit in an attribute, a payload, a value slot or a text
    // child (`v3-symbols.md` §1.5), so this always succeeds; `requireConcrete`
    // is what refuses one. §5.3's tagged shape: both fields required.
    case "symbol":
      return { $sym: v.id, path: [...v.path] };
    case "constraint":
      throw EvalError.typeMismatch(
        `a constraint (${JSON.stringify(v.name)}) cannot cross a JSON boundary -- only "!" may consume it`,
      );
  }
}

/**
 * Whether a value is, or contains, a symbol (`v3-symbols.md` §1.5, §1.7): a
 * structure built of concrete pieces is itself concrete.
 */
function containsSymbol(v: Value): boolean {
  if (v.t === "symbol") return true;
  if (v.t === "array") return v.items.some(containsSymbol);
  if (v.t === "object") return [...v.fields.values()].some(containsSymbol);
  return false;
}

/**
 * Requires a value with no symbol anywhere in it, for the operations §1.5
 * lists as needing to *know* something about their argument rather than merely
 * carry it: `str`, `eq`, and an allocation key.
 */
function requireConcrete(who: string, v: Value): Json {
  if (containsSymbol(v)) throw EvalError.notConcrete(who);
  return toJson(v);
}

function fromJson(v: Json): Value {
  if (v === null) return { t: "null" };
  if (typeof v === "boolean") return { t: "bool", value: v };
  if (typeof v === "number") return { t: "number", value: v };
  if (typeof v === "string") return { t: "str", value: v };
  if (Array.isArray(v)) return { t: "array", items: v.map(fromJson) };
  const fields: Env = new Map();
  for (const k of ownKeys(v)) fields.set(k, fromJson(v[k] as Json));
  return { t: "object", fields };
}

/**
 * The input context's boundary: as `fromJson`, but recursively refusing
 * `"$sym"` and `"$type"` as ordinary object keys (`v3-symbols.md` §5.3). In
 * symbolic mode, seeding (§5.4) accepts a well-formed `{"$sym": ..., "path":
 * [...]}` back as an actual symbol.
 */
function checkedFromJson(mode: Mode, v: Json): Value {
  if (v === null) return { t: "null" };
  if (typeof v === "boolean") return { t: "bool", value: v };
  if (typeof v === "number") return { t: "number", value: v };
  if (typeof v === "string") return { t: "str", value: v };
  if (Array.isArray(v)) return { t: "array", items: v.map((x) => checkedFromJson(mode, x)) };
  if (hasField(v, "$type")) {
    throw EvalError.typeMismatch(
      'the context carries the reserved key "$type", which only a typed envelope may use',
    );
  }
  if (hasField(v, "$sym")) {
    if (mode === "concrete") {
      throw EvalError.typeMismatch(
        'the context carries the reserved key "$sym", which only a symbolic envelope may use',
      );
    }
    return decodeSymbolRef(v["$sym"] as Json, v);
  }
  const fields: Env = new Map();
  for (const k of ownKeys(v)) fields.set(k, checkedFromJson(mode, v[k] as Json));
  return { t: "object", fields };
}

/**
 * Decodes a `{"$sym": <id>, "path": [<segment>, ...]}` object back into a
 * symbol (`v3-symbols.md` §5.4). Both fields are required, and no other key
 * may be present.
 */
function decodeSymbolRef(symVal: Json, obj: JsonObject): Value {
  const badShape = (): EvalError =>
    EvalError.typeMismatch(
      'a "$sym" object must be exactly {"$sym": <id>, "path": [<segment>, ...]}',
    );
  if (typeof symVal !== "string") throw badShape();
  if (ownKeys(obj).length !== 2) throw badShape();
  const pathArr = getField(obj, "path");
  if (!Array.isArray(pathArr)) throw badShape();
  const path = pathArr.map((x) => {
    if (typeof x !== "string") {
      throw EvalError.typeMismatch(
        'a symbol reference\'s "path" must be an array of strings',
      );
    }
    return x;
  });
  return { t: "symbol", id: symVal, path };
}

function describeValue(v: Value): string {
  switch (v.t) {
    case "null":
      return "null";
    case "bool":
      return "a boolean";
    case "number":
      return "a number";
    case "str":
      return "a string";
    case "array":
      return "an array";
    case "object":
      return "an object";
    case "node":
      return "a document node";
    case "closure":
      return "a function";
    case "builtin":
      return `the builtin ${JSON.stringify(v.name)}`;
    case "importResult":
      return "an import result";
    case "import":
      return `the not-yet-run import of ${JSON.stringify(v.pending.name)}`;
    case "symbol":
      return "a symbol";
    case "constraint":
      return `a constraint (${JSON.stringify(v.name)})`;
  }
}

/** Control flow must be concrete (`v3-symbols.md` §1.5). */
function requireBool(who: string, v: Value): boolean {
  if (v.t === "bool") return v.value;
  if (v.t === "symbol") throw EvalError.notConcrete(who);
  throw EvalError.typeMismatch(`${who} must be a boolean, got ${describeValue(v)}`);
}

// Builtins ------------------------------------------------------------------

function evalBuiltin(name: string, args: Value[]): Value {
  const arityErr = (n: number): EvalError =>
    EvalError.typeMismatch(`${name} expects exactly ${n} argument(s), got ${args.length}`);
  const arg = (i: number): Value => args[i] as Value;
  switch (name) {
    case "cardinality":
    case "count": {
      if (args.length !== 1) throw arityErr(1);
      const a = arg(0);
      if (a.t === "array") return { t: "number", value: a.items.length };
      if (a.t === "object") return { t: "number", value: a.fields.size };
      if (a.t === "symbol") throw EvalError.notConcrete(name);
      throw EvalError.typeMismatch(
        `${name} expects an array or object, got ${describeValue(a)}`,
      );
    }
    case "str": {
      if (args.length !== 1) throw arityErr(1);
      return { t: "str", value: displayString(requireConcrete(name, arg(0))) };
    }
    case "not":
      if (args.length !== 1) throw arityErr(1);
      return { t: "bool", value: !asBool(name, arg(0)) };
    case "and": {
      let acc = true;
      for (const a of args) acc = acc && asBool(name, a);
      return { t: "bool", value: acc };
    }
    case "or": {
      let acc = false;
      for (const a of args) acc = acc || asBool(name, a);
      return { t: "bool", value: acc };
    }
    case "eq": {
      if (args.length !== 2) throw arityErr(2);
      const a = requireConcrete(name, arg(0));
      const b = requireConcrete(name, arg(1));
      return { t: "bool", value: jsonEqual(a, b) };
    }
    case "lt":
    case "lte":
    case "gt":
    case "gte": {
      if (args.length !== 2) throw arityErr(2);
      const a = asNumber(name, arg(0));
      const b = asNumber(name, arg(1));
      const r = name === "lt" ? a < b : name === "lte" ? a <= b : name === "gt" ? a > b : a >= b;
      return { t: "bool", value: r };
    }
    case "has":
      if (args.length !== 2) throw arityErr(2);
      return { t: "bool", value: hasImpl(name, arg(0), arg(1)) };
    case "lookup":
      if (args.length !== 3) throw arityErr(3);
      return lookupImpl(name, arg(0), arg(1), arg(2));
    case "concat":
      return { t: "array", items: args.flatMap((a) => asArray(name, a)) };
    case "append": {
      if (args.length !== 2) throw arityErr(2);
      return { t: "array", items: [...asArray(name, arg(0)), arg(1)] };
    }
    default:
      throw EvalError.unboundName(name);
  }
}

function asBool(name: string, v: Value): boolean {
  if (v.t === "bool") return v.value;
  throw EvalError.typeMismatch(
    `${name} expects a boolean argument, got ${describeValue(v)}`,
  );
}

function asNumber(name: string, v: Value): number {
  if (v.t === "number") return v.value;
  if (v.t === "symbol") throw EvalError.notConcrete(name);
  throw EvalError.typeMismatch(`${name} expects a number argument, got ${describeValue(v)}`);
}

function asArray(name: string, v: Value): Value[] {
  if (v.t === "array") return v.items;
  throw EvalError.typeMismatch(`${name} expects an array argument, got ${describeValue(v)}`);
}

function asIndex(n: number): number | null {
  return Number.isFinite(n) && n >= 0 && Number.isInteger(n) ? n : null;
}

/**
 * Deliberately tolerant: a missing key, an out-of-range index, or a container
 * of the wrong shape all answer `false` — except a symbolic container, which
 * is `NotConcrete` rather than a lie (`v3-symbols.md` §1.5).
 */
function hasImpl(name: string, container: Value, key: Value): boolean {
  if (container.t === "symbol") throw EvalError.notConcrete(name);
  if (container.t === "object" && key.t === "str") return container.fields.has(key.value);
  if (container.t === "array" && key.t === "number") {
    const i = asIndex(key.value);
    return i !== null && i < container.items.length;
  }
  return false;
}

function lookupImpl(name: string, container: Value, key: Value, fallback: Value): Value {
  if (container.t === "symbol") throw EvalError.notConcrete(name);
  if (container.t === "object" && key.t === "str") {
    return container.fields.get(key.value) ?? fallback;
  }
  if (container.t === "array" && key.t === "number") {
    const i = asIndex(key.value);
    if (i === null) return fallback;
    return container.items[i] ?? fallback;
  }
  return fallback;
}
