package tramaj

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode"
)

// Hand-written recursive-descent lexer + parser for the surface syntax
// (specs/reference.md sections 5 and 8; specs/v3-symbols.md sections 1-2;
// specs/v4-types.md sections 1, 5, 7). Mirrors tramaj-py/tramaj/parser.py,
// including its "name recognition backtracks; the shape does not" rule for
// the special forms and the static-position (no-interpolation) restrictions.
//
// Inside the parser a failure is a panic carrying a *ParseError; attempt
// turns one back into a restored position, and ParseProgram into an error.

type ParseError struct {
	Pos int // in characters, not bytes
	Msg string
}

func (e *ParseError) Error() string {
	return fmt.Sprintf("at char %d: %s", e.Pos, e.Msg)
}

var specialFormNames = map[string]bool{
	"map": true, "filter": true, "scan": true, "fold": true, "branch": true,
	"import": true, "adapt-actions": true, "constraint": true,
}

// The five value-domain shapes v4-types.md section 1 reserves as type
// primitives.
var primNames = map[string]bool{
	"string": true, "number": true, "bool": true, "null": true, "document": true,
}

const eof rune = -1

func isAlpha(c rune) bool { return c != eof && unicode.IsLetter(c) }
func isAlnum(c rune) bool { return c != eof && (unicode.IsLetter(c) || unicode.IsNumber(c)) }
func isDigit(c rune) bool { return '0' <= c && c <= '9' }
func isHex(c rune) bool {
	return isDigit(c) || ('a' <= c && c <= 'f') || ('A' <= c && c <= 'F')
}
func isSpace(c rune) bool {
	return c != eof && (unicode.IsSpace(c) || (0x1c <= c && c <= 0x1f))
}

type parser struct {
	chars []rune
	pos   int
}

func (p *parser) fail(format string, args ...any) {
	panic(&ParseError{Pos: p.pos, Msg: fmt.Sprintf(format, args...)})
}

func (p *parser) peek() rune { return p.peekAt(0) }

func (p *parser) peekAt(off int) rune {
	if i := p.pos + off; i < len(p.chars) {
		return p.chars[i]
	}
	return eof
}

func (p *parser) advance() rune {
	c := p.peek()
	if c != eof {
		p.pos++
	}
	return c
}

// attempt gives full save/restore backtracking around one alternative.
func attempt[T any](p *parser, f func() T) (v T, ok bool) {
	save := p.pos
	defer func() {
		if r := recover(); r != nil {
			if _, isParse := r.(*ParseError); !isParse {
				panic(r)
			}
			p.pos = save
			var zero T
			v, ok = zero, false
		}
	}()
	return f(), true
}

func (p *parser) attemptDo(f func()) bool {
	_, ok := attempt(p, func() struct{} { f(); return struct{}{} })
	return ok
}

// Lexing.

func (p *parser) skipSpaces() {
	for {
		c := p.peek()
		switch {
		case isSpace(c):
			p.pos++
		case c == '-' && p.peekAt(1) == '-':
			for p.peek() != eof && p.peek() != '\n' {
				p.pos++
			}
		default:
			return
		}
	}
}

func lexeme[T any](p *parser, f func() T) T {
	v := f()
	p.skipSpaces()
	return v
}

func (p *parser) literal(s string) {
	save := p.pos
	for _, expected := range s {
		if p.advance() != expected {
			p.pos = save
			p.fail("expected %q", s)
		}
	}
}

func (p *parser) symbol(s string) {
	p.literal(s)
	p.skipSpaces()
}

func (p *parser) trySymbol(s string) bool {
	return p.attemptDo(func() { p.symbol(s) })
}

func (p *parser) charLit(c rune) {
	if p.peek() != c {
		p.fail("expected %q", string(c))
	}
	p.pos++
}

func (p *parser) rawIdent() string {
	c0 := p.peek()
	if !isAlpha(c0) {
		p.fail("expected an identifier")
	}
	p.pos++
	s := []rune{c0}
	for {
		c := p.peek()
		if isAlnum(c) || c == '_' {
			s = append(s, c)
			p.pos++
		} else if nxt := p.peekAt(1); c == '-' && (isAlnum(nxt) || nxt == '_') {
			s = append(s, '-')
			p.pos++
		} else {
			return string(s)
		}
	}
}

