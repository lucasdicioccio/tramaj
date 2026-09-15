/**
 * Hand-written recursive-descent lexer + parser for the surface syntax
 * (`specs/reference.md` §5, §8; `specs/v3-symbols.md` §1-2; `specs/v4-types.md`
 * §1, §5, §7). Mirrors `tramaj-rs/src/parser.rs`'s grammar, including its
 * "name recognition backtracks; the shape does not" rule for the special forms
 * and the static-position (no-interpolation) restrictions.
 */

import {
  documentProgram,
  expressionProgram,
  numberAllocs,
  type ActionAdaptation,
  type Attribute,
  type Expr,
  type ParamValue,
  type Program,
  type Stmt,
  type TypeConstraintArg,
  type TypeExpr,
} from "./ast.js";

export class ParseError extends Error {
  override readonly name = "ParseError";
}

const SPECIAL_FORM_NAMES = new Set([
  "map",
  "filter",
  "scan",
  "fold",
  "branch",
  "import",
  "adapt-actions",
  "constraint",
]);

/** The five value-domain shapes `v4-types.md` §1 reserves as type primitives. */
const PRIM_NAMES = new Set(["string", "number", "bool", "null", "document"]);

const ALPHABETIC = /\p{Alphabetic}/u;
const ALPHANUMERIC = /[\p{Alphabetic}\p{N}]/u;
const WHITESPACE = /\p{White_Space}/u;
const ASCII_DIGIT = /[0-9]/;
const ASCII_HEXDIGIT = /[0-9a-fA-F]/;

const FAIL = Symbol("parse-fail");
type Attempt<T> = T | typeof FAIL;

type ElementArg =
  | { t: "attr"; value: Attribute }
  | { t: "value"; value: Expr }
  | { t: "child"; value: Expr };

type StringPart = { t: "lit"; value: string } | { t: "interp"; value: Expr };

class P {
  private readonly chars: string[];
  private pos = 0;

  constructor(src: string) {
    this.chars = Array.from(src);
  }

  private err(msg: string): ParseError {
    return new ParseError(`at char ${this.pos}: ${msg}`);
  }

  private eof(): boolean {
    return this.pos >= this.chars.length;
  }

  private peek(): string | undefined {
    return this.chars[this.pos];
  }

  private peekAt(off: number): string | undefined {
    return this.chars[this.pos + off];
  }

  private advance(): string | undefined {
    const c = this.peek();
    if (c === undefined) return undefined;
    this.pos += 1;
    return c;
  }

  /** Full save/restore backtracking around one alternative. */
  private attempt<T>(f: () => T): Attempt<T> {
    const save = this.pos;
    try {
      return f();
    } catch (e) {
      if (e instanceof ParseError) {
        this.pos = save;
        return FAIL;
      }
      throw e;
    }
  }

  private succeeded<T>(v: Attempt<T>): v is T {
    return v !== FAIL;
  }

  // Lexing ---------------------------------------------------------------

  private skipSpaces(): void {
    for (;;) {
      const c = this.peek();
      if (c !== undefined && WHITESPACE.test(c)) {
        this.advance();
      } else if (c === "-" && this.peekAt(1) === "-") {
        while (this.peek() !== undefined && this.peek() !== "\n") this.advance();
      } else {
        return;
      }
    }
  }

  private lexeme<T>(f: () => T): T {
    const v = f();
    this.skipSpaces();
    return v;
  }

  private literal(s: string): void {
    const save = this.pos;
    for (const expected of s) {
      if (this.advance() !== expected) {
        this.pos = save;
        throw this.err(`expected ${JSON.stringify(s)}`);
      }
    }
  }

  private symbol(s: string): void {
    this.lexeme(() => this.literal(s));
  }

  private charLit(c: string): string {
    if (this.peek() === c) {
      this.advance();
      return c;
    }
    throw this.err(`expected ${JSON.stringify(c)}`);
  }

