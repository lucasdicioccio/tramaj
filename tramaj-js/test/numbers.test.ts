/**
 * The two number types and the arithmetic profile, where the shared corpus has
 * no shape for the check: this port's binding of a JavaScript number to a
 * type, its JSON reader and writer, the evaluation option and its default,
 * and the two arithmetic analyses.
 */

import { describe, expect, it } from "vitest";

import { arithmeticNames, arithmeticOps, deepArithmeticOps } from "../src/analysis.js";
import {
  EvalError,
  evalProgram,
  evalProgramWith,
  runProgram,
  runProgramWith,
  type LibraryTable,
} from "../src/eval.js";
import {
  Float,
  float,
  isFloat,
  isInteger,
  jsonEqual,
  JsonParseError,
  normalizeNumbers,
  JsonNumberError,
  parseJson,
  stringify,
  type Json,
} from "../src/json.js";
import { NodeDecodeError, nodeFromJson } from "../src/node.js";
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

describe("a JavaScript number as a Tramaj number", () => {
  it("classifies a safe integer as an integer and any other number as a float", () => {
    expect(isInteger(3)).toBe(true);
    expect(isFloat(3)).toBe(false);
    expect(isFloat(1.5)).toBe(true);
    expect(isFloat(2 ** 53)).toBe(true);
    expect(isFloat(new Float(3))).toBe(true);
    expect(isInteger(3n)).toBe(true);
  });

  it("wraps a float only when the plain number would be an integer", () => {
    expect(float(1.5)).toBe(1.5);
    expect(float(3)).toEqual(new Float(3));
  });

  it("never equates an integer with a float", () => {
    expect(jsonEqual(3, new Float(3))).toBe(false);
    expect(jsonEqual(new Float(3), new Float(3))).toBe(true);
    expect(jsonEqual([1, { a: new Float(2) }], [1, { a: new Float(2) }])).toBe(true);
    expect(jsonEqual(3, 3n)).toBe(true);
  });

  it("reads a host context by that classification", () => {
    expect(run("str($ctx.n)", { n: 3 })).toBe("3");
    expect(run("str($ctx.n)", { n: new Float(3) })).toBe("3.0");
    expect(run("str($ctx.n)", { n: 1.5 })).toBe("1.5");
    expect(run("str($ctx.n)", { n: 3n })).toBe("3");
    expect(run("eq($ctx.a, $ctx.b)", { a: 1, b: new Float(1) })).toBe(false);
  });

  it("refuses a host number that is not a value", () => {
    expect(errorKind(() => run("1", { n: Number.NaN }))).toBe("TypeMismatch");
    expect(errorKind(() => run("1", { n: Number.POSITIVE_INFINITY }))).toBe("TypeMismatch");
    expect(errorKind(() => run("1", { n: 2n ** 53n }))).toBe("TypeMismatch");
    expect(errorKind(() => run("1", [{ deep: [new Float(Number.NaN)] }]))).toBe("TypeMismatch");
  });

  it("hands back a whole-valued float as a Float, and every other number plain", () => {
    expect(run("[1, 1.0, 1.5, 1e21]")).toEqual([1, new Float(1), 1.5, 1e21]);
    const out = evalProgram("concrete", noLibs, null, parseProgram(".p(x: 2.0)"));
    expect(out.t === "node" && out.node.t === "element" && out.node.attributes[0]).toEqual({
      t: "attribute",
      name: "x",
      value: new Float(2),
    });
  });

  it("reads a negative zero as zero", () => {
    expect(stringify(run("$ctx", parseJson("[-0, -0.0]")))).toBe("[0,0.0]");
    expect(stringify(run("[-0, -0.0]"))).toBe("[0,0.0]");
  });
});