func (p *parser) identifier() string { return lexeme(p, p.rawIdent) }

func (p *parser) pathTail() (string, []string) {
	root := p.rawIdent()
	return root, p.dottedPathTail()
}

func (p *parser) dottedPathTail() []string {
	var segs []string
	for {
		save := p.pos
		if p.peek() != '.' {
			return segs
		}
		p.pos++
		seg, ok := attempt(p, p.rawIdent)
		if !ok {
			p.pos = save
			return segs
		}
		segs = append(segs, seg)
	}
}

func applyFieldAccess(base Expr, segs []string) Expr {
	if len(segs) == 0 {
		return base
	}
	return &FieldAccess{Target: base, Fields: segs}
}

// fieldAccessTail reads a trailing .a.b and the whitespace after it.
func (p *parser) fieldAccessTail(base Expr) Expr {
	segs := p.dottedPathTail()
	p.skipSpaces()
	return applyFieldAccess(base, segs)
}

// Static strings.

func (p *parser) staticString() string {
	return lexeme(p, func() string {
		p.charLit('"')
		var s []rune
		for {
			c := p.peek()
			if c == eof || c == '"' || c == '`' {
				break
			}
			s = append(s, c)
			p.pos++
		}
		if p.peek() != '"' {
			p.fail("this position must be a literal string, so it cannot contain an interpolation")
		}
		p.pos++
		return string(s)
	})
}

// String literals.

type stringPart struct {
	interp Expr // nil for a literal chunk
	lit    string
}

func (p *parser) stringLit() Expr {
	return lexeme(p, func() Expr {
		p.charLit('"')
		var parts []stringPart
		for {
			c := p.peek()
			if c == eof || c == '"' {
				break
			}
			if c == '`' {
				p.pos++
				e := p.expr()
				p.charLit('`')
				parts = append(parts, stringPart{interp: e})
			} else {
				parts = append(parts, stringPart{lit: p.litChunk()})
			}
		}
		p.charLit('"')
		return desugarString(parts)
	})
}

func (p *parser) litChunk() string {
	var s []rune
	for {
		c := p.peek()
		if c == '\\' {
			p.pos++
			s = append(s, p.escapeSeq())
		} else if c != eof && c != '"' && c != '`' {
			s = append(s, c)
			p.pos++
		} else {
			break
		}
	}
	if len(s) == 0 {
		p.fail("expected string content")
	}
	return string(s)
}

func (p *parser) escapeSeq() rune {
	c := p.advance()
	switch c {
	case eof:
		p.fail("unterminated escape sequence")
	case 'n':
		return '\n'
	case 't':
		return '\t'
	case 'r':
		return '\r'
	case '\\', '"', '`':
		return c
	case '0':
		return 0
	case 'u':
		p.charLit('{')
		var digits []rune
		for isHex(p.peek()) {
			digits = append(digits, p.advance())
		}
		if len(digits) == 0 {
			p.fail("invalid unicode escape")
		}
		p.charLit('}')
		n, err := strconv.ParseUint(string(digits), 16, 32)
		if err != nil || n > 0x10FFFF || (0xD800 <= n && n <= 0xDFFF) {
			p.fail("invalid unicode escape")
		}
		return rune(n)
	}
	p.fail("unknown escape sequence: \\%c", c)
	return 0
}

// Literals.

// numberLit parses ["-"] digits ["." digits] [("e"|"E") ["+"|"-"] digits],
// where a _ may sit between two digits. The fraction and exponent are taken
// only when complete; an overflow to infinity is refused and a zero is
// normalized so -0 never escapes.
func (p *parser) numberLit() Expr {
	return lexeme(p, func() Expr {
		full := ""
		if p.peek() == '-' {
			p.pos++
			full = "-"
		}
		intPart := p.digits()
		if intPart == "" {
			p.fail("expected a digit")
		}
		full += intPart
		save := p.pos
		if p.peek() == '.' {
			p.pos++
			if frac := p.digits(); frac == "" {
				p.pos = save
			} else {
				full += "." + frac
			}
		}
		save = p.pos
		if e := p.peek(); e == 'e' || e == 'E' {
			p.pos++
			exp := "e"
			if sign := p.peek(); sign == '+' || sign == '-' {
				p.pos++
				exp += string(sign)
			}
			if expDigits := p.digits(); expDigits == "" {
				p.pos = save
			} else {
				full += exp + expDigits
			}
		}
		n, _ := strconv.ParseFloat(full, 64)
		if math.IsNaN(n) || math.IsInf(n, 0) {
			p.fail("number literal out of range")
		}
		return &NumberLit{Value: normalizeNumber(n)}
	})
}