  private rawIdent(): string {
    const c0 = this.peek();
    if (c0 === undefined || !ALPHABETIC.test(c0)) throw this.err("expected an identifier");
    this.advance();
    let s = c0;
    for (;;) {
      const c = this.peek();
      if (c !== undefined && (ALPHANUMERIC.test(c) || c === "_")) {
        s += c;
        this.advance();
      } else if (c === "-") {
        const next = this.peekAt(1);
        if (next !== undefined && (ALPHANUMERIC.test(next) || next === "_")) {
          s += "-";
          this.advance();
        } else {
          return s;
        }
      } else {
        return s;
      }
    }
  }

  private identifier(): string {
    return this.lexeme(() => this.rawIdent());
  }

  private pathTail(): [string, string[]] {
    const root = this.rawIdent();
    return [root, this.dottedPathTail()];
  }

  private dottedPathTail(): string[] {
    const segs: string[] = [];
    for (;;) {
      const save = this.pos;
      if (this.peek() !== ".") return segs;
      this.advance();
      const seg = this.attempt(() => this.rawIdent());
      if (!this.succeeded(seg)) {
        this.pos = save;
        return segs;
      }
      segs.push(seg);
    }
  }

  private fieldAccessSuffix(): string[] {
    return this.dottedPathTail();
  }

  private static applyFieldAccess(base: Expr, segs: string[]): Expr {
    return segs.length === 0 ? base : { t: "FieldAccess", target: base, fields: segs };
  }

  // Static strings ---------------------------------------------------------

  private staticString(): string {
    return this.lexeme(() => {
      this.charLit('"');
      let s = "";
      for (;;) {
        const c = this.peek();
        if (c === undefined || c === '"' || c === "`") break;
        s += c;
        this.advance();
      }
      if (this.peek() !== '"') {
        throw this.err(
          "this position must be a literal string, so it cannot contain an interpolation",
        );
      }
      this.advance();
      return s;
    });
  }

  // String literals ---------------------------------------------------------

  private stringLit(): Expr {
    return this.lexeme(() => {
      this.charLit('"');
      const parts: StringPart[] = [];
      for (;;) {
        const c = this.peek();
        if (c === undefined || c === '"') break;
        if (c === "`") {
          this.advance();
          const e = this.expr();
          this.charLit("`");
          parts.push({ t: "interp", value: e });
        } else {
          parts.push({ t: "lit", value: this.litChunk() });
        }
      }
      this.charLit('"');
      return desugarString(parts);
    });
  }

  private litChunk(): string {
    let s = "";
    for (;;) {
      const c = this.peek();
      if (c === "\\") {
        this.advance();
        s += this.escapeSeq();
      } else if (c !== undefined && c !== '"' && c !== "`") {
        s += c;
        this.advance();
      } else {
        break;
      }
    }
    if (s === "") throw this.err("expected string content");
    return s;
  }

  private escapeSeq(): string {
    const c = this.advance();
    if (c === undefined) throw this.err("unterminated escape sequence");
    switch (c) {
      case "n":
        return "\n";
      case "t":
        return "\t";
      case "r":
        return "\r";
      case "\\":
        return "\\";
      case '"':
        return '"';
      case "`":
        return "`";
      case "0":
        return "\0";
      case "u": {
        this.charLit("{");
        let digits = "";
        for (;;) {
          const d = this.peek();
          if (d !== undefined && ASCII_HEXDIGIT.test(d)) {
            digits += d;
            this.advance();
          } else {
            break;
          }
        }
        if (digits === "") throw this.err("invalid unicode escape");
        this.charLit("}");
        const n = Number.parseInt(digits, 16);
        // Rust's `char::from_u32` rejects surrogates as well as out-of-range
        // code points, and a lone surrogate must not parse here either.
        if (!Number.isFinite(n) || n > 0x10ffff || (n >= 0xd800 && n <= 0xdfff)) {
          throw this.err("invalid unicode escape");
        }
        return String.fromCodePoint(n);
      }
      default:
        throw this.err(`unknown escape sequence: \\${c}`);
    }
  }

  // Literals ------------------------------------------------------------

