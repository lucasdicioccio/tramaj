/**
 * `sort-by`, `sort-by-descending`, `format-number` and `round`
 * (`specs/reference.md` §11, `specs/decisions.md` §20), where the shared
 * corpus has no shape for the check: how many times the key function runs,
 * what the parser lowers the forms to, what the analyses see inside a key
 * function, and this port's rounding against the host's own formatter.
 */

import { describe, expect, it } from "vitest";

import {
  arithmeticNames,
  arithmeticOps,
  constraintKinds,
  contextHoles,
  contextReads,
  deepActionKeys,
  deepArithmeticOps,
  deepConstraintKinds,
  staticActionKeys,
  staticImportNames,
  symbolDemands,
  symbolSites,
  transitiveImportNames,
} from "../src/analysis.js";
import { expressionProgram, subExprs, type Expr, type Program } from "../src/ast.js";
import {
  emittedConstraintCount,
  EvalError,
  runProgramWith,
  type LibraryTable,
} from "../src/eval.js";
import { stringify, type Json } from "../src/json.js";
import { ParseError, parseProgram } from "../src/parser.js";

const noLibs: LibraryTable = new Map();

function run(src: string, ctx: Json = null, arithmetic = false): Json {
  return runProgramWith({ arithmetic }, noLibs, ctx, parseProgram(src));
}

function errorKind(f: () => unknown): string {
  try {
    f();
  } catch (e) {
    if (e instanceof EvalError) return e.kind;
    throw e;
  }
  return "no error";
}

function parses(src: string): boolean {
  try {
    parseProgram(src);
    return true;
  } catch (e) {
    if (e instanceof ParseError) return false;
    throw e;
  }
}

describe("the parser and the two sort forms", () => {
  const sortOf = (src: string): Expr => parseProgram(src).root;

  it("lowers both names to one constructor", () => {
    const asc = sortOf("sort-by($ctx.xs, (x) => $x)");
    const desc = sortOf("sort-by-descending($ctx.xs, (x) => $x)");
    expect(asc.t).toBe("SortBy");
    expect(asc).toMatchObject({ descending: false, collection: { t: "Path", root: "ctx", fields: ["xs"] } });
    expect(desc).toMatchObject({ t: "SortBy", descending: true, fn: { t: "Lambda", params: ["x"] } });
  });

  it("accepts the $ spelling and a field access on the result", () => {
    expect(sortOf("$sort-by($ctx.xs, $ctx.f)")).toMatchObject({ t: "SortBy", descending: false });
    expect(sortOf("$sort-by-descending($ctx.xs, $ctx.f)")).toMatchObject({ t: "SortBy", descending: true });
    expect(sortOf("sort-by($ctx.xs, $ctx.f).name")).toMatchObject({
      t: "FieldAccess",
      target: { t: "SortBy" },
      fields: ["name"],
    });
  });

  it("refuses an argument count other than two", () => {
    for (const name of ["sort-by", "sort-by-descending"]) {
      expect(parses(`${name}()`)).toBe(false);
      expect(parses(`${name}($ctx.xs)`)).toBe(false);
      expect(parses(`${name}($ctx.xs, (x) => $x, 1)`)).toBe(false);
    }
  });

  it("refuses a sort name passed by reference", () => {
    expect(parses("map($ctx.xs, $sort-by)")).toBe(false);
    expect(parses("$sort-by-descending")).toBe(false);
    expect(parses("@s = $sort-by\n1")).toBe(false);
  });

  it("lists the collection and then the key function as sub-expressions", () => {
    const e = sortOf("sort-by($ctx.xs, $ctx.f)");
    expect(subExprs(e)).toEqual([
      { t: "Path", root: "ctx", fields: ["xs"] },
      { t: "Path", root: "ctx", fields: ["f"] },
    ]);
  });
});

describe("the key function of a sort", () => {
  /**
   * A sort whose key function emits one constraint each time it runs. No
   * surface program can write this, since `!` is a statement, so the AST is
   * built by hand. The constraints are all equal: only a count taken before
   * deduplication tells one application from two.
   */
  function countingSort(descending: boolean, keys: number[]): Program {
    const fn: Expr = {
      t: "Lambda",
      params: ["x"],
      body: { t: "Emit", constraint: { t: "Constrain", name: "applied", args: [] }, body: { t: "Path", root: "x", fields: [] } },
    };
    const collection: Expr = { t: "ArrayLit", elements: keys.map((value) => ({ t: "IntLit", value })) };
    return expressionProgram({ t: "SortBy", descending, collection, fn });
  }

  const lists: Array<[string, number[]]> = [
    ["empty", []],
    ["one element", [7]],
    ["ordered", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]],
    ["reversed", [12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]],
    ["shuffled", [5, 12, 1, 9, 3, 11, 7, 2, 10, 4, 8, 6, 5, 1, 12]],
    ["all equal", [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]],
  ];

  for (const descending of [false, true]) {
    for (const [what, keys] of lists) {
      it(`is applied once per element: ${descending ? "sort-by-descending" : "sort-by"}, ${what}`, () => {
        const prog = countingSort(descending, keys);
        expect(emittedConstraintCount({}, noLibs, null, prog)).toBe(keys.length);
        const want = [...keys].sort((a, b) => (descending ? b - a : a - b));
        expect(runProgramWith({}, noLibs, null, prog)).toEqual(want);
      });
    }
  }

  it("is applied in index order, and the first failing element decides the error", () => {
    // The second element's key is refused before the third's application fails.
    expect(errorKind(() => run("sort-by([{k: 1}, {k: null}, {}], (r) => $r.k)"))).toBe("TypeMismatch");
    expect(errorKind(() => run("sort-by([{k: 1}, {}, {k: null}], (r) => $r.k)"))).toBe("PathNotFound");
  });
});

