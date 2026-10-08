# tramaj-js

TypeScript port of the Tramaj language: parser, evaluator (concrete and
symbolic modes), the normative `Node` JSON codec, and the static analyses.
Hand-written, not generated from `tramaj/` (PureScript), `tramaj-hs/` (Haskell)
or `tramaj-rs/` (Rust); agreement with those is enforced by the shared corpus
at `../corpus/cases`, which `test/corpus.test.ts` reads directly.

No React and no DOM dependency: folding a `Node` into UI output is
`../tramaj-react`'s job, the way `tramaj-halogen` is to `tramaj`.

Specs: `../specs/reference.md` (core), `../specs/node-json.md` (wire format),
`../specs/v3-symbols.md`, `../specs/v4-types.md`.

## Public API

Everything is re-exported from `src/index.ts`.

| module | exports |
|---|---|
| `ast` | `Program`, `Expr`, `TypeExpr`, `Attribute`, `ParamValue`, `Stmt`; `subExprs`, `unlets`, `letBindings`, `typeDecls`, `numberAllocs`, `adaptKey` |
| `parser` | `parseProgram`, `tryParseProgram`, `ParseError` |
| `eval` | `runProgram`, `evalProgram`, `runProgramWith`, `evalProgramWith`, `defaultOptions`, `emittedConstraintCount`, `toJson`; `Mode`, `Options`, `LibraryTable`, `Value`, `Output`, `EvalError` |
| `json` | `Json`, `Float`; `parseJson`, `stringify`, `float`, `isInteger`, `isFloat`, `numberValue`, `classifyNumber`, `normalizeNumbers`, `inIntegerRange`, `formatInteger`, `formatFloat`, `jsonEqual`, `compactJson`, `displayString`, `isJsonObject`, `JsonParseError`, `JsonNumberError` |
| `node` | `Node`, `NodeAttribute`, `Annotations`; `nodeToJson`/`nodeFromJson`, `nodeAttributeToJson`/`nodeAttributeFromJson`, `mapActions`, `NodeDecodeError` |
| `analysis` | `staticImportNames`, `transitiveImportNames`, `staticActionKeys`, `deepActionKeys`, `contextHoles`, `deepContextHoles`, `contextReads`, `unsuppliedParams`, `arithmeticNames`, `arithmeticOps`, `deepArithmeticOps`, `constraintKinds`, `deepConstraintKinds`, `symbolSites`, `symbolDemands`, `deepSymbolDemands`, `typeDeclarations`, `typeParams`, `unsuppliedTypeParams`, `typeParamCollisions`, `programCard`, `programKind` |
| `types` | `resolveTypeExpr`, `canonicalId`, `requireClosed`, `typeClosure`, `eraseTypes`, `typeConstraints`, `deepTypeConstraints`, `typeReferences`, `deepTypeReferences`, `checkTypeParamCollisions`, `TypeError` |

```ts
import { parseProgram, runProgram } from "@lucasdicioccio/tramaj-js";

const program = parseProgram('.p($ctx.name)');
runProgram("concrete", new Map(), { name: "web" }, program);
```

A `LibraryTable` is a `Map<string, Program>`; a `Mode` is `"concrete"` or
`"symbolic"`. Every set-valued analysis returns a sorted array, so two runs
over the same program agree on order as well as membership.

## Numbers

The language has two number types, an integer and a float
(`../specs/reference.md` §3), and a JavaScript `number` has no type of its
own. This is how the port binds the two:

| JavaScript value | Tramaj type |
|---|---|
| a `number` that is a safe integer (`Number.isSafeInteger`) | integer |
| any other finite `number` (`1.5`, `1e21`) | float |
| a `Float`, e.g. `new Float(3)` | float, whatever it holds: the float `3.0` |
| a `bigint` | integer |

- **Integer range: the guaranteed one**, `-(2^53 - 1)` to `2^53 - 1`
  (`../specs/reference.md` §13; `int53` in the corpus). An integer is held in
  a double, which is exact there. An integer literal outside the range is a
  parse error; in a context, an integer outside it (a `bigint`), a `NaN` or
  an infinity is a `TypeMismatch`; a result outside it is a
  `NotRepresentable`.
- **What comes back is in canonical form**: an integer is a plain `number`,
  and a float is a plain `number` unless its value is a safe integer, in
  which case it is a `Float`. So a host meets a `Float` only for a
  whole-valued float. `float(n)` builds that form, and `isInteger`,
  `isFloat` and `numberValue` read a number of either spelling.
- **`JSON.parse` and `JSON.stringify` lose the type**: they read `3.0` as `3`
  and write a `Float` as its plain number. `parseJson` types a number by its
  text (`3` is an integer; `3.0` and `3e0` are floats) and keeps the digits
  of an integer beyond the range as a `bigint`, for the decoder to refuse;
  `stringify` writes an integer as digits and a float with a fraction or an
  exponent.

```ts
import { parseJson, parseProgram, runProgram, stringify } from "@lucasdicioccio/tramaj-js";

const ctx = parseJson('{"qty": 3, "price": 9.0}');
stringify(runProgram("concrete", new Map(), ctx, parseProgram("[$ctx.qty, $ctx.price]"))); // [3,9.0]
```

## Arithmetic

The arithmetic profile (`../specs/reference.md` §11) is an option of each
evaluation, off by default. `runProgram` and `evalProgram` run without it:
there `sum`, `product`, `negate`, `quotient`, `inverse`, `floor-quotient`,
`modulo`, `floor`, `real` and `round` are unbound, so `sum(1, 2)` is an
`UnboundName`.
`runProgramWith` and `evalProgramWith` take an `Options` object:

```ts
runProgramWith({ mode: "concrete", arithmetic: true }, new Map(), null, parseProgram("sum(1, 2)")); // 3
```

Both fields are optional (`defaultOptions` is concrete mode, arithmetic
off), and the option applies to the root program and to every library it
runs. `round`, the tenth name of the profile, gives the integer nearest to the
exact value of its operand, ties away from zero, and is held to the integer
range like `floor`.

In symbolic mode with the profile on, a builtin applied to a symbol gives a
term, `{"$term": "sum", "arguments": [...]}` (`../specs/v3-symbols.md` §1.9),
which a host that left the profile off never receives. `arithmeticOps` and
`deepArithmeticOps` report which of the names a program references free, so
such a host can refuse a program before running it.

## Sorting and number formatting

`sort-by(list, fn)`, `sort-by-descending(list, fn)` and
`format-number(x, decimals, group)` (`../specs/reference.md` §11,
`../specs/decisions.md` §20) belong to the core language: they need no
option.

- **The two sorts are one AST constructor**, `SortBy`, with a `descending`
  flag. The key function is applied once per element, in index order, before
  anything is reordered. String keys are compared by Unicode code point,
  which is not the order of `<` on JavaScript strings (UTF-16 code units).
  The comparison ends on the element's index, so both sorts are stable
  without relying on the engine's sort.
- **`format-number` does not use `toFixed`**, whose range stops at `1e21` and
  which writes a negative zero. It rounds the exact value of the double with
  `BigInt` arithmetic, ties away from zero, so `format-number(1e23, 0, "")`
  is `99999999999999991611392`. `round` uses the same rounding.
- `emittedConstraintCount(options, libs, ctx, program)` returns how many
  constraints an evaluation emitted before equal ones are made one. It exists
  for tests: it is the only way to count how many times a function ran.

## Scripts

```
npm run build      # tsc -> dist/
npm run typecheck
npm test           # vitest: corpus parity + node-json + analysis + numbers + sort-format
```