  private numberLit(): Expr {
    return this.lexeme(() => {
      let intPart = "";
      for (;;) {
        const c = this.peek();
        if (c !== undefined && ASCII_DIGIT.test(c)) {
          intPart += c;
          this.advance();
        } else break;
      }
      if (intPart === "") throw this.err("expected a digit");
      let full = intPart;
      const save = this.pos;
      if (this.peek() === ".") {
        this.advance();
        let frac = "";
        for (;;) {
          const c = this.peek();
          if (c !== undefined && ASCII_DIGIT.test(c)) {
            frac += c;
            this.advance();
          } else break;
        }
        if (frac === "") this.pos = save;
        else full = `${full}.${frac}`;
      }
      const n = Number(full);
      if (Number.isNaN(n)) throw this.err("invalid number literal");
      return { t: "NumberLit", value: n };
    });
  }

  private keywordLit(): Expr {
    const name = this.identifier();
    switch (name) {
      case "true":
        return { t: "BoolLit", value: true };
      case "false":
        return { t: "BoolLit", value: false };
      case "null":
        return { t: "NullLit" };
      default:
        throw this.err("not a literal keyword");
    }
  }

  private arrayLit(): Expr {
    this.symbol("[");
    const elements = this.sepEndBy(",", () => this.expr());
    this.symbol("]");
    return { t: "ArrayLit", elements };
  }

  private objectLit(): Expr {
    this.symbol("{");
    const fields = this.sepEndBy(",", () => this.objEntry());
    this.symbol("}");
    return { t: "ObjectLit", fields };
  }

  private objEntry(): [string, Expr] {
    const explicit = this.attempt(() => this.explicitEntry());
    if (this.succeeded(explicit)) return explicit;
    const k = this.identifier();
    return [k, { t: "Path", root: k, fields: [] }];
  }

  private explicitEntry(): [string, Expr] {
    const k = this.objectKey();
    this.refuseReservedKey(k);
    this.symbol(":");
    return [k, this.expr()];
  }

  private refuseReservedKey(k: string): void {
    if (k === "$sym" || k === "$type") {
      throw this.err(`"${k}" is a reserved key and cannot be used as an object key`);
    }
  }

  private objectKey(): string {
    const s = this.attempt(() => this.staticString());
    return this.succeeded(s) ? s : this.identifier();
  }

  // Sep-end-by helper -----------------------------------------------------

  private sepEndBy<T>(sep: string, item: () => T): T[] {
    const out: T[] = [];
    const first = this.attempt(item);
    if (!this.succeeded(first)) return out;
    out.push(first);
    for (;;) {
      const save = this.pos;
      const sepOk = this.attempt(() => this.symbol(sep));
      if (!this.succeeded(sepOk)) {
        this.pos = save;
        return out;
      }
      const next = this.attempt(item);
      if (!this.succeeded(next)) {
        this.pos = save;
        return out;
      }
      out.push(next);
    }
  }

  // Expressions -----------------------------------------------------------

  private pathExpr(): Expr {
    return this.lexeme(() => {
      this.charLit("$");
      const [root, fields] = this.pathTail();
      return { t: "Path", root, fields };
    });
  }

  /** `?(key)` (`v3-symbols.md` §1.2); `numberAllocs` assigns the real site later. */
  private allocExpr(): Expr {
    this.charLit("?");
    this.symbol("(");
    const key = this.expr();
    this.charLit(")");
    const segs = this.fieldAccessSuffix();
    this.skipSpaces();
    return P.applyFieldAccess({ t: "Alloc", site: 0, key }, segs);
  }

  /** `?ctx.a.b` (`v3-symbols.md` §1.3): the path MUST be rooted at `ctx`. */
  private demandExpr(): Expr {
    return this.lexeme(() => {
      this.charLit("?");
      const root = this.rawIdent();
      if (root !== "ctx") throw this.err("a demand must be rooted at ctx, as in ?ctx.path");
      return { t: "Demand", path: this.dottedPathTail() };
    });
  }

  private callExpr(): Expr {
    this.attempt(() => this.charLit("$"));
    const [root, fields] = this.pathTail();
    this.symbol("(");
    const args = this.sepEndBy(",", () => this.expr());
    this.charLit(")");
    const segs = this.fieldAccessSuffix();
    this.skipSpaces();
    return P.applyFieldAccess({ t: "Call", fn: { t: "Path", root, fields }, args }, segs);
  }

  private lambdaExpr(): Expr {
    this.symbol("(");
    const params = this.sepEndBy(",", () => this.identifier());
    this.symbol(")");
    this.symbol("=>");
    return { t: "Lambda", params, body: this.expr() };
  }

