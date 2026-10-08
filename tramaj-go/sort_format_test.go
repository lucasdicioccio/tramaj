package tramaj

import (
	"math"
	"math/rand"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// What the corpus cannot state about sort-by, sort-by-descending,
// format-number and round (specs/decisions.md section 20): that the key
// function is applied once per element, which no program can observe; that
// the analyses see inside a key function; the parser's lowering; and a
// comparison of the rounding with the standard library away from ties.

func TestSortNamesLowerToOneConstructor(t *testing.T) {
	list := &Path{Root: "ctx", Fields: []string{"xs"}}
	key := &Lambda{Params: []string{"x"}, Body: &Path{Root: "x", Fields: []string{"k"}}}
	for _, c := range []struct {
		src        string
		descending bool
	}{
		{"sort-by($ctx.xs, (x) => $x.k)", false},
		{"sort-by-descending($ctx.xs, (x) => $x.k)", true},
		{"$sort-by($ctx.xs, (x) => $x.k)", false},
		{"$sort-by-descending($ctx.xs, (x) => $x.k)", true},
	} {
		want := &SortBy{Descending: c.descending, Collection: list, Fn: key}
		if got := mustParse(t, c.src).Root; !reflect.DeepEqual(got, want) {
			t.Errorf("%s: got %#v, want %#v", c.src, got, want)
		}
	}

	// A function by reference, and a field access on the result.
	got := mustParse(t, "sort-by-descending($ctx.xs, $key).first").Root
	want := &FieldAccess{
		Target: &SortBy{Descending: true, Collection: list, Fn: &Path{Root: "key"}},
		Fields: []string{"first"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("a field access after a sort: got %#v, want %#v", got, want)
	}
}

func TestAMalformedSortIsAParseError(t *testing.T) {
	for _, src := range []string{
		// An argument count other than two.
		"sort-by($ctx.xs)",
		"sort-by($ctx.xs, (x) => $x, 1)",
		"sort-by()",
		"sort-by-descending($ctx.xs)",
		"sort-by-descending($ctx.xs, (x) => $x, 1)",
		// A sort name passed by reference, as map cannot be.
		"$sort-by",
		"$sort-by-descending",
		"map($ctx.xs, $sort-by)",
		"@s = $sort-by-descending\n$s",
		"[sort-by]",
	} {
		_, err := ParseProgram(src)
		if _, ok := err.(*ParseError); !ok {
			t.Errorf("%s: got %v, want a parse error", src, err)
		}
	}
	// The two names are special forms, so a binding of the same name is not
	// what a call reaches.
	expect(t, "a binding does not shadow the form",
		runWith(t, DefaultOptions, nil, "null", "@sort-by = (a, b) => 1\nsort-by([2, 1], (x) => $x)"), "[1,2]")
}

// The key function emits a constraint each time it runs, and the emissions
// are counted before equal ones are made one: the elements of a list are
// often equal, so the deduplicated list would hide a second application.
func TestTheKeyFunctionIsAppliedOncePerElementInIndexOrder(t *testing.T) {
	keyFn := &Lambda{Params: []string{"x"}, Body: &Emit{
		Constraint: &Constrain{Name: "seen", Args: []Expr{&Path{Root: "x", Fields: []string{}}}},
		Body:       &Path{Root: "x", Fields: []string{}},
	}}
	lists := map[string][]int64{
		"empty":       {},
		"one element": {7},
		"ordered":     {1, 2, 3, 4, 5, 6, 7, 8},
		"reversed":    {8, 7, 6, 5, 4, 3, 2, 1},
		"shuffled":    {5, 1, 8, 3, 7, 2, 6, 4, 9, 0, 11, 10, 15, 13, 12, 14, 16},
		"all equal":   {4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4},
		"duplicates":  {2, 1, 2, 1, 3, 3, 1, 2},
	}
	for label, xs := range lists {
		for _, descending := range []bool{false, true} {
			elems := make([]Expr, len(xs))
			for i, x := range xs {
				elems[i] = &IntLit{Value: x}
			}
			c := &evalCtx{mode: Concrete, isRoot: true, em: &emissions{}}
			out := c.eval(initialEnv(false, vNull{}), &SortBy{Descending: descending, Collection: &ArrayLit{Elements: elems}, Fn: keyFn})

			if len(c.em.constraints) != len(xs) {
				t.Errorf("%s, descending %v: the key function ran %d time(s) for %d element(s)", label, descending, len(c.em.constraints), len(xs))
				continue
			}
			for i, emitted := range c.em.constraints {
				if emitted.args[0] != vInt(xs[i]) {
					t.Errorf("%s, descending %v: application %d was of %v, want %d", label, descending, i, emitted.args[0], xs[i])
				}
			}
			sorted := out.(vArray)
			for i := 1; i < len(sorted); i++ {
				a, b := sorted[i-1].(vInt), sorted[i].(vInt)
				if (!descending && a > b) || (descending && a < b) {
					t.Errorf("%s, descending %v: not in order: %v", label, descending, sorted)
					break
				}
			}
		}
	}
}

func TestSortsAreStableOnTheirOwnTerms(t *testing.T) {
	ctx := `{"rows": [
		{"n": "a", "k": 2}, {"n": "b", "k": 1}, {"n": "c", "k": 2}, {"n": "d", "k": 1}, {"n": "e", "k": 2}
	]}`
	names := func(src string) string {
		return runWith(t, DefaultOptions, nil, ctx, "map("+src+", (r) => $r.n)")
	}
	expect(t, "ascending", names("sort-by($ctx.rows, (r) => $r.k)"), `["b","d","a","c","e"]`)
	// Not the reversal of the ascending sort, which would reverse the ties.
	expect(t, "descending", names("sort-by-descending($ctx.rows, (r) => $r.k)"), `["a","c","e","b","d"]`)

	// Enough elements, in few groups, that an unstable algorithm would show.
	var src strings.Builder
	src.WriteString("[")
	for i := 0; i < 200; i++ {
		if i > 0 {
			src.WriteString(",")
		}
		src.WriteString(`{"i":` + strconv.Itoa(i) + `,"k":` + strconv.Itoa((i*7)%5) + `}`)
	}
	src.WriteString("]")
	for _, form := range []string{"sort-by", "sort-by-descending"} {
		prog := mustParse(t, form+"($ctx, (r) => $r.k)")
		out, err := RunProgram(Concrete, nil, mustJSON(t, src.String()), prog)
		if err != nil {
			t.Fatal(err)
		}
		rows := out.([]JSON)
		for at := 1; at < len(rows); at++ {
			pk, _ := rows[at-1].(*Object).Get("k")
			pi, _ := rows[at-1].(*Object).Get("i")
			k, _ := rows[at].(*Object).Get("k")
			i, _ := rows[at].(*Object).Get("i")
			if pk.(int64) == k.(int64) && pi.(int64) > i.(int64) {
				t.Errorf("%s: equal keys out of input order at %d", form, at)
			}
		}
	}
}

func TestStringKeysCompareByCodePoint(t *testing.T) {
	// U+FF5E sorts before U+1F600 by code point, and after it by UTF-16 code
	// unit, which is the order this port's own lessUTF16 gives.
	if !lessUTF16("\U0001F600", "～") {
		t.Fatal("the two characters do not tell the two orders apart")
	}
	expect(t, "ascending", runWith(t, DefaultOptions, nil, "null",
		"sort-by([\"\U0001F600\", \"～\", \"a\", \"\"], (s) => $s)"), "[\"\",\"a\",\"～\",\"\U0001F600\"]")
	expect(t, "descending", runWith(t, DefaultOptions, nil, "null",
		"sort-by-descending([\"～\", \"\U0001F600\", \"ab\", \"a\"], (s) => $s)"), "[\"\U0001F600\",\"～\",\"ab\",\"a\"]")
}

func TestTheAnalysesSeeInsideAKeyFunction(t *testing.T) {
	for _, form := range []string{"sort-by", "sort-by-descending"} {
		prog := mustParse(t, form+`($ctx.rows, (r) => [
			sum($r.n, $ctx.offset),
			import("weights", {w: ctx(weight), n: $r.n}).rendered,
			.span(action("on-click", "pick", {})),
			?ctx.wanted.depth,
			?("key"),
			constraint("capped", $r.n)
		])`)
		libs := Libraries{
			"weights": mustParse(t, `[import("deeper", {}).rendered, .b(action("on-click", "deep", {})), floor($ctx.w), import("deeper", {v: ctx(below)}).rendered, ?ctx.far]`),
			"deeper":  mustParse(t, "1"),
		}
		expect(t, form+": contextReads", ContextReads(prog), [][]string{{"offset"}, {"rows"}, {"weight"}})
		expect(t, form+": contextHoles", ContextHoles(prog), [][]string{{"weight"}})
		expect(t, form+": staticImportNames", StaticImportNames(prog), []string{"weights"})
		expect(t, form+": transitiveImportNames", TransitiveImportNames(libs, prog), []string{"deeper", "weights"})
		expect(t, form+": staticActionKeys", StaticActionKeys(prog), []string{"pick"})
		expect(t, form+": deepActionKeys", DeepActionKeys(libs, prog), []string{"deep", "pick"})
		expect(t, form+": arithmeticOps", ArithmeticOps(prog), []string{"sum"})
		expect(t, form+": deepArithmeticOps", DeepArithmeticOps(libs, prog), []string{"floor", "sum"})
		expect(t, form+": symbolDemands", SymbolDemands(prog), [][]string{{"wanted", "depth"}})
		expect(t, form+": deepSymbolDemands", DeepSymbolDemands(libs, prog), [][]string{{"far"}, {"wanted", "depth"}})
		expect(t, form+": symbolSites", SymbolSites(prog), []int{0})
		expect(t, form+": constraintKinds", ConstraintKinds(prog), []string{"capped"})
		expect(t, form+": unsuppliedParams", UnsuppliedParams(libs, prog), []Unsupplied{{"weights", [][]string{{"below"}}}})

		// The collection is seen as well as the function.
		expect(t, form+": the collection", ArithmeticOps(mustParse(t, form+"(map($ctx.xs, $negate), (x) => $x)")), []string{"negate"})
		// A key function passed by reference is a read of that name.
		expect(t, form+": by reference", ArithmeticOps(mustParse(t, form+"($ctx.xs, $round)")), []string{"round"})
		// Its parameter is a binding like any other lambda's.
		expect(t, form+": a shadowing parameter", ArithmeticOps(mustParse(t, form+"($ctx.xs, (round) => round(1.5))")), []string{})
	}

	// Allocation sites are numbered through a sort, in source order.
	prog := mustParse(t, `[?("a"), sort-by([?("b")], (x) => ?("c")), ?("d")]`)
	expect(t, "symbolSites", SymbolSites(prog), []int{0, 1, 2, 3})
}

func TestFormatNumberIsAnOrdinaryBuiltin(t *testing.T) {
	run := func(src string) string { return runWith(t, DefaultOptions, nil, "null", src) }
	// No profile is needed for it.
	expect(t, "without arithmetic", run(`format-number(1234567.891, 2, ",")`), `"1,234,567.89"`)
	expect(t, "by reference", run("@f = $format-number\n$f(2.5, 0, \"\")"), `"3"`)
	expect(t, "shadowed", run("@format-number = (x, d, g) => \"mine\"\nformat-number(2.5, 0, \"\")"), `"mine"`)
	expect(t, "under map", run(`map([1, 22, 333], (x) => format-number($x, 1, ""))`), `["1.0","22.0","333.0"]`)

	// Left to right: the first argument that is not acceptable decides.
	symbolic := Options{Mode: Symbolic}
	sym := `{"s": {"$sym": "#ctx.s", "path": []}}`
	expect(t, "a bad x before a symbol", runWith(t, symbolic, nil, sym, `format-number("a", $ctx.s, $ctx.s)`), "TypeMismatch")
	expect(t, "a symbol before bad decimals", runWith(t, symbolic, nil, sym, `format-number($ctx.s, 2.0, 1)`), "NotConcrete")
	expect(t, "bad decimals before a symbol", runWith(t, symbolic, nil, sym, `format-number(1, 21, $ctx.s)`), "TypeMismatch")
	expect(t, "a symbol as the group", runWith(t, symbolic, nil, sym, `format-number(1, 2, $ctx.s)`), "NotConcrete")
}

// Away from an exact tie the rule is the one strconv follows (the decimal
// nearest to the exact value), so the two agree on every double that is not
// halfway, once strconv's negative zero is dropped. The ties, where they
// differ, are in the table below and in the corpus.
func TestFormatNumberAgreesWithTheExactValue(t *testing.T) {
	rng := rand.New(rand.NewSource(20))
	unsigned := func(s string) string {
		if strings.Trim(s, "-0.") == "" {
			return strings.TrimPrefix(s, "-")
		}
		return s
	}
	check := func(x float64, decimals int) {
		t.Helper()
		// Skip the exact ties: x * 10^decimals * 2 is then an odd integer.
		if isTie(x, decimals) {
			return
		}
		want := unsigned(strconv.FormatFloat(x, 'f', decimals, 64))
		if got := formatFloatForTest(x, decimals, ""); got != want {
			t.Fatalf("format-number(%v, %d): got %s, want %s", x, decimals, got, want)
		}
	}
	for i := 0; i < 20000; i++ {
		decimals := rng.Intn(21)
		// Any bit pattern that is a finite double.
		if x := math.Float64frombits(rng.Uint64()); !math.IsNaN(x) && !math.IsInf(x, 0) {
			check(x, decimals)
		}
		// Ordinary magnitudes, and values written with a few decimals, whose
		// doubles sit just beside a tie.
		check((rng.Float64()-0.5)*math.Pow(10, float64(rng.Intn(12))), decimals)
		check(float64(rng.Intn(2000000)-1000000)/1000, decimals)
	}

	ties := []struct {
		x        float64
		decimals int
		want     string
	}{
		{0.5, 0, "1"}, {1.5, 0, "2"}, {2.5, 0, "3"}, {-2.5, 0, "-3"}, {-0.5, 0, "-1"},
		{0.125, 2, "0.13"}, {-0.125, 2, "-0.13"}, {0.25, 1, "0.3"}, {0.375, 2, "0.38"},
		{1234.5, 0, "1235"}, {999999.5, 0, "1000000"}, {0.0625, 3, "0.063"},
		{2251799813685249.5, 0, "2251799813685250"},
	}
	for _, c := range ties {
		if !isTie(c.x, c.decimals) {
			t.Errorf("%v to %d decimals is not a tie", c.x, c.decimals)
		}
		if got := formatFloatForTest(c.x, c.decimals, ""); got != c.want {
			t.Errorf("format-number(%v, %d): got %s, want %s", c.x, c.decimals, got, c.want)
		}
	}

	// Grouping never touches the digits.
	for i := 0; i < 2000; i++ {
		x := (rng.Float64() - 0.5) * math.Pow(10, float64(rng.Intn(25)))
		decimals := rng.Intn(21)
		plain := formatFloatForTest(x, decimals, "")
		grouped := formatFloatForTest(x, decimals, "_")
		if strings.ReplaceAll(grouped, "_", "") != plain {
			t.Fatalf("format-number(%v, %d): grouped %s, plain %s", x, decimals, grouped, plain)
		}
		whole := strings.TrimPrefix(strings.SplitN(grouped, ".", 2)[0], "-")
		for at, part := range strings.Split(whole, "_") {
			if len(part) > 3 || len(part) == 0 || (at > 0 && len(part) != 3) {
				t.Fatalf("format-number(%v, %d): groups of %s", x, decimals, grouped)
			}
		}
	}
}

func formatFloatForTest(x float64, decimals int, group string) string {
	return string(evalBuiltin("format-number", []value{vFloat(x), vInt(decimals), vStr(group)}).(vStr))
}

// isTie reports whether x is exactly halfway between two multiples of
// 10^-decimals. Only a double with few fraction bits can be: its fraction
// must be a multiple of 2^-(decimals+1), since 10^decimals * 2 * x is then an
// integer. That is tested on the bits of x, without rounding anything.
func isTie(x float64, decimals int) bool {
	frac, exp := math.Frexp(math.Abs(x)) // x = frac * 2^exp, frac in [0.5, 1)
	if x == 0 {
		return false
	}
	mant := uint64(frac * (1 << 53)) // exact: 53 bits
	e := exp - 53                    // x = mant * 2^e
	for mant%2 == 0 {
		mant /= 2
		e++
	}
	// x is odd * 2^e. x * 2 * 10^decimals is an odd integer exactly when
	// e + 1 + decimals == 0 for the power of two, and nothing else is needed
	// from the power of five: a negative e needs e + 1 >= -decimals for an
	// integer, and oddness needs equality.
	return e+1+decimals == 0
}

func TestRoundIsTheTenthArithmeticName(t *testing.T) {
	on := Options{Mode: Concrete, Arithmetic: true}
	expect(t, "off by default", runWith(t, DefaultOptions, nil, "null", "round(2.5)"), "UnboundName")
	cases := []struct{ src, want string }{
		{"round(2.5)", "3"}, {"round(-2.5)", "-3"}, {"round(0.5)", "1"}, {"round(-0.5)", "-1"},
		{"round(-0.4)", "0"}, {"round(0.49999999999999994)", "0"}, {"round(1.4999999999999998)", "1"},
		{"round(7)", "7"}, {"round(-9223372036854775808)", "-9223372036854775808"},
		{"round(2251799813685249.5)", "2251799813685250"},
		{"round(-9223372036854775808.0)", "-9223372036854775808"},
		{"round(9223372036854774784.0)", "9223372036854774784"},
		{"round(9223372036854775808.0)", "NotRepresentable"},
		{"round(-9223372036854777856.0)", "NotRepresentable"},
		{"round(1e19)", "NotRepresentable"},
		{"round(\"a\")", "TypeMismatch"}, {"round([1.5])", "TypeMismatch"}, {"round(1.5, 2.5)", "TypeMismatch"},
		{"map([0.5, 1.5, -1.5], $round)", "[1,2,-2]"},
		{"@round = (x) => \"mine\"\nround(2.5)", `"mine"`},
	}
	for _, c := range cases {
		if got := runWith(t, on, nil, "null", c.src); got != c.want {
			t.Errorf("%s = %s, want %s", c.src, got, c.want)
		}
	}

	// A term over a symbol, and a seeded round term accepted back.
	symbolic := Options{Mode: Symbolic, Arithmetic: true}
	sym := `{"s": {"$sym": "#ctx.s", "path": []}}`
	out, err := RunProgramWith(symbolic, nil, mustJSON(t, sym), mustParse(t, "round($ctx.s)"))
	if err != nil {
		t.Fatal(err)
	}
	root, _ := out.(*Object).Get("root")
	term := `{"$term":"round","arguments":[{"$sym":"#ctx.s","path":[]}]}`
	expect(t, "a term", CompactJSON(root), term)
	out, err = RunProgramWith(symbolic, nil, mustJSON(t, `{"t": `+term+`}`), mustParse(t, "sum($ctx.t, 1)"))
	if err != nil {
		t.Fatal(err)
	}
	root, _ = out.(*Object).Get("root")
	expect(t, "a seeded term", CompactJSON(root), `{"$term":"sum","arguments":[`+term+`,1]}`)
	expect(t, "a seeded term of two arguments", runWith(t, symbolic, nil,
		`{"t": {"$term": "round", "arguments": [{"$sym": "#ctx.s", "path": []}, 1.5]}}`, "1"), "TypeMismatch")

	// For a float whose rounding is in range, str(round(x)) and
	// format-number(x, 0, "") are the same text (specs/laws.md).
	rng := rand.New(rand.NewSource(11))
	for i := 0; i < 5000; i++ {
		x := (rng.Float64() - 0.5) * math.Pow(10, float64(rng.Intn(18)))
		if i%4 == 0 {
			x = math.Trunc(x) + 0.5
		}
		rounded := evalBuiltin("round", []value{vFloat(x)}).(vInt)
		if got, want := FormatInteger(int64(rounded)), formatFloatForTest(x, 0, ""); got != want {
			t.Fatalf("round(%v) is %s and format-number gives %s", x, got, want)
		}
	}
}