describe("the order of a sort", () => {
  it("is stable on its own terms in both directions, whatever the size of the list", () => {
    // 200 elements over 7 keys: long enough for any engine to leave its
    // short-array path.
    const rows = Array.from({ length: 200 }, (_, i) => ({ i, k: (i * 37) % 7 }));
    for (const descending of [false, true]) {
      const name = descending ? "sort-by-descending" : "sort-by";
      const out = run(`${name}($ctx.rows, (r) => $r.k)`, { rows }) as Array<{ i: number; k: number }>;
      const want = [...rows].sort((a, b) => (descending ? b.k - a.k : a.k - b.k) || a.i - b.i);
      expect(out).toEqual(want);
    }
  });

  it("compares strings by code point, not by UTF-16 code unit", () => {
    // U+1F600 is the surrogates D83D DE00, which as code units sort before U+FF5E.
    const xs = ["\u{1F600}", "～", "a\u{1F600}", "a～", "a", "", "\u{10000}", "￿", "\u{1F600}\u{1F601}", "\u{1F600}\u{1F600}"];
    const want = ["", "a", "a～", "a\u{1F600}", "～", "￿", "\u{10000}", "\u{1F600}", "\u{1F600}\u{1F600}", "\u{1F600}\u{1F601}"];
    expect(run("sort-by($ctx.xs, (x) => $x)", { xs })).toEqual(want);
    expect(run("sort-by-descending($ctx.xs, (x) => $x)", { xs })).toEqual([...want].reverse());
    // The native order, which is the one not to use, differs.
    expect([...xs].sort()).not.toEqual(want);
  });
});

describe("the analyses and a sort", () => {
  const libs: LibraryTable = new Map([["row", parseProgram('.li(action("on-click", "pick", {}))')]]);
  const prog = parseProgram(
    [
      "sort-by-descending(",
      "  sort-by($ctx.rows, (r) => round($r.spend)),",
      '  (r) => [$ctx.weights, ?ctx.bias, ?("k"), constraint("seen", $r),',
      '          import("row", {title: ctx(title)}), .b(action("on-click", "open", {})), floor($r.n)]',
      ")",
    ].join("\n"),
  );

  it("reach the collection and the inside of the key function", () => {
    expect(contextReads(prog)).toEqual([["rows"], ["title"], ["weights"]]);
    expect(contextHoles(prog)).toEqual([["title"]]);
    expect(staticImportNames(prog)).toEqual(["row"]);
    expect(transitiveImportNames(libs, prog)).toEqual(["row"]);
    expect(staticActionKeys(prog)).toEqual(["open"]);
    expect(deepActionKeys(libs, prog)).toEqual(["open", "pick"]);
    expect(constraintKinds(prog)).toEqual(["seen"]);
    expect(deepConstraintKinds(libs, prog)).toEqual(["seen"]);
    expect(symbolDemands(prog)).toEqual([["bias"]]);
    expect(symbolSites(prog)).toEqual([0]);
    expect(arithmeticOps(prog)).toEqual(["floor", "round"]);
    expect(deepArithmeticOps(libs, prog)).toEqual(["floor", "round"]);
  });

  it("keep the scope of a key function's parameter", () => {
    expect(arithmeticOps(parseProgram("sort-by($ctx.xs, (round) => $round)"))).toEqual([]);
    expect(arithmeticOps(parseProgram("sort-by($ctx.xs, $round)"))).toEqual(["round"]);
  });
});