describe("JSON text", () => {
  it("types a number by its text", () => {
    const v = parseJson('[3, 3.0, 3e0, 1.5, -7, 1e21, 0.1]');
    expect(v).toEqual([3, new Float(3), new Float(3), 1.5, -7, 1e21, 0.1]);
  });

  it("writes a number by its type", () => {
    expect(stringify([3, new Float(3), 1.5, new Float(100000000000), 1e21, 1e-7, -7])).toBe(
      "[3,3.0,1.5,100000000000.0,1e+21,1e-7,-7]",
    );
    expect(String(new Float(3))).toBe("3.0");
    // `JSON.stringify` cannot keep the type.
    expect(JSON.stringify([new Float(3)])).toBe("[3]");
  });

  it("round-trips text through parseJson and stringify", () => {
    const text = '{"a":[1,1.0,"x\\n\\u00e9",null,true,false],"b":{},"c":[],"d":-0.5}';
    expect(stringify(parseJson(text))).toBe('{"a":[1,1.0,"x\\né",null,true,false],"b":{},"c":[],"d":-0.5}');
  });

  it("indents when asked", () => {
    expect(stringify({ a: [1, new Float(2)], b: {} }, 2)).toBe(
      '{\n  "a": [\n    1,\n    2.0\n  ],\n  "b": {}\n}',
    );
  });

  it("keeps the digits of an integer beyond the range, for the decoder to refuse", () => {
    const v = parseJson("9007199254740993");
    expect(v).toBe(9007199254740993n);
    expect(stringify(v)).toBe("9007199254740993");
    expect(() => normalizeNumbers(v)).toThrow(JsonNumberError);
    expect(errorKind(() => run("1", v))).toBe("TypeMismatch");
    expect(parseJson("9007199254740991")).toBe(9007199254740991);
  });

  it("reads a float too large for a double as one the decoder refuses", () => {
    const v = parseJson("[1e400]");
    expect(() => normalizeNumbers(v)).toThrow(JsonNumberError);
    expect(errorKind(() => run("1", v))).toBe("TypeMismatch");
    expect(parseJson("1e-400")).toEqual(new Float(0));
  });

  it("refuses text that is not JSON", () => {
    for (const bad of ["", "[1,]", '{"a":1,}', "01", "1.", ".5", "+1", "nul", '"a', "[1] 2", "{a:1}", '"\t"', "NaN"]) {
      expect(() => parseJson(bad), bad).toThrow(JsonParseError);
    }
  });

  it("keeps a __proto__ key as data, and the last of two equal keys", () => {
    const v = parseJson('{"__proto__": 1, "a": 1, "a": 2}') as Record<string, Json>;
    expect(Object.keys(v)).toEqual(["__proto__", "a"]);
    expect(v["a"]).toBe(2);
  });
});

describe("node decoding", () => {
  const text = (value: string): Json => parseJson(`{"type":"text","value":${value},"annotations":{}}`);

  it("types a value number by its text", () => {
    expect(nodeFromJson(text("3"))).toEqual({ t: "text", value: 3, annotations: {} });
    expect(nodeFromJson(text("3.0"))).toEqual({ t: "text", value: new Float(3), annotations: {} });
    expect(nodeFromJson(text("-0.0"))).toEqual({ t: "text", value: new Float(0), annotations: {} });
  });

  it("rejects a number outside the value domain", () => {
    expect(() => nodeFromJson(text("9007199254740992"))).toThrow(NodeDecodeError);
    expect(() => nodeFromJson(text("[1e400]"))).toThrow(NodeDecodeError);
  });
});

describe("number literals", () => {
  it("refuses an integer literal outside the range", () => {
    expect(() => parseProgram("9007199254740992")).toThrow(ParseError);
    expect(() => parseProgram("-9007199254740992")).toThrow(ParseError);
    expect(run("[9007199254740991, -9007199254740991]")).toEqual([9007199254740991, -9007199254740991]);
    expect(run("9007199254740992.0")).toBe(9007199254740992);
  });

  it("reserves the $term key", () => {
    expect(() => parseProgram('{"$term": 1}')).toThrow(ParseError);
    expect(errorKind(() => run("1", { $term: "sum", arguments: [1] }))).toBe("TypeMismatch");
  });
});

