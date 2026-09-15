/**
 * The ordinary JSON value domain (`specs/node-json.md`), plus the handful of
 * operations the rest of the port needs over it: order-insensitive structural
 * equality, and `specs/reference.md` §6's normative `str` rendering.
 */

export type Json = null | boolean | number | string | Json[] | JsonObject;

export interface JsonObject {
  [key: string]: Json;
}

export function isJsonObject(v: Json): v is JsonObject {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Own-property read, so a JSON object's inherited `constructor`/`toString` never answers. */
export function getField(o: JsonObject, key: string): Json | undefined {
  return Object.prototype.hasOwnProperty.call(o, key) ? o[key] : undefined;
}

export function hasField(o: JsonObject, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(o, key);
}

export function ownKeys(o: JsonObject): string[] {
  return Object.keys(o);
}

/**
 * Builds an object from dynamic keys without `__proto__` reaching the
 * prototype setter, which a plain assignment would.
 */
export function jsonObjectFrom(entries: Iterable<readonly [string, Json]>): JsonObject {
  const out: JsonObject = {};
  for (const [k, v] of entries) {
    Object.defineProperty(out, k, { value: v, enumerable: true, writable: true, configurable: true });
  }
  return out;
}

export function jsonEqual(a: Json, b: Json): boolean {
  if (a === b) return true;
  if (typeof a === "number" && typeof b === "number") return a === b;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    return a.every((x, i) => jsonEqual(x, b[i] as Json));
  }
  if (isJsonObject(a) && isJsonObject(b)) {
    const ka = ownKeys(a);
    const kb = ownKeys(b);
    if (ka.length !== kb.length) return false;
    return ka.every((k) => hasField(b, k) && jsonEqual(a[k] as Json, b[k] as Json));
  }
  return false;
}

/**
 * `specs/reference.md` §6's number rendering is "exactly as ECMAScript's
 * `Number::toString`", which `String` already is.
 */
export function formatNumber(n: number): string {
  return String(n);
}

export function quoteString(s: string): string {
  return JSON.stringify(s);
}

/** Compact JSON with object keys sorted (`specs/reference.md` §6). */
export function compactJson(v: Json): string {
  if (v === null) return "null";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return formatNumber(v);
  if (typeof v === "string") return quoteString(v);
  if (Array.isArray(v)) return `[${v.map(compactJson).join(",")}]`;
  const keys = ownKeys(v).sort(compareStrings);
  return `{${keys.map((k) => `${quoteString(k)}:${compactJson(v[k] as Json)}`).join(",")}}`;
}

/** `str`'s rendering (`specs/reference.md` §6): raw at the top level, compact below it. */
export function displayString(v: Json): string {
  if (v === null) return "";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return formatNumber(v);
  if (typeof v === "string") return v;
  return compactJson(v);
}

export function compareStrings(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