  private parenExpr(): Expr {
    this.symbol("(");
    const e = this.expr();
    this.symbol(")");
    return e;
  }

  /**
   * Soft recognition only: consumes the name (and trailing whitespace) iff it
   * is one of the recognized special forms; otherwise fully restores.
   */
  private trySpecialFormName(): string | null {
    const save = this.pos;
    this.attempt(() => this.charLit("$"));
    const n = this.attempt(() => this.identifier());
    if (this.succeeded(n) && SPECIAL_FORM_NAMES.has(n)) return n;
    this.pos = save;
    return null;
  }

  /**
   * Once the name is recognized the shape does not backtrack: any error here
   * is a hard parse error (`reference.md` §5).
   */
  private specialFormShape(name: string): Expr {
    let base: Expr;
    switch (name) {
      case "map": {
        const [collection, fn] = this.binaryShape();
        base = { t: "Map", collection, fn };
        break;
      }
      case "filter": {
        const [collection, fn] = this.binaryShape();
        base = { t: "Filter", collection, fn };
        break;
      }
      case "scan": {
        const [collection, initial, fn] = this.ternaryShape();
        base = { t: "Scan", collection, initial, fn };
        break;
      }
      case "fold": {
        const [collection, initial, fn] = this.ternaryShape();
        base = { t: "Fold", collection, initial, fn };
        break;
      }
      case "branch":
        base = this.branchShape();
        break;
      case "import":
        base = this.importShape();
        break;
      case "adapt-actions":
        base = this.adaptActionsShape();
        break;
      case "constraint":
        base = this.constraintShape();
        break;
      default:
        throw this.err("unrecognized special form");
    }
    const segs = this.fieldAccessSuffix();
    this.skipSpaces();
    return P.applyFieldAccess(base, segs);
  }

  private binaryShape(): [Expr, Expr] {
    this.symbol("(");
    const a = this.expr();
    this.symbol(",");
    const b = this.expr();
    this.charLit(")");
    return [a, b];
  }

  private ternaryShape(): [Expr, Expr, Expr] {
    this.symbol("(");
    const a = this.expr();
    this.symbol(",");
    const b = this.expr();
    this.symbol(",");
    const c = this.expr();
    this.charLit(")");
    return [a, b, c];
  }

  private branchShape(): Expr {
    this.symbol("(");
    const fallback = this.expr();
    const arms: Array<[Expr, Expr]> = [];
    for (;;) {
      const save = this.pos;
      const sepOk = this.attempt(() => this.symbol(","));
      if (!this.succeeded(sepOk)) {
        this.pos = save;
        break;
      }
      const arm = this.attempt(() => this.branchArm());
      if (!this.succeeded(arm)) {
        this.pos = save;
        break;
      }
      arms.push(arm);
    }
    this.attempt(() => this.symbol(","));
    this.charLit(")");
    let acc = fallback;
    for (let i = arms.length - 1; i >= 0; i -= 1) {
      const [condition, then] = arms[i] as [Expr, Expr];
      acc = { t: "Branch", condition, then, else: acc };
    }
    return acc;
  }

  private branchArm(): [Expr, Expr] {
    const p = this.expr();
    this.symbol(",");
    return [p, this.expr()];
  }

  private importShape(): Expr {
    this.symbol("(");
    const name = this.staticString();
    this.symbol(",");
    const params = this.importParams();
    this.charLit(")");
    return { t: "Import", name, params };
  }

  private importParams(): Array<[string, ParamValue]> {
    this.symbol("{");
    const entries = this.sepEndBy(",", () => this.paramEntry());
    this.symbol("}");
    return entries;
  }

  private paramEntry(): [string, ParamValue] {
    const explicit = this.attempt(() => this.explicitParam());
    if (this.succeeded(explicit)) return explicit;
    const k = this.identifier();
    return [k, { t: "PExpr", expr: { t: "Path", root: k, fields: [] } }];
  }

  private explicitParam(): [string, ParamValue] {
    const k = this.objectKey();
    this.symbol(":");
    return [k, this.paramValue()];
  }

