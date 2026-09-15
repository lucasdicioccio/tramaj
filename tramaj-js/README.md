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
| `eval` | `runProgram`, `evalProgram`, `toJson`; `Mode`, `LibraryTable`, `Value`, `Output`, `EvalError` |
| `node` | `Node`, `NodeAttribute`, `Annotations`; `nodeToJson`/`nodeFromJson`, `nodeAttributeToJson`/`nodeAttributeFromJson`, `mapActions`, `NodeDecodeError` |
| `analysis` | `staticImportNames`, `transitiveImportNames`, `staticActionKeys`, `deepActionKeys`, `contextHoles`, `deepContextHoles`, `contextReads`, `unsuppliedParams`, `constraintKinds`, `deepConstraintKinds`, `symbolSites`, `symbolDemands`, `deepSymbolDemands`, `typeDeclarations`, `typeParams`, `unsuppliedTypeParams`, `typeParamCollisions`, `programCard`, `programKind` |
| `types` | `resolveTypeExpr`, `canonicalId`, `requireClosed`, `typeClosure`, `eraseTypes`, `typeConstraints`, `deepTypeConstraints`, `typeReferences`, `deepTypeReferences`, `checkTypeParamCollisions`, `TypeError` |

```ts
import { parseProgram, runProgram } from "tramaj-js";

const program = parseProgram('.p($ctx.name)');
runProgram("concrete", new Map(), { name: "web" }, program);
```

A `LibraryTable` is a `Map<string, Program>`; a `Mode` is `"concrete"` or
`"symbolic"`. Every set-valued analysis returns a sorted array, so two runs
over the same program agree on order as well as membership.

## Scripts

```
npm run build      # tsc -> dist/
npm run typecheck
npm test           # vitest: corpus parity + node-json + analysis
```
