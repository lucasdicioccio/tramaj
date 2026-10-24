package tramaj

import (
	"fmt"
	"strings"
	"testing"
)

// An unclosed bracket, quote or interpolation is reported where the closer
// was looked for, and names the opener and where it is. The same fifteen
// cases, with the same positions and messages, are in tramaj-hs's ParserSpec
// ("an unclosed opener") and in every other port's suite.
//
// Before, most of these said "at char 0: expected an expression": every
// alternative backtracks, so the error that escaped was the outermost one's.

func TestAnUnclosedOpenerIsReportedWhereTheCloserWasLookedFor(t *testing.T) {
	cases := []struct {
		name, src    string
		line, column int
		msg          string
	}{
		{"an element's parenthesis", `.div("x"`, 1, 9, `')' to close the '(' of .div at line 1, column 5`},
		{"an element's parenthesis, over several lines", ".div(\n  .p(\"a\"),\n  .p(\"b\")\n", 4, 1, `')' to close the '(' of .div at line 1, column 5`},
		{"a nested element's parenthesis", `.div(.p("a", .span("b"))`, 1, 25, `')' to close the '(' of .div at line 1, column 5`},
		{"a string", `.div("abc)`, 1, 11, `'"' to close the string at line 1, column 6`},
		{"a string over several lines", ".div(class: \"x\n)", 2, 2, `'"' to close the string at line 1, column 13`},
		{"an interpolation", "\"a `$x", 1, 7, "'`' to close the interpolation at line 1, column 4"},
		{"an interpolation the string closes first", ".div(\"a`$x\")", 1, 11, "'`' to close the interpolation at line 1, column 8"},
		{"a call's parenthesis", "f(1, 2", 1, 7, `')' to close the '(' at line 1, column 2`},
		{"a grouping parenthesis", "(1", 1, 3, `')' to close the '(' at line 1, column 1`},
		{"an array", "[1, 2", 1, 6, `']' to close the '[' at line 1, column 1`},
		{"an object", "{a: 1", 1, 6, `'}' to close the '{' at line 1, column 1`},
		{"a special form's parenthesis", "map($xs, (x) => $x", 1, 19, `')' to close the '(' at line 1, column 4`},
		{"a string in a branch arm", `branch($x, $p, "abc`, 1, 20, `'"' to close the string at line 1, column 16`},
		{"an array in a binding", "@x = 1\n@y = [1,\n$x", 3, 3, `']' to close the '[' at line 2, column 6`},
		{"a static string", `.b(action("on-click", "save, {}))`, 1, 34, `'"' to close the string at line 1, column 23`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := ParseProgram(c.src)
			pe, ok := err.(*ParseError)
			if !ok {
				t.Fatalf("want a *ParseError, got %v", err)
			}
			if pe.Line != c.line || pe.Column != c.column {
				t.Errorf("at line %d, column %d, want line %d, column %d (%v)", pe.Line, pe.Column, c.line, c.column, pe)
			}
			want := fmt.Sprintf("(line %d, column %d): expected %s", c.line, c.column, c.msg)
			if !strings.Contains(pe.Error(), want) {
				t.Errorf("got %q, want it to contain %q", pe.Error(), want)
			}
		})
	}
}
