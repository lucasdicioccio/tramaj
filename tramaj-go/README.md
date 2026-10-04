# tramaj-go

Go port of the Tramaj language: parser, evaluator (concrete and symbolic
modes), the normative `Node` JSON codec, and the static analyses. Hand-written,
not generated from `tramaj/` (PureScript), `tramaj-hs/` (Haskell),
`tramaj-rs/` (Rust), `tramaj-js/` (TypeScript) or `tramaj-py/` (Python);
agreement with those is enforced by the shared corpus at `../corpus/cases`,
which `corpus_test.go` reads directly. Standard library only, Go 1.21+.

Specs: `../specs/reference.md`, `../specs/node-json.md`,
`../specs/v3-symbols.md`, `../specs/v4-types.md`.

## Public API

One package, `tramaj`. The files mirror `tramaj-py/tramaj/*.py` one-to-one.

| file | exports |
|---|---|
| `ast.go` | `Program`, the `Expr`/`TypeExpr`/`Attribute`/`ParamValue` node types, `Stmt`; `SubExprs`, `Unlets` |
| `parser.go` | `ParseProgram`, `ParseError` |
| `eval.go` | `RunProgram`, `EvalProgram`, `Output`, `Mode` (`Concrete`, `Symbolic`), `EvalError` |
| `node.go` | `Node`, `NodeAttribute`; `NodeToJSON`/`NodeFromJSON`, `NodeAttributeToJSON`/`NodeAttributeFromJSON`, `NodeDecodeError` |
| `analysis.go` | `StaticImportNames`, `TransitiveImportNames`, `StaticActionKeys`, `DeepActionKeys`, `ContextHoles`, `DeepContextHoles`, `ContextReads`, `UnsuppliedParams`, `ConstraintKinds`, `DeepConstraintKinds`, `SymbolSites`, `SymbolDemands`, `DeepSymbolDemands`, `TypeDeclarations`, `TypeParams`, `UnsuppliedTypeParams`, `TypeParamCollisions`, `ProgramCard` |
| `types.go` | `ResolveTypeExpr`, `CanonicalID`, `TypeConstraints`, `DeepTypeConstraints`, `TypeReferences`, `DeepTypeReferences`, `CheckTypeParamCollisions`, `TypeError` |
| `jsonval.go` | `JSON`, `Object`, `ParseJSON`, `JSONEqual`, `CompactJSON`, `DisplayString`, `FormatNumber`, `PrettyJSON` |

```go
import tramaj "github.com/lucasdicioccio/tramaj/tramaj-go"

program, err := tramaj.ParseProgram(`.p($ctx.name)`)
ctx, _ := tramaj.ParseJSON([]byte(`{"name": "web"}`))
out, err := tramaj.RunProgram(tramaj.Concrete, nil, ctx, program)
fmt.Println(tramaj.CompactJSON(out))
// {"annotations":{},"attributes":[],"children":[{"annotations":{},"type":"text","value":"web"}],"tag":"p","type":"element","value":null}
```

A library table is a `tramaj.Libraries`, a map from import name to parsed
program. Errors are returned, never panicked: `*ParseError` from parsing,
`*EvalError` from evaluation (its `Kind` is the error kind the corpus names),
`*TypeError` from the type analyses. Every set-valued analysis returns a sorted
slice, so two runs over the same program agree on order as well as membership.

A `tramaj.JSON` value is `nil`, `bool`, `float64`, `string`, `[]tramaj.JSON` or
`*tramaj.Object`. `Object` keeps its keys in insertion order, which is why the
package has its own `ParseJSON` rather than decoding into `map[string]any`.
Every number is a `float64`, as the language specifies, and
`str`/`FormatNumber` render exactly as ECMAScript's `Number::toString` does
(`1e21` → `1e+21`, `-2.0` → `-2`).

## Command line

The same shape as `tramaj-cli-rs` and `python -m tramaj`:

```
go build ./cmd/tramaj-go
./tramaj-go [evaluate] [--lib name=path ...] [--mode concrete|symbolic] <template-file> <context-json-file>
./tramaj-go analyze <imports|actions|holes|unsupplied|constraints|symbols|types|card|all> <template-file> [--lib name=path ...]
```

Evaluation prints the result JSON on stdout: the node-json document, the plain
value, or the symbolic envelope. A parse error exits 2 and an evaluation error
exits 1, each printed on stderr leading with the error kind.

## Tests

```
go test ./...
```

`corpus_test.go` runs every case under `../corpus/cases` in the mode its
`meta.json` names; `node_test.go` covers the decoder's rejection list and the
round-trip law; `analysis_test.go` covers the analyses and the number
rendering.