// digits reads digit { ["_"] digit } with the underscores dropped; "" when no
// digit is next.
func (p *parser) digits() string {
	if !isDigit(p.peek()) {
		return ""
	}
	var out []rune
	for {
		c := p.peek()
		if isDigit(c) {
			out = append(out, c)
			p.pos++
		} else if c == '_' && isDigit(p.peekAt(1)) {
			p.pos++
		} else {
			return string(out)
		}
	}
}

func (p *parser) keywordLit() Expr {
	switch p.identifier() {
	case "true":
		return &BoolLit{Value: true}
	case "false":
		return &BoolLit{Value: false}
	case "null":
		return &NullLit{}
	}
	p.fail("not a literal keyword")
	return nil
}

func (p *parser) arrayLit() Expr {
	p.symbol("[")
	elements := sepEndBy(p, ",", p.expr)
	p.symbol("]")
	return &ArrayLit{Elements: elements}
}

func (p *parser) objectLit() Expr {
	p.symbol("{")
	fields := sepEndBy(p, ",", p.objEntry)
	p.symbol("}")
	return &ObjectLit{Fields: fields}
}

func (p *parser) objEntry() Field {
	if explicit, ok := attempt(p, p.explicitEntry); ok {
		return explicit
	}
	k := p.identifier()
	return Field{Name: k, Value: &Path{Root: k}}
}

func (p *parser) explicitEntry() Field {
	k := p.objectKey()
	if k == "$sym" || k == "$type" {
		p.fail("%q is a reserved key and cannot be used as an object key", k)
	}
	p.symbol(":")
	return Field{Name: k, Value: p.expr()}
}

func (p *parser) objectKey() string {
	if s, ok := attempt(p, p.staticString); ok {
		return s
	}
	return p.identifier()
}

func sepEndBy[T any](p *parser, sep string, item func() T) []T {
	var out []T
	first, ok := attempt(p, item)
	if !ok {
		return out
	}
	out = append(out, first)
	for {
		save := p.pos
		if !p.trySymbol(sep) {
			return out
		}
		nxt, ok := attempt(p, item)
		if !ok {
			p.pos = save
			return out
		}
		out = append(out, nxt)
	}
}

// Expressions.

func (p *parser) pathExpr() Expr {
	return lexeme(p, func() Expr {
		p.charLit('$')
		root, fields := p.pathTail()
		return &Path{Root: root, Fields: fields}
	})
}

// allocExpr parses ?(key) (v3-symbols.md section 1.2); numberAllocs assigns
// the real site later.
func (p *parser) allocExpr() Expr {
	p.charLit('?')
	p.symbol("(")
	key := p.expr()
	p.charLit(')')
	return p.fieldAccessTail(&Alloc{Key: key})
}

// demandExpr parses ?ctx.a.b (section 1.3): the path MUST be rooted at ctx.
func (p *parser) demandExpr() Expr {
	return lexeme(p, func() Expr {
		p.charLit('?')
		if p.rawIdent() != "ctx" {
			p.fail("a demand must be rooted at ctx, as in ?ctx.path")
		}
		return &Demand{Path: p.dottedPathTail()}
	})
}

func (p *parser) callExpr() Expr {
	p.attemptDo(func() { p.charLit('$') })
	root, fields := p.pathTail()
	p.symbol("(")
	args := sepEndBy(p, ",", p.expr)
	p.charLit(')')
	return p.fieldAccessTail(&Call{Fn: &Path{Root: root, Fields: fields}, Args: args})
}

func (p *parser) lambdaExpr() Expr {
	p.symbol("(")
	params := sepEndBy(p, ",", p.pattern)
	p.symbol(")")
	p.symbol("=>")
	return lowerLambda(params, p.expr())
}

// Binding patterns (decisions section 17).

