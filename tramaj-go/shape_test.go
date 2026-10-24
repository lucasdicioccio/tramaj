package tramaj

import (
	"errors"
	"testing"
)

// ?shape(key, shape) and its ~name markers (v3-symbols.md section 1.2,
// decisions section 19), where the shared corpus has no shape for the check:
// the AST the form lowers to, its site numbering, the parse errors one by one,
// and SymbolSites.

func shapeMarkerAt(site int, name string, key ...Expr) Expr {
	elements := append([]Expr{&Path{Root: shapeKeyName}, &StringLit{Value: name}}, key...)
	return &Alloc{Site: site, Key: &ArrayLit{Elements: elements}}
}

func TestShapeLowersToAHiddenBinding(t *testing.T) {
	prog := mustParse(t, `?shape("d", {~replicas, ports: [~http($x)]})`)
	expect(t, "lowered", prog.Root, Expr(&Let{
		Name:  shapeKeyName,
		Value: &StringLit{Value: "d"},
		Body: &ObjectLit{Fields: []Field{
			{Name: "replicas", Value: shapeMarkerAt(0, "replicas")},
			{Name: "ports", Value: &ArrayLit{Elements: []Expr{shapeMarkerAt(0, "http", &Path{Root: "x"})}}},
		}},
	}))
}

func TestShapePlainAllocTakesTheNextSite(t *testing.T) {
	prog := mustParse(t, `?shape("o", [~a, ?("p")])`)
	expect(t, "sites", prog.Root, Expr(&Let{
		Name:  shapeKeyName,
		Value: &StringLit{Value: "o"},
		Body: &ArrayLit{Elements: []Expr{
			shapeMarkerAt(0, "a"),
			&Alloc{Site: 1, Key: &StringLit{Value: "p"}},
		}},
	}))
}

func TestShapeSymbolSitesCountsAFormOnce(t *testing.T) {
	prog := mustParse(t, `[?shape("o", {~a, b: [~b, ~c(1)], i: ?shape("i", {~d})}), ?("p")]`)
	expect(t, "sites", SymbolSites(prog), []int{0, 1, 2})
}

func TestShapeAllocatesWithANullBinding(t *testing.T) {
	prog := mustParse(t, "@d = ?shape(\"d\", {~a, b: map([1, 2], (x) => ~b($x))})\n$d")
	out, err := RunProgram(Symbolic, nil, nil, prog)
	if err != nil {
		t.Fatal(err)
	}
	obj, ok := out.(*Object)
	if !ok {
		t.Fatalf("not an envelope: %s", CompactJSON(out))
	}
	symbols, _ := obj.Get("symbols")
	want, err := ParseJSON([]byte(`[
		{"id": "#0:[\"d\",\"a\"]", "origin": {"kind": "alloc", "site": 0, "key": ["d", "a"]}, "binding": null},
		{"id": "#0:[\"d\",\"b\",1]", "origin": {"kind": "alloc", "site": 0, "key": ["d", "b", 1]}, "binding": null},
		{"id": "#0:[\"d\",\"b\",2]", "origin": {"kind": "alloc", "site": 0, "key": ["d", "b", 2]}, "binding": null}
	]`))
	if err != nil {
		t.Fatal(err)
	}
	if !JSONEqual(symbols, want) {
		t.Errorf("symbols: got %s, want %s", CompactJSON(symbols), CompactJSON(want))
	}
}

func TestShapeLeavesDollarShapeAlone(t *testing.T) {
	out, err := RunProgram(Concrete, nil, nil, mustParse(t, "@shape = 1\n$shape"))
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "$shape", CompactJSON(out), "1")
}

func TestShapeRejects(t *testing.T) {
	for _, c := range []struct{ what, src string }{
		{"a marker outside any shape", `[~a]`},
		{"a marker in a ?shape's key", `?shape(~k, {~a})`},
		{"a marker in a nested ?shape's key", `?shape("o", {~a, i: ?shape(~k, {~b})})`},
		{"a bare marker under a lambda inside the shape", `?shape("d", map($xs, (x) => ~a))`},
		{"a bare shorthand marker under a lambda", `?shape("d", map($xs, (x) => {~a}))`},
		{"a duplicate marker name, bare and keyed", `?shape("d", [~a, map($xs, (x) => ~a($x))])`},
		{"a shape with no marker", `?shape("d", {a: 1})`},
		{"?shape with three arguments", `?shape("d", {~a}, 1)`},
		{"?shape with one argument", `?shape("d")`},
		{"a space after the marker leader", `?shape("d", ~ a)`},
		{"?(a, b)", `?("a", "b")`},
	} {
		_, err := ParseProgram(c.src)
		var pe *ParseError
		if !errors.As(err, &pe) {
			t.Errorf("%s: %s parsed, want a parse error (got %v)", c.what, c.src, err)
		}
	}
}

// Past ?shape( the parser commits, as it does for a special form, so a broken
// marker rule is reported as itself rather than as a failed alternative.
func TestShapeReportsTheBrokenRule(t *testing.T) {
	for _, c := range []struct{ src, msg string }{
		{`?shape("d", {a: 1})`, "a ?shape's shape must contain at least one marker of its own"},
		{`?shape("d", {~a, b: ~a})`, "a marker name appears twice in one ?shape"},
		{`?shape(~k, {~a})`, "a marker cannot be written in a ?shape's key"},
		{`?shape("d", map($xs, (x) => ~a))`, "a marker under a lambda inside a ?shape must carry a key, as in ~name(key)"},
		{`[~a]`, "a marker ~name may only be written inside a ?shape's shape"},
	} {
		_, err := ParseProgram(c.src)
		var pe *ParseError
		if !errors.As(err, &pe) {
			t.Errorf("%s: got %v, want a parse error", c.src, err)
			continue
		}
		expect(t, c.src, pe.Msg, c.msg)
	}
}
