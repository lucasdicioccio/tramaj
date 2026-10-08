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
| `eval.go` | `RunProgram`, `EvalProgram`, `RunProgramWith`, `EvalProgramWith`, `Options`, `DefaultOptions`, `Output`, `Mode` (`Concrete`, `Symbolic`), `EvalError` |
| `node.go` | `Node`, `NodeAttribute`; `NodeToJSON`/`NodeFromJSON`, `NodeAttributeToJSON`/`NodeAttributeFromJSON`, `NodeDecodeError` |
| `analysis.go` | `StaticImportNames`, `TransitiveImportNames`, `StaticActionKeys`, `DeepActionKeys`, `ContextHoles`, `DeepContextHoles`, `ContextReads`, `UnsuppliedParams`, `ArithmeticNames`, `ArithmeticOps`, `DeepArithmeticOps`, `ConstraintKinds`, `DeepConstraintKinds`, `SymbolSites`, `SymbolDemands`, `DeepSymbolDemands`, `TypeDeclarations`, `TypeParams`, `UnsuppliedTypeParams`, `TypeParamCollisions`, `ProgramCard` |
| `types.go` | `ResolveTypeExpr`, `CanonicalID`, `TypeConstraints`, `DeepTypeConstraints`, `TypeReferences`, `DeepTypeReferences`, `CheckTypeParamCollisions`, `TypeError` |
| `jsonval.go` | `JSON`, `Object`, `ParseJSON`, `NormalizeNumbers`, `JSONEqual`, `CompactJSON`, `DisplayString`, `FormatInteger`, `FormatFloat`, `FormatNumber`, `PrettyJSON` |

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

A `tramaj.JSON` value is `nil`, `bool`, `int64`, `float64`, `string`,
`[]tramaj.JSON` or `*tramaj.Object`. `Object` keeps its keys in insertion
order, which is why the package has its own `ParseJSON` rather than decoding
into `map[string]any`.

## Numbers

Integers and floats are two types (`../specs/reference.md` §3), and nothing
converts one into the other except the `real` and `floor` builtins.

- **In Go, the type of the value says which.** An `int64` is an integer and a
  `float64` is a float: `int64(3)` and `float64(3)` are two values, and
  `JSONEqual` never equates them. No other Go numeric type is a JSON value, so
  a host that builds a context by hand converts an `int` to `int64` itself; a
  context holding anything else is a `TypeMismatch`.
- **Integer range: signed 64-bit**, `-2^63` to `2^63 - 1` (reference §13). An
  integer literal outside it is a parse error, an integer-form number outside
  it in the context is a `TypeMismatch`, and an arithmetic result outside it
  is a `NotRepresentable`. Nothing wraps or rounds.
- **`ParseJSON` types a number by its text**: `3` is an integer, `3.0` and
  `3e0` are floats, and an integer keeps its digits beyond 2^53. Do not read a
  context with `encoding/json` into `any`: it makes every number a `float64`,
  so every number becomes a float.
- **`ParseJSON` refuses no number.** An integer-form number outside the range
  is read as a `*big.Int` and a float too large for a double as an infinity.
  `NormalizeNumbers` is what refuses both, and the context decoder and
  `NodeFromJSON` go through it, so a context holding `1e400` is a
  `TypeMismatch` from evaluation and not an error from the JSON reader.
- **Written, a number keeps its type.** An integer is its digits; a float is
  the shortest round-trip text of ECMAScript's `Number::toString` with `.0`
  appended when that text has neither a fraction nor an exponent (`1.0`,
  `100000000000.0`, `1e+21`). `str`, `CompactJSON` and `PrettyJSON` all write
  this way; `FormatInteger` and `FormatFloat` are the two rules, and
  `FormatNumber` is `Number::toString` alone.
- `eq(1, 1.0)` is `false`, and `lt`/`lte`/`gt`/`gte` take two integers or two
  floats. `int` and `float` are the v4 type primitives; `number` is not one.

## Arithmetic

The arithmetic profile (reference §11) is an option of each evaluation, off
by default. This port has its nine names other than `round`: `sum`,
`product`, `negate`, `quotient`, `inverse`, `floor-quotient`, `modulo`,
`floor` and `real` (`tramaj.ArithmeticNames`).

```go
opts := tramaj.Options{Mode: tramaj.Concrete, Arithmetic: true}
out, err := tramaj.RunProgramWith(opts, nil, ctx, program)
```

`RunProgram` and `EvalProgram` run with the profile off, where those names
are unbound and `sum(1, 2)` is an `UnboundName`. The option applies to the
root program and to every library the evaluation runs. A host that leaves it
off can refuse a program beforehand: `DeepArithmeticOps(libs, program)` lists
the arithmetic names the program and its libraries reference free.

An operation with no result in the type of its operands (integer overflow, a
zero divisor, a float result that is not finite) is an `*EvalError` of kind
`NotRepresentable`. Integer results are checked at every step of a fold;
float results are one `float64` operation at a time, with no fused
multiply-add and no negative zero.

In symbolic mode, a builtin given a symbol builds a term instead of
computing, written `{"$term": <op>, "arguments": [...]}` with its operands as
written (`../specs/v3-symbols.md` §1.9). `"$term"` is a reserved object key
in every profile, and a context may seed a well-formed term only in symbolic
mode with the profile on.

## Command line

The same shape as `tramaj-cli-rs` and `python -m tramaj`:

```
go build ./cmd/tramaj-go
./tramaj-go [evaluate] [--lib name=path ...] [--mode concrete|symbolic] [--arithmetic] <template-file> <context-json-file>
./tramaj-go analyze <imports|actions|holes|unsupplied|constraints|symbols|types|arithmetic|card|all> <template-file> [--lib name=path ...]
```

`--arithmetic` turns the arithmetic profile on for the run. When an evaluation
fails without it and the program references an arithmetic name, the error
lists those names and names the flag. `analyze arithmetic` prints
`DeepArithmeticOps`, and `analyze all` carries it under `"arithmetic"`.

Evaluation prints the result JSON on stdout: the node-json document, the plain
value, or the symbolic envelope. A parse error exits 2 and an evaluation error
exits 1, each printed on stderr leading with the error kind.

## Tests

```
go test ./...
```

`corpus_test.go` runs every case under `../corpus/cases` in the mode its
`meta.json` names, with the arithmetic profile on only for a case that lists
`arithmetic`. It provides the profiles `base`, `int-float`, `arithmetic` and
`int64`, and skips a case that lists any other (`go test -v` shows each as
`--- SKIP` with what was not provided). `node_test.go` covers the decoder's
rejection list and the round-trip law; `analysis_test.go` covers the analyses
and `Number::toString`; `arithmetic_test.go` covers how JSON text becomes the
two number types and back, the arithmetic option and its default, the two
arithmetic analyses, and integer arithmetic at the ends of the 64-bit range.