// pattern is a name, or (when fields is non-nil) an object pattern.
type pattern struct {
	name   string
	fields []patternField
}

type patternField struct {
	key string
	pat pattern
}

func (pat pattern) isObject() bool { return pat.fields != nil }

func (pat pattern) names() []string {
	if !pat.isObject() {
		return []string{pat.name}
	}
	var out []string
	for _, f := range pat.fields {
		out = append(out, f.pat.names()...)
	}
	return out
}

// pattern parses a name, or an object pattern {a, b: c, d: {e}}. Object
// patterns only: defaults, rest and array patterns are not in the grammar, so
// they are parse errors.
func (p *parser) pattern() pattern {
	if n, ok := attempt(p, p.identifier); ok {
		return pattern{name: n}
	}
	return p.objectPattern()
}

func (p *parser) objectPattern() pattern {
	p.symbol("{")
	fields := sepEndBy(p, ",", p.patternField)
	if len(fields) == 0 {
		p.fail("expected a field in a binding pattern")
	}
	p.symbol("}")
	pat := pattern{fields: fields}
	seen := map[string]bool{}
	for _, n := range pat.names() {
		if seen[n] {
			p.fail("duplicate name in a binding pattern")
		}
		seen[n] = true
	}
	return pat
}

// patternField: `name` binds the field to that name; `name: p` binds or
// destructures it as p.
func (p *parser) patternField() patternField {
	k := p.identifier()
	sub, ok := attempt(p, func() pattern {
		p.symbol(":")
		return p.pattern()
	})
	if !ok {
		sub = pattern{name: k}
	}
	return patternField{key: k, pat: sub}
}

func (p *parser) parenExpr() Expr {
	p.symbol("(")
	e := p.expr()
	p.symbol(")")
	return e
}

// trySpecialFormName is soft recognition only: it consumes the name (and
// trailing whitespace) iff it is one of the recognized special forms;
// otherwise it fully restores.
func (p *parser) trySpecialFormName() (string, bool) {
	save := p.pos
	p.attemptDo(func() { p.charLit('$') })
	if n, ok := attempt(p, p.identifier); ok && specialFormNames[n] {
		return n, true
	}
	p.pos = save
	return "", false
}

// specialFormShape: once the name is recognized the shape does not backtrack:
// any error here is a hard parse error (reference.md section 5).
func (p *parser) specialFormShape(name string) Expr {
	var base Expr
	switch name {
	case "map":
		c, f := p.binaryShape()
		base = &Map{Collection: c, Fn: f}
	case "filter":
		c, f := p.binaryShape()
		base = &Filter{Collection: c, Fn: f}
	case "scan":
		c, i, f := p.ternaryShape()
		base = &Scan{Collection: c, Initial: i, Fn: f}
	case "fold":
		c, i, f := p.ternaryShape()
		base = &Fold{Collection: c, Initial: i, Fn: f}
	case "branch":
		base = p.branchShape()
	case "import":
		base = p.importShape()
	case "adapt-actions":
		base = p.adaptActionsShape()
	case "constraint":
		base = p.constraintShape()
	default:
		p.fail("unrecognized special form")
	}
	return p.fieldAccessTail(base)
}

func (p *parser) binaryShape() (Expr, Expr) {
	p.symbol("(")
	a := p.expr()
	p.symbol(",")
	b := p.expr()
	p.charLit(')')
	return a, b
}

func (p *parser) ternaryShape() (Expr, Expr, Expr) {
	p.symbol("(")
	a := p.expr()
	p.symbol(",")
	b := p.expr()
	p.symbol(",")
	c := p.expr()
	p.charLit(')')
	return a, b, c
}

// commaSeparatedTail reads { "," item } [","] ")" after a form's first
// argument.
func commaSeparatedTail[T any](p *parser, item func() T) []T {
	var out []T
	for {
		save := p.pos
		if !p.trySymbol(",") {
			break
		}
		x, ok := attempt(p, item)
		if !ok {
			p.pos = save
			break
		}
		out = append(out, x)
	}
	p.trySymbol(",")
	p.charLit(')')
	return out
}

