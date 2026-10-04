package tramaj

import (
	"math"
	"reflect"
	"testing"
)

// specs/reference.md section 9's analyses, which the corpus never reaches: it
// drives RunProgram only. Plus the str number rendering the language pins to
// ECMAScript's Number::toString.

func mustParse(t *testing.T, src string) *Program {
	t.Helper()
	prog, err := ParseProgram(src)
	if err != nil {
		t.Fatalf("%s: %v", src, err)
	}
	return prog
}

func expect(t *testing.T, what string, got, want any) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Errorf("%s: got %#v, want %#v", what, got, want)
	}
}

func TestActionKeys(t *testing.T) {
	// Adaptation is applied, not ignored.
	prog := mustParse(t, `adapt-actions(.div(action("on-click", "save", {}), action("on-click", "delete", {})), prefix("user:"))`)
	expect(t, "adapted", StaticActionKeys(prog), []string{"user:delete", "user:save"})

	prog = mustParse(t, `adapt-actions(adapt-actions(.div(action("on-click", "k", {})), prefix("a:")), prefix("b:"))`)
	expect(t, "composed", StaticActionKeys(prog), []string{"b:a:k"})

	// A binding is not followed through an adaptation.
	prog = mustParse(t, "@p=.div(action(\"on-click\", \"k\", {}))\nadapt-actions($p, prefix(\"a:\"))")
	expect(t, "through a binding", StaticActionKeys(prog), []string{"k"})
}

func TestDeepActionKeysFollowImports(t *testing.T) {
	libs := Libraries{"row": mustParse(t, `.li(action("on-click", "pick", {}))`)}
	prog := mustParse(t, `.ul(import("row", {}).rendered, import("gone", {}).rendered)`)
	expect(t, "deep keys", DeepActionKeys(libs, prog), []string{"pick"})
	expect(t, "static imports", StaticImportNames(prog), []string{"gone", "row"})
	expect(t, "transitive imports", TransitiveImportNames(libs, prog), []string{"gone", "row"})
}

func TestContextHolesVersusReads(t *testing.T) {
	prog := mustParse(t, `import("panel", {name: ctx(title), n: $ctx.count})`)
	expect(t, "holes", ContextHoles(prog), [][]string{{"title"}})
	expect(t, "reads", ContextReads(prog), [][]string{{"count"}, {"title"}})
}

func TestUnsuppliedParams(t *testing.T) {
	libs := Libraries{"panel": mustParse(t, ".section(.h1($ctx.title), .p($ctx.body.text))")}
	prog := mustParse(t, `import("panel", {"title": "x"}).rendered`)
	expect(t, "known library", UnsuppliedParams(libs, prog), []Unsupplied{{"panel", [][]string{{"body", "text"}}}})
	expect(t, "missing library", UnsuppliedParams(nil, mustParse(t, `import("gone", {}).rendered`)), []Unsupplied{{"gone", [][]string{}}})
}

func TestConstraintKindsAndAllocationSites(t *testing.T) {
	prog := mustParse(t, "!constraint(\"positive\", $ctx.n)\n[?(\"a\"), ?(\"b\")]")
	expect(t, "kinds", ConstraintKinds(prog), []string{"positive"})
	expect(t, "sites", SymbolSites(prog), []int{0, 1})
}

func TestCard(t *testing.T) {
	libs := Libraries{"row": mustParse(t, `.li(action("on-click", "pick", $ctx.id))`)}
	prog := mustParse(t, `.ul(map($ctx.items, (i) => import("row", {}).rendered))`)
	expect(t, "card", ProgramCard(libs, prog), Card{
		Produces:   "document",
		Requires:   [][]string{{"items"}},
		Imports:    []string{"row"},
		Emits:      []string{"pick"},
		Unsupplied: []Unsupplied{{"row", [][]string{{"id"}}}},
	})
}

func TestTypeAnalyses(t *testing.T) {
	libs := Libraries{"shapes": mustParse(t, "type Box = {item: %ctx.t}\nnull")}
	prog := mustParse(t, "@s = import(\"shapes\", {t: %number})\ntype Id = string\n@b : $s.types.Box = {item: 1}\n!type-constraint(\"sized\", %Id, 3)\n$b")
	expect(t, "declarations", TypeDeclarations(prog), []string{"Id"})
	expect(t, "library params", TypeParams(libs["shapes"]), [][]string{{"t"}})
	expect(t, "unsupplied type params", UnsuppliedTypeParams(libs, prog), []Unsupplied{{"shapes", [][]string{}}})

	refs, err := TypeReferences(libs, prog)
	expect(t, "references error", err, nil)
	expect(t, "references", refs, []string{`"shapes":Box[t=number]`, "number", "root:Id", "string"})

	tcs, err := TypeConstraints(libs, prog)
	expect(t, "constraints error", err, nil)
	if len(tcs) != 1 || tcs[0].Name != "sized" || CompactJSON(tcs[0].Arguments) != `[{"$type":"root:Id"},3]` {
		t.Errorf("constraints: got %#v", tcs)
	}

	_, err = TypeReferences(nil, mustParse(t, "@x : Missing = 1\n$x"))
	if te, ok := err.(*TypeError); !ok || te.Kind != "UnresolvedType" {
		t.Errorf("an undeclared type name: got %v, want UnresolvedType", err)
	}
}

func TestFormatNumberRendersLikeECMAScript(t *testing.T) {
	tenth, fifth := 0.1, 0.2 // variables: a constant sum would be exact
	cases := []struct {
		n    float64
		want string
	}{
		{0, "0"}, {math.Copysign(0, -1), "0"}, {1, "1"}, {-2.0, "-2"}, {1.5, "1.5"},
		{tenth + fifth, "0.30000000000000004"}, {1e21, "1e+21"}, {1e20, "100000000000000000000"},
		{1e-7, "1e-7"}, {0.000001, "0.000001"}, {123456789012345680000, "123456789012345680000"},
		{1 << 53, "9007199254740992"}, {math.MaxFloat64, "1.7976931348623157e+308"},
		{5e-324, "5e-324"}, {-1.5e-9, "-1.5e-9"},
	}
	for _, c := range cases {
		if got := FormatNumber(c.n); got != c.want {
			t.Errorf("FormatNumber(%v) = %q, want %q", c.n, got, c.want)
		}
	}
}
