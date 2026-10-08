package tramaj

import (
	"math"
	"math/big"
	"testing"
)

// What the corpus has no shape for: how JSON text becomes the two number
// types and back, the arithmetic option and its default, the two arithmetic
// analyses, and integer arithmetic at the ends of the 64-bit range.

func TestParseJSONTypesANumberByItsText(t *testing.T) {
	cases := []struct {
		src  string
		want JSON
	}{
		{"3", int64(3)}, {"-7", int64(-7)}, {"-0", int64(0)},
		{"3.0", 3.0}, {"3e0", 3.0}, {"3E0", 3.0}, {"-0.0", 0.0}, {"1e-400", 0.0},
		{"9007199254740993", int64(9007199254740993)},
		{"9223372036854775807", int64(math.MaxInt64)},
		{"-9223372036854775808", int64(math.MinInt64)},
	}
	for _, c := range cases {
		got := mustJSON(t, c.src)
		if !JSONEqual(got, c.want) {
			t.Errorf("ParseJSON(%s) = %#v, want %#v", c.src, got, c.want)
		}
		if f, ok := got.(float64); ok && math.Signbit(f) {
			t.Errorf("ParseJSON(%s) is a negative zero", c.src)
		}
	}
	if JSONEqual(mustJSON(t, "3"), mustJSON(t, "3.0")) {
		t.Error("3 and 3.0 are two values")
	}
}

func TestNormalizeNumbersRefusesWhatIsNotAValue(t *testing.T) {
	// ParseJSON refuses no number; NormalizeNumbers is what does.
	beyond := mustJSON(t, `{"a": [9223372036854775808]}`)
	if n, ok := beyond.(*Object).m["a"].([]JSON)[0].(*big.Int); !ok || n.String() != "9223372036854775808" {
		t.Fatalf("an integer beyond 64 bits must be read exactly, got %#v", beyond)
	}
	for _, src := range []string{`{"a": [9223372036854775808]}`, `-9223372036854775809`, `[1e400]`, `{"k": -1e400}`} {
		if _, err := NormalizeNumbers(mustJSON(t, src)); err == nil {
			t.Errorf("NormalizeNumbers(%s) must be refused", src)
		}
	}
	for _, v := range []JSON{3, float32(1), math.NaN(), []JSON{math.Inf(1)}} {
		if _, err := NormalizeNumbers(v); err == nil {
			t.Errorf("NormalizeNumbers(%#v) must be refused", v)
		}
	}
	got, err := NormalizeNumbers([]JSON{math.Copysign(0, -1), int64(1), big.NewInt(2)})
	if err != nil || CompactJSON(got) != "[0.0,1,2]" {
		t.Errorf("got %v, %v", got, err)
	}

	// The context decoder and the node decoder both go through it.
	prog := mustParse(t, "1")
	_, err = RunProgram(Concrete, nil, mustJSON(t, `{"unread": 1e400}`), prog)
	if ee, ok := err.(*EvalError); !ok || ee.Kind != "TypeMismatch" {
		t.Errorf("a context holding 1e400: got %v, want TypeMismatch", err)
	}
	_, err = NodeFromJSON(mustJSON(t, `{"type":"text","value":9223372036854775808,"annotations":{}}`))
	if _, ok := err.(*NodeDecodeError); !ok {
		t.Errorf("a node holding an integer beyond 64 bits: got %v, want a NodeDecodeError", err)
	}
}

func TestNumbersKeepTheirTypeAsText(t *testing.T) {
	floats := []struct {
		n    float64
		want string
	}{
		{0, "0.0"}, {1, "1.0"}, {-2, "-2.0"}, {1.5, "1.5"}, {0.1, "0.1"},
		{1e11, "100000000000.0"}, {1e20, "100000000000000000000.0"}, {1e21, "1e+21"}, {1e-7, "1e-7"},
	}
	for _, c := range floats {
		if got := FormatFloat(c.n); got != c.want {
			t.Errorf("FormatFloat(%v) = %q, want %q", c.n, got, c.want)
		}
	}
	if got := FormatInteger(math.MinInt64); got != "-9223372036854775808" {
		t.Errorf("FormatInteger(-2^63) = %q", got)
	}
	// Text to value to text, for both types.
	src := `[1,1.0,-7,0.5,9223372036854775807,1e+21,{"k":100000000000.0}]`
	if got := CompactJSON(mustJSON(t, src)); got != src {
		t.Errorf("round trip: got %s, want %s", got, src)
	}
	if got := PrettyJSON(mustJSON(t, "[3, 3.0]")); got != "[\n  3,\n  3.0\n]" {
		t.Errorf("PrettyJSON: got %q", got)
	}
}

