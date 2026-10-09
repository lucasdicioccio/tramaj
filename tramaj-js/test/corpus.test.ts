/**
 * Runs the shared cross-implementation corpus at `corpus/cases` (see
 * `corpus/README.md`), the TypeScript counterpart of `tramaj-rs/tests/corpus.rs`,
 * `tramaj-hs/test/unit/Tramaj/CorpusSpec.hs` and `tramaj/test/Test/Corpus.purs`.
 * A case here is JSON-value equality between independently written
 * implementations, not merely "this implementation agrees with itself".
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import {
  contextHoles,
  arithmeticOps,
  contextReads,
  deepActionKeys,
  deepArithmeticOps,
  deepContextHoles,
  staticActionKeys,
  staticImportNames,
  transitiveImportNames,
} from "../src/analysis.js";
import { EvalError, runProgramWith, type LibraryTable, type Mode, type Options } from "../src/eval.js";
import { jsonEqual, parseJson, stringify, type Json } from "../src/json.js";
import { ParseError, parseProgram } from "../src/parser.js";
import type { Program } from "../src/ast.js";

interface CaseMeta {
  name: string;
  /** Absent in an `"expect": "analysis"` case, which evaluates nothing. */
  mode?: string;
  expect?: string;
  errorKind?: string;
  profiles?: string[];
  /** The key `profiles` replaced; a case that still has it is refused. */
  requires?: unknown;
}

/**
 * The profiles (`profiles` in `meta.json`, see corpus/README.md) this port can
 * provide. A case naming any other one is skipped. `base` is the language
 * without any profile. `int-float` says integers and floats are two types,
 * and `int53` that the integer range is the guaranteed one, `-(2^53 - 1)` to
 * `2^53 - 1` (reference.md §13), so a case that needs `int64` is skipped.
 * `arithmetic` is the arithmetic profile: it is an option of each evaluation,
 * and `runCase` turns it on only for a case that lists it. `sort`,
 * `format-number` and `round` are transition tags for the two sort forms, the
 * `format-number` builtin and the tenth arithmetic name (decisions §20).
 */
const providedProfiles: ReadonlySet<string> = new Set([
  "base",
  "int-float",
  "arithmetic",
  "int53",
  "sort",
  "format-number",
  "round",
]);

/**
 * The profiles every port provides (corpus/README.md). A case naming one that
 * `providedProfiles` lacks fails instead of being skipped.
 */
const requiredProfiles: ReadonlySet<string> = new Set(["int-float", "arithmetic"]);

/**
 * The static analyses (reference.md §9) this port provides to an
 * `"expect": "analysis"` case, by the name `analysis.json` gives them. A case
 * naming any other one is skipped.
 */
const providedAnalyses: ReadonlyMap<string, (libs: LibraryTable, prog: Program) => unknown[]> = new Map<
  string,
  (libs: LibraryTable, prog: Program) => unknown[]
>([
  ["staticImportNames", (_libs, prog) => staticImportNames(prog)],
  ["transitiveImportNames", (libs, prog) => transitiveImportNames(libs, prog)],
  ["staticActionKeys", (_libs, prog) => staticActionKeys(prog)],
  ["deepActionKeys", (libs, prog) => deepActionKeys(libs, prog)],
  ["contextHoles", (_libs, prog) => contextHoles(prog)],
  ["deepContextHoles", (libs, prog) => deepContextHoles(libs, prog)],
  ["contextReads", (_libs, prog) => contextReads(prog)],
  ["arithmeticOps", (_libs, prog) => arithmeticOps(prog)],
  ["deepArithmeticOps", (libs, prog) => deepArithmeticOps(libs, prog)],
]);

/**
 * `analysis.json` of an `"expect": "analysis"` case: the expected result of
 * each named analysis. It holds no number, so reading it before deciding to
 * skip is safe on every port.
 */
function readExpectedAnalyses(dir: string): Record<string, unknown[]> {
  return JSON.parse(readFileSync(join(dir, "analysis.json"), "utf8")) as Record<string, unknown[]>;
}