describe("the arithmetic profile", () => {
  it("is off by default, where its names are unbound", () => {
    expect(errorKind(() => runProgram("concrete", noLibs, null, parseProgram("sum(1, 2)")))).toBe("UnboundName");
    expect(errorKind(() => evalProgram("concrete", noLibs, null, parseProgram("$floor")))).toBe("UnboundName");
    expect(errorKind(() => runProgramWith({}, noLibs, null, parseProgram("sum(1, 2)")))).toBe("UnboundName");
    expect(errorKind(() => evalProgramWith({ mode: "symbolic" }, noLibs, null, parseProgram("real(1)")))).toBe(
      "UnboundName",
    );
  });

  it("computes when it is on", () => {
    expect(run("sum(1, [2, [3]])", null, true)).toBe(6);
    expect(stringify(run("[sum(0.5, 0.5), real(2), floor(2.5), quotient(1.0, 4.0)]", null, true))).toBe(
      "[1.0,2.0,2,0.25]",
    );
    expect(run("[floor-quotient(-7, 2), modulo(-7, 2), modulo(7, -2)]", null, true)).toEqual([-4, 1, -1]);
    expect(errorKind(() => run("sum(9007199254740991, 1)", null, true))).toBe("NotRepresentable");
    expect(errorKind(() => run("inverse(0.0)", null, true))).toBe("NotRepresentable");
    expect(errorKind(() => run("sum(1, 1.0)", null, true))).toBe("TypeMismatch");
  });

  it("does not have round", () => {
    expect(arithmeticNames).toHaveLength(9);
    expect(errorKind(() => run("round(2.5)", null, true))).toBe("UnboundName");
  });

  it("lets a program bind one of its names, with or without it", () => {
    for (const arithmetic of [false, true]) expect(run("@sum = 7\n$sum", null, arithmetic)).toBe(7);
  });

  it("applies to every library the evaluation runs", () => {
    const libs: LibraryTable = new Map([["lib", parseProgram("@total = sum($ctx.a, 1)\n$total")]]);
    const prog = parseProgram('import("lib", {a: 2}).rendered');
    expect(runProgramWith({ arithmetic: true }, libs, null, prog)).toBe(3);
    expect(errorKind(() => runProgramWith({}, libs, null, prog))).toBe("InLibrary");
  });

  it("builds a term over a symbol, and reads it back only with the profile on", () => {
    const prog = parseProgram("sum(1, ?ctx.s, 2.5)");
    expect(errorKind(() => runProgramWith({ mode: "symbolic", arithmetic: true }, noLibs, {}, prog))).toBe(
      "TypeMismatch",
    );
    const out = runProgramWith(
      { mode: "symbolic", arithmetic: true },
      noLibs,
      {},
      parseProgram("sum(1.0, ?ctx.s, 2.5)"),
    ) as Record<string, Json>;
    const term = out["root"] as Json;
    expect(stringify(term)).toBe('{"$term":"sum","arguments":[1.0,{"$sym":"#ctx.s","path":[]},2.5]}');
    const back = parseProgram("$ctx.t");
    expect(
      stringify(
        (runProgramWith({ mode: "symbolic", arithmetic: true }, noLibs, { t: term }, back) as Record<string, Json>)[
          "root"
        ] as Json,
      ),
    ).toBe(stringify(term));
    expect(errorKind(() => runProgramWith({ mode: "symbolic" }, noLibs, { t: term }, back))).toBe("TypeMismatch");
    expect(errorKind(() => runProgramWith({ arithmetic: true }, noLibs, { t: term }, back))).toBe("TypeMismatch");
  });
});

describe("arithmeticOps", () => {
  it("reports a name called or passed by reference, sorted", () => {
    expect(arithmeticOps(parseProgram("fold($ctx.xs, 0, $sum) <> [negate(1), floor(1.5)]"))).toEqual([
      "floor",
      "negate",
      "sum",
    ]);
  });

  it("is scope-aware", () => {
    expect(arithmeticOps(parseProgram("@sum = 1\n$sum"))).toEqual([]);
    expect(arithmeticOps(parseProgram("@sum = sum(1, 2)\n$sum"))).toEqual(["sum"]);
    expect(arithmeticOps(parseProgram("map($ctx.xs, (floor) => $floor)"))).toEqual([]);
    expect(arithmeticOps(parseProgram("[map($ctx.xs, (real) => $real), real(1)]"))).toEqual(["real"]);
  });

  it("does not report round, which this port does not have", () => {
    expect(arithmeticOps(parseProgram("round(1.5)"))).toEqual([]);
  });

  it("follows imports in its deep variant, each library in its own scope", () => {
    const libs: LibraryTable = new Map([
      ["a", parseProgram('@x = import("b", {})\nproduct(2, 3)')],
      ["b", parseProgram("modulo(7, 2)")],
    ]);
    const prog = parseProgram('@product = 1\n@modulo = 2\nimport("a", {}).rendered');
    expect(arithmeticOps(prog)).toEqual([]);
    expect(deepArithmeticOps(libs, prog)).toEqual(["modulo", "product"]);
  });
});
