/**
 * The introspection views, driven by the envelope shapes `tramaj-js` actually
 * produces rather than by hand-written JSON, so a change to either side shows
 * up here.
 */

import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import {
  isJsonObject,
  parseProgram,
  programCard,
  runProgram,
  type Json,
  type LibraryTable,
} from "tramaj-js";

import {
  ConstraintTable,
  ProgramCard,
  resolvedTypeText,
  SymbolTable,
  TypeConstraintTable,
  TypesTable,
} from "../src/tables.js";

const noLibs: LibraryTable = new Map();

function envelope(src: string, ctx: Json = null): Record<string, Json> {
  const out = runProgram("symbolic", noLibs, ctx, parseProgram(src));
  if (!isJsonObject(out)) throw new Error("expected an envelope");
  return out;
}

function arrayField(e: Record<string, Json>, name: string): Json[] {
  const v = e[name];
  if (!Array.isArray(v)) throw new Error(`expected ${name} to be an array`);
  return v;
}

function textOf(ui: React.ReactNode): string {
  return render(<>{ui}</>).container.textContent ?? "";
}

describe("SymbolTable", () => {
  it("says so when there are no symbols", () => {
    expect(textOf(<SymbolTable entries={[]} />)).toBe("No symbols.");
  });

  it("renders an allocation's site and key, and the binding it was read into", () => {
    const e = envelope('@x=?("deployment")\n$x');
    const text = textOf(<SymbolTable entries={arrayField(e, "symbols")} />);
    expect(text).toContain("alloc @0 deployment");
    expect(text).toContain("x");
  });

  it("renders a demand's path, with no binding", () => {
    const e = envelope("?ctx.spec.replicas", {});
    const text = textOf(<SymbolTable entries={arrayField(e, "symbols")} />);
    expect(text).toContain("demand ctx.spec.replicas");
    expect(text).toContain("—");
  });

  it("renders a malformed entry as a ? row rather than throwing", () => {
    expect(textOf(<SymbolTable entries={[{ nonsense: true }]} />)).toContain("?");
  });
});

describe("ConstraintTable", () => {
  it("says so when there are no constraints", () => {
    expect(textOf(<ConstraintTable entries={[]} />)).toBe("No constraints.");
  });

  it("renders a constraint's name and arguments, a symbol argument included", () => {
    const e = envelope('@n=?("count")\n!constraint("positive", $n, 3)\n$n');
    const text = textOf(<ConstraintTable entries={arrayField(e, "constraints")} />);
    expect(text).toContain("positive");
    expect(text).toContain('#0:"count", 3');
  });
});

describe("TypesTable", () => {
  it("says so when there are no types", () => {
    expect(textOf(<TypesTable entries={[]} />)).toBe("No types.");
  });

  it("renders a declaration's canonical id alongside its definition", () => {
    const e = envelope("type Point = {x: number, y: number}\n@p : Point = $ctx.p\n$p", { p: 1 });
    const text = textOf(<TypesTable entries={arrayField(e, "types")} />);
    expect(text).toContain("root:Point");
    expect(text).toContain("{x: number, y: number}");
  });

  it("renders each ResolvedType shape terse enough for a table cell", () => {
    expect(resolvedTypeText({ kind: "prim", name: "string" })).toBe("string");
    expect(resolvedTypeText({ kind: "array", element: { kind: "prim", name: "bool" } })).toBe("[bool]");
    expect(resolvedTypeText({ kind: "ref", id: 'root:Point' })).toBe("root:Point");
    expect(resolvedTypeText({ kind: "var", path: ["a", "b"] })).toBe("%ctx.a.b");
    expect(
      resolvedTypeText({
        kind: "union",
        arms: [{ name: "None" }, { name: "Some", payload: { kind: "prim", name: "number" } }],
      }),
    ).toBe("None | Some(number)");
    expect(resolvedTypeText("not a type")).toBe("?");
  });
});

describe("TypeConstraintTable", () => {
  it("says so when there are none", () => {
    expect(textOf(<TypeConstraintTable entries={[]} />)).toBe("No type constraints.");
  });

  it("renders a type argument as the id behind its $type tag", () => {
    const e = envelope('type Point = {x: number}\n!type-constraint("shaped", %Point, "note")\n1');
    const text = textOf(<TypeConstraintTable entries={arrayField(e, "type-constraints")} />);
    expect(text).toContain("shaped");
    expect(text).toContain("root:Point, note");
  });
});

describe("ProgramCard", () => {
  it("renders the five fields of an analysis card", () => {
    const libs: LibraryTable = new Map([
      ["row", parseProgram('.li(action("on-click", "pick", $ctx.id))')],
    ]);
    const prog = parseProgram('.ul(map($ctx.items, (i) => import("row", {}).rendered))');
    const text = textOf(<ProgramCard card={programCard(libs, prog)} />);
    expect(text).toContain("Producesdocument");
    expect(text).toContain("items");
    expect(text).toContain("row");
    expect(text).toContain("pick");
    expect(text).toContain("id");
  });

  it("shows an em dash for an empty field", () => {
    const text = textOf(<ProgramCard card={programCard(noLibs, parseProgram("1"))} />);
    expect(text).toContain("—");
    expect(text).toContain("Producesvalue");
  });
});