describe("round", () => {
  it("is the tenth name of the arithmetic profile, bound only with it", () => {
    expect(arithmeticNames).toHaveLength(10);
    expect(arithmeticNames).toContain("round");
    expect(errorKind(() => run("round(2.5)"))).toBe("UnboundName");
    expect(run("@round = 7\n$round", null, true)).toBe(7);
  });

  it("rounds the exact value, ties away from zero, to an integer", () => {
    expect(
      stringify(
        run("[round(2.5), round(-2.5), round(0.5), round(-0.5), round(-0.4), round(0.49999999999999994), round(7), round(3.0)]", null, true),
      ),
    ).toBe("[3,-3,1,-1,0,0,7,3]");
    // 2^52 + 0.5 is not a double; 2^52 - 0.5 is, and is a tie.
    expect(run("round(4503599627370495.5)", null, true)).toBe(4503599627370496);
    expect(run("round(-4503599627370495.5)", null, true)).toBe(-4503599627370496);
  });

  it("is held to the integer range", () => {
    expect(run("round(9007199254740991.0)", null, true)).toBe(9007199254740991);
    expect(errorKind(() => run("round(9007199254740992.0)", null, true))).toBe("NotRepresentable");
    expect(errorKind(() => run("round(-1e19)", null, true))).toBe("NotRepresentable");
    expect(errorKind(() => run("round(1e308)", null, true))).toBe("NotRepresentable");
  });

  it("builds a term over a symbol, and a seeded round term is read back", () => {
    const out = runProgramWith({ mode: "symbolic", arithmetic: true }, noLibs, {}, parseProgram("round(?ctx.s)")) as Record<
      string,
      Json
    >;
    const term = out["root"] as Json;
    expect(stringify(term)).toBe('{"$term":"round","arguments":[{"$sym":"#ctx.s","path":[]}]}');
    const back = runProgramWith({ mode: "symbolic", arithmetic: true }, noLibs, { t: term }, parseProgram("$ctx.t")) as Record<
      string,
      Json
    >;
    expect(stringify(back["root"] as Json)).toBe(stringify(term));
  });
});

describe("format-number", () => {
  it("is a builtin of every profile, which a program may shadow or pass by reference", () => {
    expect(run('format-number(1234567.891, 2, ",")')).toBe("1,234,567.89");
    expect(run('@format-number = 7\n$format-number')).toBe(7);
    expect(run('@f = $format-number\n$f(1234, 2, " ")')).toBe("1 234.00");
  });

  it("inserts the separator as it is, whatever it holds", () => {
    expect(run('format-number(1234567, 0, "$&")')).toBe("1$&234$&567");
    expect(run('format-number(1234567, 1, "$1")')).toBe("1$1234$1567.0");
    expect(run('format-number(123, 0, ",")')).toBe("123");
  });

  it("writes every digit of a large or a small double, and no exponent", () => {
    expect(run('format-number(1e23, 0, "")')).toBe("99999999999999991611392");
    expect(run('format-number(1e21, 0, ",")')).toBe("1,000,000,000,000,000,000,000");
    expect(run('format-number(5e-324, 20, "")')).toBe("0.00000000000000000000");
    expect((run('format-number(1.7976931348623157e308, 20, "")') as string).length).toBe(309 + 1 + 20);
    expect(run('format-number(0.1, 20, "")')).toBe("0.10000000000000000555");
  });

  /** A small deterministic generator (mulberry32), so a failure reproduces. */
  function generator(seed: number): () => number {
    let a = seed;
    return () => {
      a = (a + 0x6d2b79f5) | 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  it("agrees with toFixed below 1e21, apart from the negative zero toFixed writes", () => {
    // Below 1e21 `Number.prototype.toFixed` is specified on the exact value
    // with the larger candidate on a tie, which for its magnitude is this
    // rule. It is not what the port runs, so the two are independent.
    const next = generator(20);
    const bits = new DataView(new ArrayBuffer(8));
    const samples: number[] = [0.125, -0.125, 2.5, -2.5, 1.005, 2.675, 999.995, -0.001, -0.005, 0.5, 1e-7, 123456789.125];
    while (samples.length < 4000) {
      const kind = samples.length % 3;
      let x: number;
      if (kind === 0) {
        // Any bit pattern.
        bits.setUint32(0, Math.floor(next() * 4294967296));
        bits.setUint32(4, Math.floor(next() * 4294967296));
        x = bits.getFloat64(0);
      } else if (kind === 1) {
        // An ordinary magnitude.
        x = (next() - 0.5) * 10 ** Math.floor(next() * 24 - 6);
      } else {
        // An exact tie at some number of decimals: an odd multiple of a power of two.
        x = (Math.floor(next() * 2000000) - 1000000 + 0.5) / 2 ** Math.floor(next() * 12);
      }
      if (Number.isFinite(x) && Math.abs(x) < 1e21) samples.push(x === 0 ? 0 : x);
    }
    // A sample that is a whole number in range is an integer in the context,
    // which format-number takes as well.
    const ctx = { xs: samples };
    for (let decimals = 0; decimals <= 20; decimals += 1) {
      const got = run(`map($ctx.xs, (x) => format-number($x, ${decimals}, ""))`, ctx) as string[];
      samples.forEach((x, i) => {
        const fixed = x.toFixed(decimals);
        const want = /^-[0.]*$/.test(fixed) ? fixed.slice(1) : fixed;
        if (got[i] !== want) throw new Error(`format-number(${x}, ${decimals}, ""): got ${got[i]}, toFixed gives ${want}`);
      });
    }
  });

  it("gives the text of round for a float whose rounding is in range", () => {
    const next = generator(7);
    const xs = Array.from({ length: 500 }, () => (next() - 0.5) * 10 ** Math.floor(next() * 14)).filter(
      (x) => !Number.isSafeInteger(x),
    );
    const out = run('map($ctx.xs, (x) => [str(round($x)), format-number($x, 0, "")])', { xs }, true) as string[][];
    for (const [a, b] of out) expect(a).toBe(b);
  });
});