func (p *parser) branchShape() Expr {
	p.symbol("(")
	acc := p.expr()
	arms := commaSeparatedTail(p, func() [2]Expr {
		cond := p.expr()
		p.symbol(",")
		return [2]Expr{cond, p.expr()}
	})
	for i := len(arms) - 1; i >= 0; i-- {
		acc = &Branch{Condition: arms[i][0], Then: arms[i][1], Else: acc}
	}
	return acc
}

func (p *parser) importShape() Expr {
	p.symbol("(")
	name := p.staticString()
	p.symbol(",")
	p.symbol("{")
	params := sepEndBy(p, ",", p.paramEntry)
	p.symbol("}")
	p.charLit(')')
	return &Import{Name: name, Params: params}
}

func (p *parser) paramEntry() Param {
	if explicit, ok := attempt(p, func() Param {
		k := p.objectKey()
		p.symbol(":")
		return Param{Name: k, Value: p.paramValue()}
	}); ok {
		return explicit
	}
	k := p.identifier()
	return Param{Name: k, Value: &PExpr{Expr: &Path{Root: k}}}
}

func (p *parser) paramValue() ParamValue {
	if marked, ok := attempt(p, p.markedTypeExpr); ok {
		return &PType{Type: marked}
	}
	if fromCtx, ok := attempt(p, p.ctxParam); ok {
		return fromCtx
	}
	return &PExpr{Expr: p.expr()}
}

// Types.

func (p *parser) typeExpr() TypeExpr {
	for _, alt := range []func() TypeExpr{p.typeVar, p.typeUnion, p.typeArray, p.typeRecord} {
		if v, ok := attempt(p, alt); ok {
			return v
		}
	}
	return p.typePrimOrRef()
}

// typeExprPayload is deliberately narrower than typeExpr: a bare name is
// excluded because nothing marks where a nullary arm ends.
func (p *parser) typeExprPayload() TypeExpr {
	if v, ok := attempt(p, p.typeVar); ok {
		return v
	}
	if a, ok := attempt(p, p.typeArray); ok {
		return a
	}
	return p.typeRecord()
}

func (p *parser) typeVar() TypeExpr {
	return lexeme(p, func() TypeExpr {
		p.charLit('%')
		if p.rawIdent() != "ctx" {
			p.fail("a type hole must be rooted at ctx, as in %%ctx.path")
		}
		return &TVar{Path: p.dottedPathTail()}
	})
}

// markedTypeExpr parses a %-marked type argument (v4-types.md sections 2, 5).
// Unlike typeVar the leading % does not require what follows to be ctx.
func (p *parser) markedTypeExpr() TypeExpr {
	p.charLit('%')
	for _, alt := range []func() TypeExpr{p.ctxForward, p.typeUnion, p.typeArray, p.typeRecord} {
		if v, ok := attempt(p, alt); ok {
			return v
		}
	}
	return p.typePrimOrRef()
}

func (p *parser) ctxForward() TypeExpr {
	return lexeme(p, func() TypeExpr {
		if p.rawIdent() != "ctx" {
			p.fail("a %%-marked value must be ctx.path or a type expression")
		}
		return &TVar{Path: p.dottedPathTail()}
	})
}

func (p *parser) typeArray() TypeExpr {
	p.symbol("[")
	element := p.typeExpr()
	p.symbol("]")
	return &TArray{Element: element}
}

func (p *parser) typeRecord() TypeExpr {
	p.symbol("{")
	fields := sepEndBy(p, ",", func() TypeField {
		k := p.identifier()
		p.symbol(":")
		return TypeField{Name: k, Type: p.typeExpr()}
	})
	p.symbol("}")
	return &TRecord{Fields: fields}
}

func (p *parser) typeUnion() TypeExpr {
	p.symbol("|")
	arms := []UnionArm{p.unionArm()}
	for p.trySymbol("|") {
		arms = append(arms, p.unionArm())
	}
	return &TUnion{Arms: arms}
}

func (p *parser) unionArm() UnionArm {
	name := p.identifier()
	payload, _ := attempt(p, p.typeExprPayload)
	return UnionArm{Name: name, Payload: payload}
}

func (p *parser) typePrimOrRef() TypeExpr {
	if r, ok := attempt(p, p.typeLibRef); ok {
		return r
	}
	name := p.identifier()
	if primNames[name] {
		return &TPrim{Name: name}
	}
	return &TName{Name: name}
}

