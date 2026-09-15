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

import { EvalError, runProgram, type LibraryTable, type Mode } from "../src/eval.js";
import { jsonEqual, type Json } from "../src/json.js";
import { ParseError, parseProgram } from "../src/parser.js";
import type { Program } from "../src/ast.js";

interface CaseMeta {
  name: string;
  mode: string;
  expect?: string;
  errorKind?: string;
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

function readJsonFile(path: string): Json {
  return JSON.parse(readFileSync(path, "utf8")) as Json;
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

function modeFromMeta(m: string): Mode {
  if (m === "concrete" || m === "symbolic") return m;
  throw new Error(`unknown mode ${m}`);
}

function parseOrThrow(src: string): Program {
  return parseProgram(src);
}

function runCase(dir: string, meta: CaseMeta): void {
  const mode = modeFromMeta(meta.mode);
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
      runProgram(mode, libs, ctx, prog);
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
  const actual = runProgram(mode, libs, ctx, prog);
  if (!jsonEqual(actual, expected)) {
    expect(actual).toEqual(expected);
    throw new Error("output mismatch");
  }
}

const corpusRoot = findCorpusRoot();

const caseDirs = readdirSync(corpusRoot)
  .map((name) => join(corpusRoot, name))
  .filter((p) => statSync(p).isDirectory())
  .sort();

const cases = caseDirs.map((dir) => ({
  dir,
  meta: JSON.parse(readFileSync(join(dir, "meta.json"), "utf8")) as CaseMeta,
}));

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
      for (const c of subset) {
        it(c.meta.name, () => {
          runCase(c.dir, c.meta);
        });
      }
    });
  }
});