  private paramValue(): ParamValue {
    const marked = this.attempt(() => this.markedTypeExpr());
    if (this.succeeded(marked)) return { t: "PType", type: marked };
    const fromCtx = this.attempt(() => this.ctxParam());
    if (this.succeeded(fromCtx)) return fromCtx;
    return { t: "PExpr", expr: this.expr() };
  }

  // Types ---------------------------------------------------------------

  private typeExpr(): TypeExpr {
    const v = this.attempt(() => this.typeVar());
    if (this.succeeded(v)) return v;
    const u = this.attempt(() => this.typeUnion());
    if (this.succeeded(u)) return u;
    const a = this.attempt(() => this.typeArray());
    if (this.succeeded(a)) return a;
    const r = this.attempt(() => this.typeRecord());
    if (this.succeeded(r)) return r;
    return this.typePrimOrRef();
  }

  /**
   * Deliberately narrower than `typeExpr`: a bare name is excluded because
   * nothing marks where a nullary arm ends (`| Dev | Staging` is two arms).
   */
  private typeExprPayload(): TypeExpr {
    const v = this.attempt(() => this.typeVar());
    if (this.succeeded(v)) return v;
    const a = this.attempt(() => this.typeArray());
    if (this.succeeded(a)) return a;
    return this.typeRecord();
  }

  private typeVar(): TypeExpr {
    return this.lexeme(() => {
      this.charLit("%");
      const root = this.rawIdent();
      if (root !== "ctx") throw this.err("a type hole must be rooted at ctx, as in %ctx.path");
      return { t: "Var", path: this.dottedPathTail() };
    });
  }

  /**
   * A `%`-marked type argument (`v4-types.md` §2, §5). Unlike `typeVar` the
   * leading `%` does not require what follows to be `ctx`.
   */
  private markedTypeExpr(): TypeExpr {
    this.charLit("%");
    const f = this.attempt(() => this.ctxForward());
    if (this.succeeded(f)) return f;
    const u = this.attempt(() => this.typeUnion());
    if (this.succeeded(u)) return u;
    const a = this.attempt(() => this.typeArray());
    if (this.succeeded(a)) return a;
    const r = this.attempt(() => this.typeRecord());
    if (this.succeeded(r)) return r;
    return this.typePrimOrRef();
  }

  private ctxForward(): TypeExpr {
    return this.lexeme(() => {
      const root = this.rawIdent();
      if (root !== "ctx") throw this.err("a %-marked value must be ctx.path or a type expression");
      return { t: "Var", path: this.dottedPathTail() };
    });
  }

  private typeArray(): TypeExpr {
    this.symbol("[");
    const element = this.typeExpr();
    this.symbol("]");
    return { t: "Array", element };
  }

  private typeRecord(): TypeExpr {
    this.symbol("{");
    const fields = this.sepEndBy(",", () => this.typeField());
    this.symbol("}");
    return { t: "Record", fields };
  }

  /**
   * A field name here is always a bare identifier, never a quoted string —
   * what keeps `types.canonicalId` injective, since the id grammar's own
   * delimiters can never appear in one.
   */
  private typeField(): [string, TypeExpr] {
    const k = this.identifier();
    this.symbol(":");
    return [k, this.typeExpr()];
  }

  private typeUnion(): TypeExpr {
    this.symbol("|");
    const arms: Array<[string, TypeExpr | null]> = [this.unionArm()];
    for (;;) {
      const save = this.pos;
      const barOk = this.attempt(() => this.symbol("|"));
      if (!this.succeeded(barOk)) {
        this.pos = save;
        break;
      }
      arms.push(this.unionArm());
    }
    return { t: "Union", arms };
  }

  private unionArm(): [string, TypeExpr | null] {
    const name = this.identifier();
    const payload = this.attempt(() => this.typeExprPayload());
    return [name, this.succeeded(payload) ? payload : null];
  }

  private typePrimOrRef(): TypeExpr {
    const r = this.attempt(() => this.typeLibRef());
    if (this.succeeded(r)) return r;
    return this.typeNameOrPrim();
  }

  private typeLibRef(): TypeExpr {
    return this.lexeme(() => {
      this.charLit("$");
      const lib = this.rawIdent();
      this.charLit(".");
      this.literal("types");
      this.charLit(".");
      const name = this.rawIdent();
      return { t: "LibRef", lib, name };
    });
  }