func (p *parser) typeLibRef() TypeExpr {
	return lexeme(p, func() TypeExpr {
		p.charLit('$')
		lib := p.rawIdent()
		p.charLit('.')
		p.literal("types")
		p.charLit('.')
		return &TLibRef{Lib: lib, Name: p.rawIdent()}
	})
}

func (p *parser) typeConstraintArg() TypeConstraintArg {
	if marked, ok := attempt(p, p.markedTypeExpr); ok {
		return TypeConstraintArg{Type: marked}
	}
	if s, ok := attempt(p, p.staticString); ok {
		return TypeConstraintArg{Scalar: s}
	}
	if n, ok := attempt(p, p.numberLit); ok {
		return TypeConstraintArg{Scalar: n.(*NumberLit).Value}
	}
	if k, ok := attempt(p, p.keywordLit); ok {
		if b, isBool := k.(*BoolLit); isBool {
			return TypeConstraintArg{Scalar: b.Value}
		}
		return TypeConstraintArg{}
	}
	p.fail("expected a type-constraint argument")
	return TypeConstraintArg{}
}

// typeEmission parses !type-constraint(name, args...) (v4-types.md section
// 5): tried before the general !expr emission, since both share the ! leader.
func (p *parser) typeEmission() Stmt {
	p.charLit('!')
	if p.identifier() != "type-constraint" {
		p.fail("not a !type-constraint")
	}
	p.symbol("(")
	name := p.staticString()
	args := commaSeparatedTail(p, p.typeConstraintArg)
	p.skipSpaces()
	return Stmt{Kind: StmtTypeEmit, Name: name, Args: args}
}

// typeDeclStmt parses `type Name = TypeExpr` (v4-types.md section 1.1): a
// keyword leader.
func (p *parser) typeDeclStmt() Stmt {
	if p.identifier() != "type" {
		p.fail("not a type declaration")
	}
	name := p.identifier()
	p.symbol("=")
	return Stmt{Kind: StmtTypeDecl, Name: name, Type: p.typeExpr()}
}

func (p *parser) ctxParam() ParamValue {
	save := p.pos
	if n := p.identifier(); n != "ctx" || p.peek() != '(' {
		p.pos = save
		p.fail("not a ctx(...) parameter")
	}
	p.symbol("(")
	root, fields := p.pathTail()
	p.skipSpaces()
	p.charLit(')')
	p.skipSpaces()
	return &PFromContext{Path: append([]string{root}, fields...)}
}

// constraintShape parses constraint(name, args...) (v3-symbols.md section
// 2.1).
func (p *parser) constraintShape() Expr {
	p.symbol("(")
	name := p.staticString()
	return &Constrain{Name: name, Args: commaSeparatedTail(p, p.expr)}
}

func (p *parser) adaptActionsShape() Expr {
	p.symbol("(")
	target := p.expr()
	p.symbol(",")
	adaptation := p.adaptationShape()
	fn, _ := attempt(p, func() Expr {
		p.symbol(",")
		return p.expr()
	})
	p.trySymbol(",")
	p.charLit(')')
	return &AdaptActions{Target: target, Adaptation: adaptation, Fn: fn}
}

func (p *parser) adaptationShape() ActionAdaptation {
	switch p.identifier() {
	case "identity":
		return ActionAdaptation{}
	case "prefix":
		p.symbol("(")
		prefix := p.staticString()
		p.charLit(')')
		p.skipSpaces()
		return ActionAdaptation{IsPrefix: true, Prefix: prefix}
	}
	p.fail(`an action adaptation must be identity or prefix("...")`)
	return ActionAdaptation{}
}

// Documents.

func (p *parser) documentExpr() Expr {
	p.charLit('.')
	if frag, ok := attempt(p, p.fragmentShape); ok {
		return frag
	}
	return p.elementShape()
}

func (p *parser) fragmentShape() Expr {
	p.symbol("(")
	children := sepEndBy(p, ",", p.expr)
	p.symbol(")")
	return &Fragment{Children: children}
}

// elementArg is one argument of an element: an attribute or action, the
// value(...) slot, or a child.
type elementArg struct {
	attr  Attribute
	value Expr
	child Expr
}

