/**
 * `specs/reference.md` §9's analyses, which the corpus never reaches: it drives
 * `runProgram` only.
 */

import { describe, expect, it } from "vitest";

import {
  constraintKinds,
  contextHoles,
  contextReads,
  deepActionKeys,
  programCard,
  staticActionKeys,
  staticImportNames,
  symbolSites,
  transitiveImportNames,
  unsuppliedParams,
} from "../src/analysis.js";
import type { LibraryTable } from "../src/eval.js";
import { parseProgram } from "../src/parser.js";

const noLibs: LibraryTable = new Map();

describe("analysis", () => {
  it("reports action keys with adaptation applied, not ignored", () => {
    const prog = parseProgram(
      'adapt-actions(.div(action("on-click", "save", {}), action("on-click", "delete", {})), prefix("user:"))',
    );
    expect(staticActionKeys(prog)).toEqual(["user:delete", "user:save"]);
  });

  it("composes adaptations the obvious way", () => {
    const prog = parseProgram(
      'adapt-actions(adapt-actions(.div(action("on-click", "k", {})), prefix("a:")), prefix("b:"))',
    );
    expect(staticActionKeys(prog)).toEqual(["b:a:k"]);
  });

  // The analysis is syntactic: an adaptation over a *name* cannot see the
  // element that name is bound to, so the binding's own keys are reported raw.
  it("does not follow a binding through an adaptation", () => {
    const prog = parseProgram(
      '@p=.div(action("on-click", "k", {}))\nadapt-actions($p, prefix("a:"))',
    );
    expect(staticActionKeys(prog)).toEqual(["k"]);
  });

  it("follows imports for deep action keys, and reports a missing library as a dependency", () => {
    const libs: LibraryTable = new Map([
      ["row", parseProgram('.li(action("on-click", "pick", {}))')],
    ]);
    const prog = parseProgram('.ul(import("row", {}).rendered, import("gone", {}).rendered)');
    expect(deepActionKeys(libs, prog)).toEqual(["pick"]);
    expect(staticImportNames(prog)).toEqual(["gone", "row"]);
    expect(transitiveImportNames(libs, prog)).toEqual(["gone", "row"]);
  });

  it("separates context holes from every context read", () => {
    const prog = parseProgram('import("panel", {name: ctx(title), n: $ctx.count})');
    expect(contextHoles(prog)).toEqual([["title"]]);
    expect(contextReads(prog)).toEqual([["count"], ["title"]]);
  });

  it("reports the parameters an import leaves unsupplied, attributed by first segment", () => {
    const libs: LibraryTable = new Map([
      ["panel", parseProgram('.section(.h1($ctx.title), .p($ctx.body.text))')],
    ]);
    const prog = parseProgram('import("panel", {"title": "x"}).rendered');
    expect(unsuppliedParams(libs, prog)).toEqual([["panel", [["body", "text"]]]]);
  });

  it("contributes no unsupplied parameters for a library the table lacks", () => {
    const prog = parseProgram('import("gone", {}).rendered');
    expect(unsuppliedParams(noLibs, prog)).toEqual([["gone", []]]);
  });

  it("collects constraint kinds and allocation sites", () => {
    const prog = parseProgram('!constraint("positive", $ctx.n)\n[?("a"), ?("b")]');
    expect(constraintKinds(prog)).toEqual(["positive"]);
    expect(symbolSites(prog)).toEqual([0, 1]);
  });

  it("summarises a program as a card", () => {
    const libs: LibraryTable = new Map([["row", parseProgram('.li(action("on-click", "pick", $ctx.id))')]]);
    const prog = parseProgram('.ul(map($ctx.items, (i) => import("row", {}).rendered))');
    expect(programCard(libs, prog)).toEqual({
      produces: "document",
      requires: [["items"]],
      imports: ["row"],
      emits: ["pick"],
      unsupplied: [["row", [["id"]]]],
    });
  });

  it("classifies an expression program as producing a value", () => {
    expect(programCard(noLibs, parseProgram("$ctx.name")).produces).toBe("value");
  });
});