// runWith evaluates src and renders the result, or the error kind.
func runWith(t *testing.T, options Options, libs Libraries, ctx, src string) string {
	t.Helper()
	out, err := RunProgramWith(options, libs, mustJSON(t, ctx), mustParse(t, src))
	if err != nil {
		return err.(*EvalError).Kind
	}
	return CompactJSON(out)
}

func TestTheArithmeticProfileIsAnOptionOffByDefault(t *testing.T) {
	on := Options{Mode: Concrete, Arithmetic: true}
	expect(t, "DefaultOptions", DefaultOptions, Options{Mode: Concrete})
	expect(t, "off by default", runWith(t, DefaultOptions, nil, "null", "sum(1, 2)"), "UnboundName")
	expect(t, "on", runWith(t, on, nil, "null", "sum(1, 2)"), "3")

	// RunProgram and EvalProgram run without the profile.
	_, err := RunProgram(Concrete, nil, nil, mustParse(t, "sum(1, 2)"))
	expect(t, "RunProgram", err.(*EvalError).Kind, "UnboundName")
	_, err = EvalProgram(Concrete, nil, nil, mustParse(t, "sum(1, 2)"))
	expect(t, "EvalProgram", err.(*EvalError).Kind, "UnboundName")
	out, err := EvalProgramWith(on, nil, nil, mustParse(t, "real(2)"))
	if err != nil || !JSONEqual(out.Value, 2.0) {
		t.Errorf("EvalProgramWith: got %#v, %v", out, err)
	}

	// The two number types do not depend on it.
	expect(t, "str of both types", runWith(t, DefaultOptions, nil, "null", `[str(1), str(1.0), eq(1, 1.0)]`), `["1","1.0",false]`)
	expect(t, "a mixed comparison", runWith(t, DefaultOptions, nil, "null", `gt(1.5, 0)`), "TypeMismatch")

	// A library runs with the profile of the evaluation that reached it.
	libs := Libraries{"math": mustParse(t, "product($ctx.n, 2)")}
	expect(t, "library, on", runWith(t, on, libs, "null", `import("math", {n: 21}).rendered`), "42")
	expect(t, "library, off", runWith(t, DefaultOptions, libs, "null", `import("math", {n: 21}).rendered`), "InLibrary")

	// A binding shadows a builtin, with or without the profile.
	expect(t, "shadowed", runWith(t, DefaultOptions, nil, "null", "@sum = (a, b) => [$a, $b]\nsum(1, 2)"), "[1,2]")
}

func TestASeededTermNeedsBothProfiles(t *testing.T) {
	ctx := `{"t": {"$term": "sum", "arguments": [1, {"$sym": "#ctx.s", "path": []}]}}`
	symbolic := Options{Mode: Symbolic, Arithmetic: true}
	out, err := RunProgramWith(symbolic, nil, mustJSON(t, ctx), mustParse(t, "$ctx.t"))
	if err != nil {
		t.Fatal(err)
	}
	root, _ := out.(*Object).Get("root")
	expect(t, "round trip", CompactJSON(root), `{"$term":"sum","arguments":[1,{"$sym":"#ctx.s","path":[]}]}`)

	expect(t, "without arithmetic", runWith(t, Options{Mode: Symbolic}, nil, ctx, "1"), "TypeMismatch")
	expect(t, "in concrete mode", runWith(t, Options{Mode: Concrete, Arithmetic: true}, nil, ctx, "1"), "TypeMismatch")
	for label, bad := range map[string]string{
		"no symbol inside":   `{"$term": "sum", "arguments": [1, 2]}`,
		"an unknown op":      `{"$term": "ceiling", "arguments": [{"$sym": "#ctx.s", "path": []}]}`,
		"an array argument":  `{"$term": "sum", "arguments": [[{"$sym": "#ctx.s", "path": []}]]}`,
		"a third key":        `{"$term": "negate", "arguments": [{"$sym": "#ctx.s", "path": []}], "x": 1}`,
		"mixed number types": `{"$term": "sum", "arguments": [1, {"$sym": "#ctx.s", "path": []}, 2.0]}`,
	} {
		expect(t, label, runWith(t, symbolic, nil, bad, "1"), "TypeMismatch")
	}

	// "$term" is reserved in a program in every profile.
	if _, err := ParseProgram(`{"$term": 1}`); err == nil {
		t.Error(`{"$term": 1} must be a parse error`)
	}
}