  private typeNameOrPrim(): TypeExpr {
    const name = this.identifier();
    return PRIM_NAMES.has(name) ? { t: "Prim", name } : { t: "Name", name };
  }

  private typeConstraintArg(): TypeConstraintArg {
    const marked = this.attempt(() => this.markedTypeExpr());
    if (this.succeeded(marked)) return { t: "Type", type: marked };
    return this.scalarArg();
  }

  private scalarArg(): TypeConstraintArg {
    const s = this.attempt(() => this.staticString());
    if (this.succeeded(s)) return { t: "ScalarStr", value: s };
    const n = this.attempt(() => this.numberLit());
    if (this.succeeded(n)) return asScalarArg(n);
    const k = this.attempt(() => this.keywordLit());
    if (this.succeeded(k)) return asScalarArg(k);
    throw this.err("expected a type-constraint argument");
  }

  /**
   * `!type-constraint(name, args...)` (`v4-types.md` §5): tried before the
   * general `!expr` emission, since both share the `!` leader.
   */
  private typeEmission(): Stmt {
    this.charLit("!");
    const kw = this.identifier();
    if (kw !== "type-constraint") throw this.err("not a !type-constraint");
    this.symbol("(");
    const name = this.staticString();
    const args: TypeConstraintArg[] = [];
    for (;;) {
      const save = this.pos;
      const sepOk = this.attempt(() => this.symbol(","));
      if (!this.succeeded(sepOk)) {
        this.pos = save;
        break;
      }
      const a = this.attempt(() => this.typeConstraintArg());
      if (!this.succeeded(a)) {
        this.pos = save;
        break;
      }
      args.push(a);
    }
    this.attempt(() => this.symbol(","));
    this.charLit(")");
    this.skipSpaces();
    return { t: "TypeEmit", name, args };
  }

  /** `type Name = TypeExpr` (`v4-types.md` §1.1): a keyword leader, not a character. */
  private typeDeclStmt(): Stmt {
    const kw = this.identifier();
    if (kw !== "type") throw this.err("not a type declaration");
    const name = this.identifier();
    this.symbol("=");
    return { t: "TypeDecl", name, type: this.typeExpr() };
  }

  private ctxParam(): ParamValue {
    const save = this.pos;
    const n = this.identifier();
    if (n !== "ctx" || this.peek() !== "(") {
      this.pos = save;
      throw this.err("not a ctx(...) parameter");
    }
    this.symbol("(");
    const [root, fields] = this.pathTail();
    this.skipSpaces();
    this.charLit(")");
    this.skipSpaces();
    return { t: "PFromContext", path: [root, ...fields] };
  }

  /** `constraint(name, args...)` (`v3-symbols.md` §2.1): a static name, then any number of expressions. */
  private constraintShape(): Expr {
    this.symbol("(");
    const name = this.staticString();
    const args: Expr[] = [];
    for (;;) {
      const save = this.pos;
      const sepOk = this.attempt(() => this.symbol(","));
      if (!this.succeeded(sepOk)) {
        this.pos = save;
        break;
      }
      const a = this.attempt(() => this.expr());
      if (!this.succeeded(a)) {
        this.pos = save;
        break;
      }
      args.push(a);
    }
    this.attempt(() => this.symbol(","));
    this.charLit(")");
    return { t: "Constrain", name, args };
  }

  private adaptActionsShape(): Expr {
    this.symbol("(");
    const target = this.expr();
    this.symbol(",");
    const adaptation = this.adaptationShape();
    const fn = this.attempt(() => {
      this.symbol(",");
      return this.expr();
    });
    this.attempt(() => this.symbol(","));
    this.charLit(")");
    return { t: "AdaptActions", target, adaptation, fn: this.succeeded(fn) ? fn : null };
  }

  private adaptationShape(): ActionAdaptation {
    const name = this.identifier();
    if (name === "identity") return { t: "Identity" };
    if (name === "prefix") {
      this.symbol("(");
      const prefix = this.staticString();
      this.charLit(")");
      this.skipSpaces();
      return { t: "Prefix", prefix };
    }
    throw this.err('an action adaptation must be identity or prefix("...")');
  }

