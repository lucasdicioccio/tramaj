/**
 * `?shape(key, shape)` and its `~name` markers (`v3-symbols.md` §1.2,
 * decisions §19), where the shared corpus has no shape for the check: the AST
 * the form lowers to, its site numbering, the parse errors one by one, and
 * `symbolSites`.
 */

import { describe, expect, it } from "vitest";

import { symbolSites } from "../src/analysis.js";
import type { Expr } from "../src/ast.js";
import { runProgram, type LibraryTable } from "../src/eval.js";
import { ParseError, parseProgram } from "../src/parser.js";

const noLibs: LibraryTable = new Map();

const shapeKey: Expr = { t: "Path", root: "#shape", fields: [] };

function markerAt(site: number, name: string, ...key: Expr[]): Expr {
  return { t: "Alloc", site, key: { t: "ArrayLit", elements: [shapeKey, { t: "StringLit", value: name }, ...key] } };
}

describe("?shape", () => {
  it("lowers to a hidden binding of its key, with markers allocating at the form's one site", () => {
    const prog = parseProgram('?shape("d", {~replicas, ports: [~http($x)]})');
    expect(prog.root).toEqual({
      t: "Let",
      name: "#shape",
      value: { t: "StringLit", value: "d" },
      body: {
        t: "ObjectLit",
        fields: [
          ["replicas", markerAt(0, "replicas")],
          ["ports", { t: "ArrayLit", elements: [markerAt(0, "http", { t: "Path", root: "x", fields: [] })] }],
        ],
      },
    });
  });

  it("gives a ?(k) inside a shape the next site, after the form's own", () => {
    const prog = parseProgram('?shape("o", [~a, ?("p")])');
    expect(prog.root).toEqual({
      t: "Let",
      name: "#shape",
      value: { t: "StringLit", value: "o" },
      body: { t: "ArrayLit", elements: [markerAt(0, "a"), { t: "Alloc", site: 1, key: { t: "StringLit", value: "p" } }] },
    });
  });

  it("reports a ?shape's site once, whatever number of markers it holds, in one sequence with ?(k)", () => {
    const prog = parseProgram('[?shape("o", {~a, b: [~b, ~c(1)], i: ?shape("i", {~d})}), ?("p")]');
    expect(symbolSites(prog)).toEqual([0, 1, 2]);
  });

  it("allocates [key, name] and [key, name, marker key], with a null binding even when bound", () => {
    const prog = parseProgram('@d = ?shape("d", {~a, b: map([1, 2], (x) => ~b($x))})\n$d');
    const out = runProgram("symbolic", noLibs, null, prog) as { symbols: unknown[] };
    expect(out.symbols).toEqual([
      { id: '#0:["d","a"]', origin: { kind: "alloc", site: 0, key: ["d", "a"] }, binding: null },
      { id: '#0:["d","b",1]', origin: { kind: "alloc", site: 0, key: ["d", "b", 1] }, binding: null },
      { id: '#0:["d","b",2]', origin: { kind: "alloc", site: 0, key: ["d", "b", 2] }, binding: null },
    ]);
  });

  it("leaves $shape and @shape alone", () => {
    expect(runProgram("concrete", noLibs, null, parseProgram("@shape = 1\n$shape"))).toBe(1);
  });

  const rejects: Array<[string, string]> = [
    ["a marker outside any shape", "[~a]"],
    ["a marker in a ?shape's key", '?shape(~k, {~a})'],
    ["a marker in a nested ?shape's key", '?shape("o", {~a, i: ?shape(~k, {~b})})'],
    ["a bare marker under a lambda inside the shape", '?shape("d", map($xs, (x) => ~a))'],
    ["a bare shorthand marker under a lambda inside the shape", '?shape("d", map($xs, (x) => {~a}))'],
    ["a duplicate marker name, bare and keyed", '?shape("d", [~a, map($xs, (x) => ~a($x))])'],
    ["a shape with no marker", '?shape("d", {a: 1})'],
    ["?shape with three arguments", '?shape("d", {~a}, 1)'],
    ["?shape with one argument", '?shape("d")'],
    ["a space after the marker leader", '?shape("d", ~ a)'],
    ["?(a, b)", '?("a", "b")'],
  ];
  for (const [what, src] of rejects) {
    it(`rejects ${what}`, () => {
      expect(() => parseProgram(src)).toThrow(ParseError);
    });
  }
});