func (p *parser) elementShape() Expr {
	tag := p.rawIdent()
	p.skipSpaces()
	p.symbol("(")
	args := sepEndBy(p, ",", p.elementArg)
	p.symbol(")")

	el := &Element{Tag: tag}
	seenChild, values := false, 0
	for _, a := range args {
		if a.child != nil {
			seenChild = true
			el.Children = append(el.Children, a.child)
			continue
		}
		if seenChild {
			p.fail("attributes, action(...) and value(...) must all come before an element's children")
		}
		if a.attr != nil {
			el.Attributes = append(el.Attributes, a.attr)
		} else {
			values++
			el.Value = a.value
		}
	}
	if values > 1 {
		p.fail("an element can have at most one value(...)")
	}
	if values == 0 {
		el.Value = &NullLit{}
	}
	return el
}

func (p *parser) elementArg() elementArg {
	if positional, ok := p.tryAttributePositionArg(); ok {
		return positional
	}
	if named, ok := attempt(p, func() Attribute {
		name := p.objectKey()
		p.symbol(":")
		return &Attr{Name: name, Value: p.expr()}
	}); ok {
		return elementArg{attr: named}
	}
	return elementArg{child: p.expr()}
}

// tryAttributePositionArg handles action(...)/value(...): soft name+lookahead
// recognition, then a hard-committed shape.
func (p *parser) tryAttributePositionArg() (elementArg, bool) {
	save := p.pos
	n, ok := attempt(p, p.identifier)
	if !ok || p.peek() != '(' || (n != "action" && n != "value") {
		p.pos = save
		return elementArg{}, false
	}
	p.symbol("(")
	if n == "value" {
		v := p.expr()
		p.symbol(")")
		return elementArg{value: v}, true
	}
	event := p.staticString()
	p.symbol(",")
	key := p.staticString()
	p.symbol(",")
	payload := p.expr()
	p.symbol(")")
	return elementArg{attr: &ActionAttr{Event: event, Key: key, Payload: payload}}, true
}

// Precedence.

func (p *parser) expr() Expr {
	acc := p.operand()
	for {
		rhs, ok := attempt(p, func() Expr {
			p.symbol("<>")
			return p.operand()
		})
		if !ok {
			return acc
		}
		acc = &Concat{Left: acc, Right: rhs}
	}
}

func (p *parser) operand() Expr {
	for _, alt := range []func() Expr{p.keywordLit, p.lambdaExpr, p.parenExpr} {
		if v, ok := attempt(p, alt); ok {
			return v
		}
	}
	if special, ok := p.trySpecialFormName(); ok {
		return p.specialFormShape(special)
	}
	for _, alt := range []func() Expr{
		p.callExpr, p.pathExpr, p.allocExpr, p.demandExpr, p.documentExpr,
		p.stringLit, p.numberLit, p.arrayLit, p.objectLit,
	} {
		if v, ok := attempt(p, alt); ok {
			return v
		}
	}
	p.fail("expected an expression")
	return nil
}

// Programs.

// binding parses @name=expr, @name : T = expr (v4-types.md section 7) or
// @{a, b: c} = expr (decisions section 17), which lowers to several
// statements. An annotation on a pattern is a parse error.
func (p *parser) binding() []Stmt {
	p.charLit('@')
	pat := p.pattern()
	if pat.isObject() {
		p.symbol("=")
		return bindPattern(pat, p.expr())
	}
	annot, annotated := attempt(p, func() TypeExpr {
		p.symbol(":")
		return p.typeExpr()
	})
	p.symbol("=")
	value := p.expr()
	if annotated {
		return []Stmt{{Kind: StmtAnnotate, Name: pat.name, Type: annot, Value: value}}
	}
	return []Stmt{{Kind: StmtLet, Name: pat.name, Value: value}}
}