/**
 * What a case names that this port does not provide: profiles, and for an
 * `"expect": "analysis"` case the analyses, written `analysis <name>`.
 */
function missingFor(dir: string, meta: CaseMeta): string[] {
  const missing = (meta.profiles ?? []).filter((r) => !providedProfiles.has(r));
  if (meta.expect === "analysis") {
    for (const name of Object.keys(readExpectedAnalyses(dir))) {
      if (!providedAnalyses.has(name)) missing.push(`analysis ${name}`);
    }
  }
  return missing;
}

function readMeta(dir: string): CaseMeta {
  return JSON.parse(readFileSync(join(dir, "meta.json"), "utf8")) as CaseMeta;
}

/** Registers one case, as a skipped test when it names something this port does not provide. */
function registerCase(dir: string, meta: CaseMeta): void {
  if (meta.requires !== undefined) {
    it(meta.name, () => {
      throw new Error('"requires" was replaced by "profiles" (corpus/README.md)');
    });
    return;
  }
  const missing = missingFor(dir, meta);
  const required = missing.filter((r) => requiredProfiles.has(r));
  if (required.length > 0) {
    it(meta.name, () => {
      throw new Error(`not provided, but required of every port: ${required.join(", ")}`);
    });
    return;
  }
  if (missing.length > 0) {
    it.skip(`${meta.name} (not provided: ${missing.join(", ")})`, () => {});
    return;
  }
  it(meta.name, () => {
    if (meta.expect === "analysis") runAnalysisCase(dir);
    else runCase(dir, meta);
  });
}

/**
 * An `"expect": "analysis"` case: no context and no evaluation. Each named
 * analysis runs over the parsed template (and `libs/`, for a deep variant) and
 * its result is compared, as a set, with the array `analysis.json` gives.
 */
function runAnalysisCase(dir: string): void {
  const prog = parseProgram(readFileSync(join(dir, "template.tramaj"), "utf8"));
  const libs = readLibs(dir);
  // Each element as its JSON text, so names and paths compare the same way.
  const asSet = (xs: unknown[]): string[] => [...new Set(xs.map((x) => JSON.stringify(x)))].sort();
  for (const [name, want] of Object.entries(readExpectedAnalyses(dir))) {
    const analysis = providedAnalyses.get(name);
    if (analysis === undefined) throw new Error(`unknown analysis ${name}`);
    const wantSet = asSet(want);
    // A repeated element is refused: the file is a set.
    if (wantSet.length !== want.length) throw new Error(`analysis.json: ${name} repeats an element`);
    expect({ [name]: asSet(analysis(libs, prog)) }).toEqual({ [name]: wantSet });
  }
}

/** `corpus/cases` lives at the repo root — walk upward until it is found. */
function findCorpusRoot(): string {
  let dir = dirname(fileURLToPath(import.meta.url));
  for (;;) {
    const candidate = join(dir, "corpus", "cases");
    try {
      if (statSync(candidate).isDirectory()) return candidate;
    } catch {
      // keep walking
    }
    const parent = resolve(dir, "..");
    if (parent === dir) throw new Error("could not locate corpus/cases above the test directory");
    dir = parent;
  }
}

/**
 * `ctx.json` and `expected.json`, read with the parser that types a number by
 * its text, so that `3` and `3.0` stay two values (corpus/README.md).
 */
function readJsonFile(path: string): Json {
  return parseJson(readFileSync(path, "utf8"));
}

function readLibs(dir: string): LibraryTable {
  const table: LibraryTable = new Map();
  const libsDir = join(dir, "libs");
  let entries: string[];
  try {
    if (!statSync(libsDir).isDirectory()) return table;
    entries = readdirSync(libsDir);
  } catch {
    return table;
  }
  for (const entry of entries) {
    if (!entry.endsWith(".tramaj")) continue;
    const name = entry.slice(0, -".tramaj".length);
    table.set(name, parseProgram(readFileSync(join(libsDir, entry), "utf8")));
  }
  return table;
}