  // Documents ---------------------------------------------------------------

  private documentExpr(): Expr {
    this.charLit(".");
    const frag = this.attempt(() => this.fragmentShape());
    if (this.succeeded(frag)) return frag;
    return this.elementShape();
  }

  private fragmentShape(): Expr {
    this.symbol("(");
    const children = this.sepEndBy(",", () => this.expr());
    this.symbol(")");
    return { t: "Fragment", children };
  }

  private elementShape(): Expr {
    const tag = this.rawIdent();
    this.skipSpaces();
    this.symbol("(");
    const args = this.sepEndBy(",", () => this.elementArg());
    this.symbol(")");
    return this.buildElement(tag, args);
  }

  private elementArg(): ElementArg {
    const positional = this.tryAttributePositionArg();
    if (positional !== null) return positional;
    const named = this.attempt(() => this.namedArg());
    if (this.succeeded(named)) return { t: "attr", value: named };
    return { t: "child", value: this.expr() };
  }

  /** `action(...)`/`value(...)`: soft name+lookahead recognition, then a hard-committed shape. */
  private tryAttributePositionArg(): ElementArg | null {
    const save = this.pos;
    const n = this.attempt(() => this.identifier());
    if (!this.succeeded(n)) {
      this.pos = save;
      return null;
    }
    if (this.peek() !== "(" || (n !== "action" && n !== "value")) {
      this.pos = save;
      return null;
    }
    return n === "action"
      ? { t: "attr", value: this.actionShape() }
      : { t: "value", value: this.valueShape() };
  }

  private actionShape(): Attribute {
    this.symbol("(");
    const event = this.staticString();
    this.symbol(",");
    const key = this.staticString();
    this.symbol(",");
    const payload = this.expr();
    this.symbol(")");
    return { t: "ActionAttr", event, key, payload };
  }

  private valueShape(): Expr {
    this.symbol("(");
    const v = this.expr();
    this.symbol(")");
    return v;
  }

  private namedArg(): Attribute {
    const name = this.objectKey();
    this.symbol(":");
    return { t: "Attr", name, value: this.expr() };
  }

  private buildElement(tag: string, args: ElementArg[]): Expr {
    let seenChild = false;
    for (const arg of args) {
      if (arg.t === "child") seenChild = true;
      else if (seenChild) {
        throw this.err(
          "attributes, action(...) and value(...) must all come before an element's children",
        );
      }
    }
    const values = args.flatMap((a) => (a.t === "value" ? [a.value] : []));
    const attributes = args.flatMap((a) => (a.t === "attr" ? [a.value] : []));
    const children = args.flatMap((a) => (a.t === "child" ? [a.value] : []));
    if (values.length > 1) throw this.err("an element can have at most one value(...)");
    const value: Expr = values.length === 1 ? (values[0] as Expr) : { t: "NullLit" };
    return { t: "Element", tag, attributes, value, children };
  }

  // Precedence ---------------------------------------------------------------

  private expr(): Expr {
    let acc = this.operand();
    for (;;) {
      const save = this.pos;
      const rhs = this.attempt(() => {
        this.symbol("<>");
        return this.operand();
      });
      if (!this.succeeded(rhs)) {
        this.pos = save;
        return acc;
      }
      acc = { t: "Concat", left: acc, right: rhs };
    }
  }

  private operand(): Expr {
    const alternatives: Array<() => Expr> = [
      () => this.keywordLit(),
      () => this.lambdaExpr(),
      () => this.parenExpr(),
    ];
    for (const alt of alternatives) {
      const v = this.attempt(alt);
      if (this.succeeded(v)) return v;
    }
    const special = this.trySpecialFormName();
    if (special !== null) return this.specialFormShape(special);
    const rest: Array<() => Expr> = [
      () => this.callExpr(),
      () => this.pathExpr(),
      () => this.allocExpr(),
      () => this.demandExpr(),
      () => this.documentExpr(),
      () => this.stringLit(),
      () => this.numberLit(),
      () => this.arrayLit(),
      () => this.objectLit(),
    ];
    for (const alt of rest) {
      const v = this.attempt(alt);
      if (this.succeeded(v)) return v;
    }
    throw this.err("expected an expression");
  }