func (p *parser) program() *Program {
	p.skipSpaces()
	var stmts []Stmt
	for {
		if b, ok := attempt(p, p.binding); ok {
			stmts = append(stmts, b...)
		} else if te, ok := attempt(p, p.typeEmission); ok {
			stmts = append(stmts, te)
		} else if em, ok := attempt(p, func() Expr {
			// !expr (v3-symbols.md section 2.2): a statement position only.
			p.charLit('!')
			return p.expr()
		}); ok {
			stmts = append(stmts, Stmt{Kind: StmtEmit, Value: em})
		} else if td, ok := attempt(p, p.typeDeclStmt); ok {
			stmts = append(stmts, td)
		} else {
			break
		}
	}
	root := p.expr()
	p.skipSpaces()
	if p.pos < len(p.chars) {
		p.fail("unexpected trailing input")
	}
	kind := ExpressionProgram
	switch root.(type) {
	case *Element, *Fragment:
		kind = DocumentProgram
	}
	body := wrapStmts(stmts, root)
	numberAllocs(body)
	return &Program{Kind: kind, Root: body}
}

// wrapStmts nests a statement list back around a body, the inverse of Unlets.
func wrapStmts(stmts []Stmt, body Expr) Expr {
	for i := len(stmts) - 1; i >= 0; i-- {
		s := stmts[i]
		switch s.Kind {
		case StmtLet:
			body = &Let{Name: s.Name, Value: s.Value, Body: body}
		case StmtEmit:
			body = &Emit{Constraint: s.Value, Body: body}
		case StmtTypeDecl:
			body = &TypeDecl{Name: s.Name, Type: s.Type, Body: body}
		case StmtAnnotate:
			body = &TypeAnnotate{Name: s.Name, Type: s.Type, Value: s.Value, Body: body}
		case StmtTypeEmit:
			body = &TypeEmit{Name: s.Name, Args: s.Args, Body: body}
		}
	}
	return body
}

func readField(source Expr, k string) Expr {
	if path, ok := source.(*Path); ok {
		fields := append(append([]string(nil), path.Fields...), k)
		return &Path{Root: path.Root, Fields: fields}
	}
	return &FieldAccess{Target: source, Fields: []string{k}}
}

// bindPattern lowers `pattern = source` to plain bindings, in written order.
// A source that is a path is read directly ($ctx.item.a), so errors and
// static analyses see the reads a hand-written program would make; anything
// else is bound once to the hidden name #src first. Hidden names start with
// '#', which no surface name can (isHiddenName).
func bindPattern(pat pattern, source Expr) []Stmt {
	if !pat.isObject() {
		return []Stmt{{Kind: StmtLet, Name: pat.name, Value: source}}
	}
	var out []Stmt
	if _, ok := source.(*Path); !ok {
		out = append(out, Stmt{Kind: StmtLet, Name: "#src", Value: source})
		source = &Path{Root: "#src"}
	}
	for _, f := range pat.fields {
		out = append(out, bindPattern(f.pat, readField(source, f.key))...)
	}
	return out
}

// lowerLambda turns a pattern parameter into a hidden parameter #argN; the
// body is wrapped in the bindings that read the pattern's names out of it.
func lowerLambda(params []pattern, body Expr) Expr {
	var names []string
	var bound []Stmt
	for i, pat := range params {
		if !pat.isObject() {
			names = append(names, pat.name)
			continue
		}
		hidden := "#arg" + strconv.Itoa(i)
		names = append(names, hidden)
		bound = append(bound, bindPattern(pat, &Path{Root: hidden})...)
	}
	return &Lambda{Params: names, Body: wrapStmts(bound, body)}
}

func desugarString(parts []stringPart) Expr {
	var acc Expr
	var lit strings.Builder
	hasLit := false
	push := func(e Expr) {
		if acc == nil {
			acc = e
		} else {
			acc = &Concat{Left: acc, Right: e}
		}
	}
	flush := func() {
		if hasLit {
			push(&StringLit{Value: lit.String()})
			lit.Reset()
			hasLit = false
		}
	}
	for _, part := range parts {
		if part.interp == nil {
			lit.WriteString(part.lit)
			hasLit = true
			continue
		}
		flush()
		push(&Call{Fn: &Path{Root: "str"}, Args: []Expr{part.interp}})
	}
	flush()
	if acc == nil {
		return &StringLit{}
	}
	return acc
}

// ParseProgram parses a program's source. The error, when there is one, is a
// *ParseError.
func ParseProgram(src string) (prog *Program, err error) {
	defer func() {
		if r := recover(); r != nil {
			pe, ok := r.(*ParseError)
			if !ok {
				panic(r)
			}
			prog, err = nil, pe
		}
	}()
	p := &parser{chars: []rune(src)}
	return p.program(), nil
}