func TestIntegerArithmeticAtTheEndsOfTheRange(t *testing.T) {
	on := Options{Mode: Concrete, Arithmetic: true}
	cases := []struct{ src, want string }{
		{"sum(9223372036854775806, 1)", "9223372036854775807"},
		{"sum(9223372036854775807, 1)", "NotRepresentable"},
		{"sum(-9223372036854775808, -1)", "NotRepresentable"},
		{"sum(9223372036854775807, 1, -1)", "NotRepresentable"},
		{"sum(9223372036854775807, -9223372036854775808)", "-1"},
		{"product(3037000499, 3037000499)", "9223372030926249001"},
		{"product(3037000500, 3037000500)", "NotRepresentable"},
		{"product(-9223372036854775808, -1)", "NotRepresentable"},
		{"product(-1, -9223372036854775808)", "NotRepresentable"},
		{"product(-9223372036854775808, 1)", "-9223372036854775808"},
		{"product(4611686018427387904, -2)", "-9223372036854775808"},
		{"product(4611686018427387904, 2)", "NotRepresentable"},
		{"product(4294967296, 4294967296, 0)", "NotRepresentable"},
		{"negate(-9223372036854775808)", "NotRepresentable"},
		{"negate(9223372036854775807)", "-9223372036854775807"},
		{"floor-quotient(-9223372036854775808, -1)", "NotRepresentable"},
		{"modulo(-9223372036854775808, -1)", "0"},
		{"floor-quotient(-9223372036854775808, 2)", "-4611686018427387904"},
		{"floor-quotient(-7, 2)", "-4"}, {"floor-quotient(7, -2)", "-4"}, {"floor-quotient(-7, -2)", "3"},
		{"modulo(-7, 2)", "1"}, {"modulo(7, -2)", "-1"}, {"modulo(-7, -2)", "-1"}, {"modulo(6, -2)", "0"},
		{"modulo(1, 0)", "NotRepresentable"}, {"floor-quotient(1, 0)", "NotRepresentable"},
		{"floor(-9223372036854775808.0)", "-9223372036854775808"},
		{"floor(9223372036854775808.0)", "NotRepresentable"},
		{"floor(9223372036854774784.0)", "9223372036854774784"},
		{"floor(-0.5)", "-1"},
		{"real(9007199254740993)", "9007199254740992.0"},
		{"real(9223372036854775807)", "9223372036854776000.0"},
		{"negate(0.0)", "0.0"}, {"product(-1.0, 0.0)", "0.0"}, {"sum(0.1, 0.2, 0.3)", "0.6000000000000001"},
		{"product(49.0, inverse(49.0))", "0.9999999999999999"}, {"quotient(49.0, 49.0)", "1.0"},
		{"sum(1e308, 1e308, \"a\")", "TypeMismatch"}, {"sum(1e308, 1e308)", "NotRepresentable"},
	}
	for _, c := range cases {
		if got := runWith(t, on, nil, "null", c.src); got != c.want {
			t.Errorf("%s = %s, want %s", c.src, got, c.want)
		}
	}
}

func TestArithmeticOps(t *testing.T) {
	expect(t, "names", ArithmeticNames, []string{
		"sum", "product", "negate", "quotient", "inverse", "floor-quotient", "modulo", "floor", "real", "round",
	})
	ops := func(src string) []string { return ArithmeticOps(mustParse(t, src)) }
	expect(t, "called and by reference", ops("[sum(1, 2), fold($ctx.xs, 0, $product)]"), []string{"product", "sum"})
	expect(t, "none", ops("cardinality($ctx.xs)"), []string{})
	expect(t, "shadowed by a binding", ops("@sum = (a) => $a\nsum(1)"), []string{})
	expect(t, "a binding's own right-hand side", ops("@sum = sum(1, 2)\n$sum"), []string{"sum"})
	expect(t, "shadowed by a parameter", ops("map($ctx.xs, (floor) => floor(1.5))"), []string{})
	expect(t, "a parameter's scope ends", ops("[map($ctx.xs, (floor) => $floor), floor(1.5)]"), []string{"floor"})
	expect(t, "shadowed by a pattern name", ops("@{real} = $ctx\nreal(1)"), []string{})
	expect(t, "under an unselected arm", ops("branch(1, false, negate(1))"), []string{"negate"})
	// round is the tenth name (decisions section 20).
	expect(t, "round", ops("round(1.5)"), []string{"round"})

	libs := Libraries{
		"a": mustParse(t, `[modulo(1, 2), import("b", {}).rendered]`),
		"b": mustParse(t, "@sum = 1\nreal($sum)"),
	}
	prog := mustParse(t, "@modulo = 1\n[import(\"a\", {}).rendered, negate($modulo)]")
	expect(t, "own", ArithmeticOps(prog), []string{"negate"})
	expect(t, "deep", DeepArithmeticOps(libs, prog), []string{"modulo", "negate", "real"})
	expect(t, "deep, missing library", DeepArithmeticOps(nil, prog), []string{"negate"})
}