  // Programs -----------------------------------------------------------------

  /** `@name=expr` or `@name : T = expr` (`v4-types.md` §7). */
  private binding(): Stmt {
    this.charLit("@");
    const name = this.identifier();
    const annot = this.attempt(() => {
      this.symbol(":");
      return this.typeExpr();
    });
    this.symbol("=");
    const value = this.expr();
    return this.succeeded(annot)
      ? { t: "Annotate", name, type: annot, value }
      : { t: "Let", name, value };
  }

  /** `!expr` (`v3-symbols.md` §2.2): a statement position only. */
  private emissionStmt(): Expr {
    this.charLit("!");
    return this.expr();
  }

  program(): Program {
    this.skipSpaces();
    const statements: Stmt[] = [];
    for (;;) {
      const b = this.attempt(() => this.binding());
      if (this.succeeded(b)) {
        statements.push(b);
        continue;
      }
      const te = this.attempt(() => this.typeEmission());
      if (this.succeeded(te)) {
        statements.push(te);
        continue;
      }
      const em = this.attempt(() => this.emissionStmt());
      if (this.succeeded(em)) {
        statements.push({ t: "Emit", constraint: em });
        continue;
      }
      const td = this.attempt(() => this.typeDeclStmt());
      if (this.succeeded(td)) {
        statements.push(td);
        continue;
      }
      break;
    }
    const root = this.expr();
    this.skipSpaces();
    if (!this.eof()) throw this.err("unexpected trailing input");
    const isDocument = root.t === "Element" || root.t === "Fragment";
    let body = root;
    for (let i = statements.length - 1; i >= 0; i -= 1) {
      const stmt = statements[i] as Stmt;
      switch (stmt.t) {
        case "Let":
          body = { t: "Let", name: stmt.name, value: stmt.value, body };
          break;
        case "Emit":
          body = { t: "Emit", constraint: stmt.constraint, body };
          break;
        case "TypeDecl":
          body = { t: "TypeDecl", name: stmt.name, type: stmt.type, body };
          break;
        case "Annotate":
          body = { t: "TypeAnnotate", name: stmt.name, type: stmt.type, value: stmt.value, body };
          break;
        case "TypeEmit":
          body = { t: "TypeEmit", name: stmt.name, args: stmt.args, body };
          break;
      }
    }
    numberAllocs(body);
    return isDocument ? documentProgram(body) : expressionProgram(body);
  }
}

function asScalarArg(e: Expr): TypeConstraintArg {
  switch (e.t) {
    case "NumberLit":
      return { t: "ScalarNum", value: e.value };
    case "BoolLit":
      return { t: "ScalarBool", value: e.value };
    case "StringLit":
      return { t: "ScalarStr", value: e.value };
    default:
      return { t: "ScalarNull" };
  }
}

function desugarString(parts: StringPart[]): Expr {
  const coalesced = coalesce(parts);
  const first = coalesced[0];
  if (first === undefined) return { t: "StringLit", value: "" };
  let acc = partExpr(first);
  for (let i = 1; i < coalesced.length; i += 1) {
    acc = { t: "Concat", left: acc, right: partExpr(coalesced[i] as StringPart) };
  }
  return acc;
}

function partExpr(p: StringPart): Expr {
  return p.t === "lit"
    ? { t: "StringLit", value: p.value }
    : { t: "Call", fn: { t: "Path", root: "str", fields: [] }, args: [p.value] };
}

function coalesce(parts: StringPart[]): StringPart[] {
  const out: StringPart[] = [];
  for (const part of parts) {
    const last = out[out.length - 1];
    if (last !== undefined && last.t === "lit" && part.t === "lit") {
      out[out.length - 1] = { t: "lit", value: last.value + part.value };
    } else {
      out.push(part);
    }
  }
  return out;
}

export function parseProgram(src: string): Program {
  return new P(src).program();
}

/** `parseProgram`, returning the error rather than throwing it. */
export function tryParseProgram(src: string): { ok: true; program: Program } | { ok: false; error: ParseError } {
  try {
    return { ok: true, program: parseProgram(src) };
  } catch (e) {
    if (e instanceof ParseError) return { ok: false, error: e };
    throw e;
  }
}