function modeFromMeta(m: string | undefined): Mode {
  if (m === "concrete" || m === "symbolic") return m;
  throw new Error(`unknown mode ${m}`);
}

function parseOrThrow(src: string): Program {
  return parseProgram(src);
}

function runCase(dir: string, meta: CaseMeta): void {
  // The arithmetic profile is on only for a case that lists it: every other
  // case runs with the arithmetic names unbound.
  const options: Options = {
    mode: modeFromMeta(meta.mode),
    arithmetic: (meta.profiles ?? []).includes("arithmetic"),
  };
  const src = readFileSync(join(dir, "template.tramaj"), "utf8");
  const expectKind = meta.expect ?? "success";

  if (expectKind === "parse-error") {
    let parsed = false;
    try {
      parseOrThrow(src);
      parsed = true;
    } catch (e) {
      if (!(e instanceof ParseError)) throw e;
    }
    if (parsed) throw new Error("expected a parse error, but the template parsed");
    return;
  }

  const libs = readLibs(dir);
  const ctx = readJsonFile(join(dir, "ctx.json"));
  const prog = parseOrThrow(src);

  if (expectKind === "eval-error") {
    const errorKind = meta.errorKind;
    if (errorKind === undefined) throw new Error("eval-error case needs errorKind");
    let succeeded = false;
    try {
      runProgramWith(options, libs, ctx, prog);
      succeeded = true;
    } catch (e) {
      if (!(e instanceof EvalError)) throw e;
      if (e.kind !== errorKind) {
        throw new Error(`expected eval error ${errorKind}, got ${e.kind} (${e.message})`);
      }
    }
    if (succeeded) {
      throw new Error(`expected eval error ${errorKind}, but evaluation succeeded`);
    }
    return;
  }

  if (expectKind !== "success") throw new Error(`unknown expect ${expectKind}`);

  const expected = readJsonFile(join(dir, "expected.json"));
  const actual = runProgramWith(options, libs, ctx, prog);
  if (!jsonEqual(actual, expected)) {
    expect(stringify(actual, 2)).toEqual(stringify(expected, 2));
    throw new Error("output mismatch");
  }
}

const corpusRoot = findCorpusRoot();

const caseDirs = readdirSync(corpusRoot)
  .map((name) => join(corpusRoot, name))
  .filter((p) => statSync(p).isDirectory())
  .sort();

const cases = caseDirs.map((dir) => ({ dir, meta: readMeta(dir) }));

describe("shared corpus", () => {
  it("finds cases", () => {
    expect(cases.length).toBeGreaterThan(0);
  });

  for (const mode of ["concrete", "symbolic"] as const) {
    describe(mode, () => {
      const subset = cases.filter((c) => c.meta.mode === mode);
      it(`has ${mode} cases`, () => {
        expect(subset.length).toBeGreaterThan(0);
      });
      for (const c of subset) registerCase(c.dir, c.meta);
    });
  }

  // Everything else: the `"expect": "analysis"` cases, which have no mode,
  // and a case whose mode is unknown, which fails when it runs.
  describe("analysis", () => {
    const subset = cases.filter((c) => c.meta.mode !== "concrete" && c.meta.mode !== "symbolic");
    for (const c of subset) registerCase(c.dir, c.meta);
  });
});

// corpus/runner-checks/unsupported-profile would fail if it ran: its
// expected.json does not match what the template evaluates to.
describe("a case naming a profile this port does not provide", () => {
  const dir = join(dirname(corpusRoot), "runner-checks", "unsupported-profile");
  const meta = readMeta(dir);
  registerCase(dir, meta);

  it("is registered as skipped", (ctx) => {
    expect(missingFor(dir, meta)).toEqual(["never-declared"]);
    const registered = ctx.task.suite?.tasks.find((t) => t.name.startsWith(meta.name));
    expect(registered?.mode).toBe("skip");
  });
});
