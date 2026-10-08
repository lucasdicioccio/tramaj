package tramaj

import (
	"fmt"
	"math"
	"math/big"
	"slices"
	"sort"
	"strconv"
	"strings"
)

// Values, the environment, and the evaluator: concrete and symbolic modes
// (specs/reference.md sections 6, 7, 10; specs/v3-symbols.md sections 4-6;
// specs/v4-types.md sections 7-8). Mirrors tramaj-py/tramaj/evaluator.py.
//
// Inside the evaluator a failure is a panic carrying an *EvalError; the
// exported entry points turn it back into an error.

// Mode is an evaluation mode.
type Mode string

const (
	Concrete Mode = "concrete"
	Symbolic Mode = "symbolic"
)

// Options is what a host chooses for one evaluation. The zero value is not
// usable, since it names no mode; start from DefaultOptions.
type Options struct {
	Mode Mode
	// Arithmetic turns on the arithmetic profile (specs/reference.md section
	// 11) for this evaluation: the names of ArithmeticNames are in the
	// initial environment of the root program and of every library it runs,
	// and a well-formed term is accepted in a symbolic-mode context. Off,
	// those names are unbound, so sum(1, 2) is an UnboundName, and every
	// seeded term is refused. The two number types and the reserved "$term"
	// key do not depend on it.
	Arithmetic bool
}

// DefaultOptions is concrete mode without the arithmetic profile, which is
// what EvalProgram and RunProgram add to the mode they are given. A host that
// leaves the profile off can refuse a program beforehand with
// DeepArithmeticOps.
var DefaultOptions = Options{Mode: Concrete}

// EvalError carries one of the error kinds from specs/reference.md section
// 12 (NotRepresentable among them: an arithmetic operation with no result in
// the type of its operands), plus v3's symbol kinds and the one v4 static
// failure (TypeErr). Error()
// always leads with the bare kind; the rest is implementation-defined prose.
type EvalError struct {
	Kind   string
	Detail string
	// Cause is the library's own error when Kind is InLibrary.
	Cause *EvalError
}

func (e *EvalError) Error() string {
	if e.Detail == "" {
		return e.Kind
	}
	return e.Kind + " " + e.Detail
}

func (e *EvalError) Unwrap() error {
	if e.Cause == nil {
		return nil
	}
	return e.Cause
}

func evalFail(kind, format string, args ...any) {
	panic(&EvalError{Kind: kind, Detail: fmt.Sprintf(format, args...)})
}

func typeMismatch(format string, args ...any)     { evalFail("TypeMismatch", format, args...) }
func notRepresentable(format string, args ...any) { evalFail("NotRepresentable", format, args...) }
func notConcrete(who string)                      { evalFail("NotConcrete", "%s", who) }

// try runs f, returning the *EvalError it panicked with, if any.
func try(f func()) (err *EvalError) {
	defer func() {
		if r := recover(); r != nil {
			ee, ok := r.(*EvalError)
			if !ok {
				panic(r)
			}
			err = ee
		}
	}()
	f()
	return nil
}

// withTypeErrors runs a static type pass, reporting its failure as TypeErr.
func withTypeErrors[T any](f func() T) T {
	defer func() {
		if r := recover(); r != nil {
			if te, ok := r.(*TypeError); ok {
				evalFail("TypeErr", "%s", te.Error())
			}
			panic(r)
		}
	}()
	return f()
}

// Values.

type value interface{ isValue() }

type (
	vNull struct{}
	vBool bool
	// vInt is an integer, in the signed 64-bit range; vFloat is a float,
	// finite and never a negative zero (specs/reference.md section 3).
	// Nothing converts one into the other except real and floor.
	vInt     int64
	vFloat   float64
	vStr     string
	vArray   []value
	vObject  struct{ fields *OrderedMap[value] }
	vNode    struct{ node *Node }
	vClosure struct {
		params []string
		body   Expr
		env    *env
	}
	vBuiltin string
	// vImportResult is what a run library yields: .rendered and .vals.
	vImportResult struct{ fields *OrderedMap[value] }
	// vImport is an import that has not run yet.
	vImport struct {
		name   string
		params *OrderedMap[value]
		queued []queuedAdaptation
	}
	// vSymbol is a symbol (v3-symbols.md section 1.1): an id plus a
	// projection path (section 1.6).
	vSymbol struct {
		id   string
		path []string
	}
	vConstraint struct {
		name string
		args []value
	}
	// vTerm is a term (v3-symbols.md section 1.9): an arithmetic operation
	// left unevaluated because an operand is a symbol or a term. args are the
	// flattened operands exactly as written, each a vInt, a vFloat, a
	// *vSymbol or a *vTerm, nothing folded and no nested term spliced.
	vTerm struct {
		op   string
		args []value
	}
)

type queuedAdaptation struct {
	adaptation ActionAdaptation
	fn         value // nil when no function was given
}

func (vNull) isValue()          {}
func (vBool) isValue()          {}
func (vInt) isValue()           {}
func (vFloat) isValue()         {}
func (*vTerm) isValue()         {}
func (vStr) isValue()           {}
func (vArray) isValue()         {}
func (*vObject) isValue()       {}
func (*vNode) isValue()         {}
func (*vClosure) isValue()      {}
func (vBuiltin) isValue()       {}
func (*vImportResult) isValue() {}
func (*vImport) isValue()       {}
func (*vSymbol) isValue()       {}
func (*vConstraint) isValue()   {}

// env is a persistent environment: binding a name never disturbs a closure
// that captured the environment it extends.
type env struct {
	name   string
	val    value
	parent *env
}

func (e *env) bind(name string, v value) *env {
	return &env{name: name, val: v, parent: e}
}

func (e *env) lookup(name string) (value, bool) {
	for ; e != nil; e = e.parent {
		if e.name == name {
			return e.val, true
		}
	}
	return nil, false
}

var builtinNames = []string{
	"cardinality", "count", "str", "not", "and", "or", "eq", "lt", "lte", "gt", "gte",
	"has", "lookup", "concat", "append", "format-number",
}

// initialEnv is $ctx and the builtins. The arithmetic names are bound only
// with the arithmetic profile on (specs/reference.md section 11); without it
// they are unbound like any other name.
func initialEnv(arithmetic bool, ctxVal value) *env {
	var e *env
	for _, n := range builtinNames {
		e = e.bind(n, vBuiltin(n))
	}
	if arithmetic {
		for _, n := range ArithmeticNames {
			e = e.bind(n, vBuiltin(n))
		}
	}
	return e.bind("ctx", ctxVal)
}

type symbolEntry struct {
	id      string
	origin  *Object
	binding JSON // a string, or nil
}

// emissions is what evaluation accumulates alongside its result
// (v3-symbols.md section 4): emitted constraints and allocated symbol-table
// entries, each in evaluation order and deduplicated once, globally, at the
// top.
type emissions struct {
	constraints []*vConstraint
	symbols     []symbolEntry
}

type evalCtx struct {
	libs       Libraries
	inProgress map[string]bool
	mode       Mode
	// arithmetic is whether the arithmetic profile is on (Options): a library
	// runs with the profile of the evaluation that reached it.
	arithmetic bool
	isRoot     bool
	em         *emissions
}

// Entry points.

// Output is a program's result: a document when Node is non-nil, otherwise
// the plain JSON value in Value.
type Output struct {
	Node  *Node
	Value JSON
}

func (o Output) toJSON() JSON {
	if o.Node != nil {
		return NodeToJSON(o.Node)
	}
	return o.Value
}

func catchEvalError(err *error) {
	if r := recover(); r != nil {
		ee, ok := r.(*EvalError)
		if !ok {
			panic(r)
		}
		*err = ee
	}
}

// EvalProgram evaluates a program against a context, without the arithmetic
// profile. The error, when there is one, is an *EvalError.
func EvalProgram(mode Mode, libs Libraries, ctx JSON, prog *Program) (Output, error) {
	return EvalProgramWith(Options{Mode: mode}, libs, ctx, prog)
}

// EvalProgramWith is EvalProgram with every option chosen by the host.
func EvalProgramWith(options Options, libs Libraries, ctx JSON, prog *Program) (out Output, err error) {
	defer catchEvalError(&err)
	out, _ = evalProgram(options, libs, ctx, prog)
	return out, nil
}

func evalProgram(options Options, libs Libraries, ctx JSON, prog *Program) (Output, *emissions) {
	mode := options.Mode
	if mode != Concrete && mode != Symbolic {
		panic(fmt.Sprintf("tramaj: unknown mode %q", mode))
	}
	erased := withTypeErrors(func() *Program { return eraseTypes(libs, prog) })
	c := &evalCtx{libs: libs, mode: mode, arithmetic: options.Arithmetic, isRoot: true, em: &emissions{}}
	v := c.eval(initialEnv(options.Arithmetic, checkedFromJSON(options, ctx)), erased.Root)
	if n, ok := v.(*vNode); ok {
		return Output{Node: n.node}, dedupe(c.em)
	}
	return Output{Value: toJSON(v)}, dedupe(c.em)
}

// dedupe: two constraints with the same name and equal arguments are one
// constraint, and two symbol-table entries with the same id are one entry,
// each kept at the position of the first.
func dedupe(e *emissions) *emissions {
	out := &emissions{}
	var wire []JSON
	for _, c := range e.constraints {
		w := constraintToJSON(c)
		dup := false
		for _, seen := range wire {
			if JSONEqual(seen, w) {
				dup = true
				break
			}
		}
		if !dup {
			wire = append(wire, w)
			out.constraints = append(out.constraints, c)
		}
	}
	seen := map[string]bool{}
	for _, s := range e.symbols {
		if !seen[s.id] {
			seen[s.id] = true
			out.symbols = append(out.symbols, s)
		}
	}
	return out
}

// constraintToJSON is total: a constraint's arguments were checked to cross
// the JSON boundary when it was built.
func constraintToJSON(c *vConstraint) JSON {
	args := make([]JSON, len(c.args))
	for i, a := range c.args {
		args[i] = toJSON(a)
	}
	return NewObject("name", c.name, "arguments", args)
}

// RunProgram evaluates and serializes to the wire JSON a host compares
// against a corpus case's expected.json: the node-json document or the plain
// value in concrete mode, the v3-symbols section 5.2 envelope in symbolic
// mode. It runs without the arithmetic profile. The error, when there is one,
// is an *EvalError.
func RunProgram(mode Mode, libs Libraries, ctx JSON, prog *Program) (JSON, error) {
	return RunProgramWith(Options{Mode: mode}, libs, ctx, prog)
}

// RunProgramWith is RunProgram with every option chosen by the host.
func RunProgramWith(options Options, libs Libraries, ctx JSON, prog *Program) (out JSON, err error) {
	defer catchEvalError(&err)
	mode := options.Mode
	output, em := evalProgram(options, libs, ctx, prog)
	root := output.toJSON()
	if mode == Concrete {
		return root, nil
	}
	kind := "expression"
	if output.Node != nil {
		kind = "document"
	}

	types, typeConstraints := withTypeErrors(func() []JSON {
		closure := typeClosure(libs, prog, programTypeRoots(libs, prog))
		ids := make([]string, 0, len(closure))
		for id := range closure {
			ids = append(ids, id)
		}
		sort.Slice(ids, func(i, j int) bool { return lessUTF16(ids[i], ids[j]) })
		out := make([]JSON, len(ids))
		for i, id := range ids {
			out[i] = NewObject("id", id, "definition", resolvedTypeToJSON(closure[id]))
		}
		return out
	}), withTypeErrors(func() []JSON {
		tcs := deepTypeConstraints(libs, prog)
		out := make([]JSON, len(tcs))
		for i, tc := range tcs {
			out[i] = tc.toJSON()
		}
		return out
	})

	symbols := make([]JSON, len(em.symbols))
	for i, s := range em.symbols {
		symbols[i] = NewObject("id", s.id, "origin", s.origin, "binding", s.binding)
	}
	constraints := make([]JSON, len(em.constraints))
	for i, c := range em.constraints {
		constraints[i] = constraintToJSON(c)
	}
	return NewObject(
		"format", "tramaj/symbolic/1",
		"kind", kind,
		"root", root,
		"symbols", symbols,
		"constraints", constraints,
		"types", types,
		"type-constraints", typeConstraints,
	), nil
}

func resolvedTypeToJSON(rt ResolvedType) JSON {
	switch x := rt.(type) {
	case RPrim:
		return NewObject("kind", "prim", "name", x.Name)
	case RArray:
		return NewObject("kind", "array", "element", resolvedTypeToJSON(x.Element))
	case RRecord:
		fields := make([]JSON, len(x.Fields))
		for i, f := range x.Fields {
			fields[i] = NewObject("name", f.Name, "type", resolvedTypeToJSON(f.Type))
		}
		return NewObject("kind", "record", "fields", fields)
	case RUnion:
		arms := make([]JSON, len(x.Arms))
		for i, a := range x.Arms {
			arm := NewObject("name", a.Name)
			if a.Type != nil {
				arm.Set("payload", resolvedTypeToJSON(a.Type))
			}
			arms[i] = arm
		}
		return NewObject("kind", "union", "arms", arms)
	case RRef:
		return NewObject("kind", "ref", "id", CanonicalID(x))
	case RVar:
		return NewObject("kind", "var", "path", stringsJSON(x.Path))
	}
	panic("tramaj: unknown resolved type")
}

// Core evaluation.

func (c *evalCtx) eval(en *env, e Expr) value {
	switch x := e.(type) {
	case *Path:
		v, ok := en.lookup(x.Root)
		if !ok {
			evalFail("UnboundName", "%s", x.Root)
		}
		if len(x.Fields) == 0 {
			return v
		}
		return c.walkFields(append([]string{x.Root}, x.Fields...), v, x.Fields)
	case *FieldAccess:
		return c.walkFields(x.Fields, c.eval(en, x.Target), x.Fields)
	case *Call:
		fn := c.eval(en, x.Fn)
		return c.apply(describeCallee(x.Fn), fn, c.evalAll(en, x.Args))
	case *Lambda:
		return &vClosure{params: x.Params, body: x.Body, env: en}
	case *Let:
		var binding JSON
		if !isHiddenName(x.Name) {
			binding = x.Name
		}
		return c.eval(en.bind(x.Name, c.evalBindable(en, binding, x.Value)), x.Body)
	case *StringLit:
		return vStr(x.Value)
	case *IntLit:
		return vInt(x.Value)
	case *FloatLit:
		return vFloat(x.Value)
	case *BoolLit:
		return vBool(x.Value)
	case *NullLit:
		return vNull{}
	case *ArrayLit:
		return vArray(c.evalAll(en, x.Elements))
	case *ObjectLit:
		fields := NewOrderedMap[value]()
		for _, f := range x.Fields {
			fields.Set(f.Name, c.eval(en, f.Value))
		}
		return &vObject{fields}
	case *Element:
		n := &Node{Type: ElementNode, Tag: x.Tag, Attributes: make([]NodeAttribute, len(x.Attributes))}
		for i, a := range x.Attributes {
			switch at := a.(type) {
			case *Attr:
				n.Attributes[i] = NodeAttribute{Kind: PlainAttribute, Name: at.Name, Value: toJSON(c.eval(en, at.Value))}
			case *ActionAttr:
				n.Attributes[i] = NodeAttribute{Kind: ActionAttribute, Event: at.Event, Key: at.Key, Payload: toJSON(c.eval(en, at.Payload))}
			}
		}
		n.Value = toJSON(c.eval(en, x.Value))
		n.Children = c.evalChildren(en, x.Children)
		return &vNode{n}
	case *Fragment:
		return &vNode{&Node{Type: FragmentNode, Children: c.evalChildren(en, x.Children)}}
	case *Branch:
		if requireBool("a branch condition", c.eval(en, x.Condition)) {
			return c.eval(en, x.Then)
		}
		return c.eval(en, x.Else)
	case *Map:
		items := c.evalCollection(en, "map", x.Collection)
		fn := c.eval(en, x.Fn)
		out := make(vArray, len(items))
		for i, item := range items {
			out[i] = c.apply("map", fn, []value{item})
		}
		return out
	case *Filter:
		items := c.evalCollection(en, "filter", x.Collection)
		fn := c.eval(en, x.Fn)
		kept := vArray{}
		for _, item := range items {
			if requireBool("a filter predicate", c.apply("filter", fn, []value{item})) {
				kept = append(kept, item)
			}
		}
		return kept
	case *SortBy:
		who := "sort-by"
		if x.Descending {
			who = "sort-by-descending"
		}
		items := c.evalCollection(en, who, x.Collection)
		return c.sortBy(who, x.Descending, items, c.eval(en, x.Fn))
	case *Scan:
		items := c.evalCollection(en, "scan", x.Collection)
		acc := c.eval(en, x.Initial)
		fn := c.eval(en, x.Fn)
		out := vArray{acc}
		for _, item := range items {
			acc = c.apply("scan", fn, []value{acc, item})
			out = append(out, acc)
		}
		return out
	case *Fold:
		items := c.evalCollection(en, "fold", x.Collection)
		acc := c.eval(en, x.Initial)
		fn := c.eval(en, x.Fn)
		for _, item := range items {
			acc = c.apply("fold", fn, []value{acc, item})
		}
		return acc
	case *Concat:
		l := c.eval(en, x.Left)
		return concatValues(l, c.eval(en, x.Right))
	case *Import:
		params := NewOrderedMap[value]()
		for _, p := range x.Params {
			switch pv := p.Value.(type) {
			case *PExpr:
				params.Set(p.Name, c.eval(en, pv.Expr))
			case *PFromContext:
				ctxVal, ok := en.lookup("ctx")
				if !ok {
					evalFail("UnboundName", "ctx")
				}
				params.Set(p.Name, c.walkFields(append([]string{"ctx"}, pv.Path...), ctxVal, pv.Path))
			}
			// A %-marked entry supplies a type, not a value.
		}
		return &vImport{name: x.Name, params: params}
	case *AdaptActions:
		target := c.eval(en, x.Target)
		var fn value
		if x.Fn != nil {
			fn = c.eval(en, x.Fn)
		}
		return c.adaptValue(queuedAdaptation{x.Adaptation, fn}, target)
	case *Constrain:
		args := c.evalAll(en, x.Args)
		for _, a := range args {
			toJSON(a)
		}
		return &vConstraint{name: x.Name, args: args}
	case *Emit:
		c.em.constraints = append(c.em.constraints, collectConstraints(c.eval(en, x.Constraint))...)
		return c.eval(en, x.Body)
	case *Alloc, *Demand:
		return c.evalBindable(en, nil, e)
	case *TypeDecl:
		return c.eval(en, x.Body)
	case *TypeAnnotate:
		return c.eval(en.bind(x.Name, c.evalBindable(en, x.Name, x.Value)), x.Body)
	case *TypeEmit:
		return c.eval(en, x.Body)
	}
	panic("tramaj: unknown expression")
}

func (c *evalCtx) evalAll(en *env, es []Expr) []value {
	out := make([]value, len(es))
	for i, e := range es {
		out[i] = c.eval(en, e)
	}
	return out
}

// evalBindable evaluates the right-hand side of a binding: an allocation or
// demand sitting directly there records the name it is bound to.
func (c *evalCtx) evalBindable(en *env, binding JSON, e Expr) value {
	switch x := e.(type) {
	case *Alloc:
		return c.evalAlloc(en, binding, x)
	case *Demand:
		return c.evalDemand(en, binding, x.Path)
	}
	return c.eval(en, e)
}

func (c *evalCtx) evalAlloc(en *env, binding JSON, a *Alloc) value {
	key := requireConcrete("?(...)", c.eval(en, a.Key))
	if c.mode == Concrete {
		evalFail("SymbolsUnavailable", "?(...) would have to allocate a symbol, which concrete mode cannot represent")
	}
	id := "#" + strconv.Itoa(a.Site) + ":" + CompactJSON(key)
	c.em.symbols = append(c.em.symbols, symbolEntry{
		id:      id,
		origin:  NewObject("kind", "alloc", "site", int64(a.Site), "key", key),
		binding: binding,
	})
	return &vSymbol{id: id}
}

func (c *evalCtx) evalDemand(en *env, binding JSON, path []string) (v value) {
	nConstraints, nSymbols := len(c.em.constraints), len(c.em.symbols)
	err := try(func() { v = c.eval(en, &Path{Root: "ctx", Fields: path}) })
	if err == nil {
		return v
	}
	c.em.constraints = c.em.constraints[:nConstraints]
	c.em.symbols = c.em.symbols[:nSymbols]
	if err.Kind != "PathNotFound" || !c.isRoot {
		panic(err)
	}
	if c.mode == Concrete {
		evalFail("SymbolsUnavailable", "?ctx....  unsupplied at the root would have to allocate a symbol, which concrete mode cannot represent")
	}
	id := "#ctx"
	for _, p := range path {
		id += "." + p
	}
	c.em.symbols = append(c.em.symbols, symbolEntry{
		id:      id,
		origin:  NewObject("kind", "demand", "path", stringsJSON(path)),
		binding: binding,
	})
	return &vSymbol{id: id}
}

func collectConstraints(v value) []*vConstraint {
	switch x := v.(type) {
	case *vConstraint:
		return []*vConstraint{x}
	case vArray:
		var out []*vConstraint
		for _, item := range x {
			out = append(out, collectConstraints(item)...)
		}
		return out
	}
	typeMismatch("! expects a constraint or an array of them, got %s", describeValue(v))
	return nil
}

func describeCallee(e Expr) string {
	if p, ok := e.(*Path); ok {
		return strings.Join(append([]string{p.Root}, p.Fields...), ".")
	}
	return "a call"
}

// Documents.

func (c *evalCtx) evalChildren(en *env, children []Expr) []*Node {
	out := []*Node{}
	for _, e := range children {
		out = appendChildNodes(out, c.eval(en, e))
	}
	return out
}

func appendChildNodes(out []*Node, v value) []*Node {
	switch x := v.(type) {
	case *vNode:
		return append(out, x.node)
	case vArray:
		for _, item := range x {
			out = appendChildNodes(out, item)
		}
		return out
	}
	return append(out, &Node{Type: TextNode, Value: toJSON(v)})
}

// Application.

func (c *evalCtx) apply(who string, f value, args []value) value {
	switch fn := f.(type) {
	case *vClosure:
		if len(fn.params) != len(args) {
			typeMismatch("closure expects %d argument(s), got %d", len(fn.params), len(args))
		}
		en := fn.env
		for i, p := range fn.params {
			en = en.bind(p, args[i])
		}
		return c.eval(en, fn.body)
	case vBuiltin:
		return evalBuiltin(string(fn), args)
	case *vImport:
		if len(args) != 1 {
			typeMismatch("%s: the import of %q expects exactly 1 argument, the parameters to add", who, fn.name)
		}
		only, ok := args[0].(*vObject)
		if !ok {
			typeMismatch("%s: the import of %q takes an object of parameters, got %s", who, fn.name, describeValue(args[0]))
		}
		params := fn.params.clone()
		for _, k := range only.fields.Keys() {
			v, _ := only.fields.Get(k)
			params.Set(k, v)
		}
		return &vImport{name: fn.name, params: params, queued: fn.queued}
	}
	typeMismatch("%s is not callable: %s", who, describeValue(f))
	return nil
}

func (c *evalCtx) evalCollection(en *env, who string, e Expr) vArray {
	switch v := c.eval(en, e).(type) {
	case vArray:
		return v
	case *vSymbol, *vTerm:
		notConcrete(who)
	default:
		typeMismatch("%s expects an array as its first argument, got %s", who, describeValue(v))
	}
	return nil
}

// Sorting (specs/reference.md section 11).

// sortBy orders items by the key fn gives each of them. fn is applied once
// per element, in index order, and each key is checked as soon as it is
// known, so the first element whose application or key fails decides the
// error, and nothing is reordered before every key has passed. The keys of
// one call are all integers, all floats or all strings.
//
// Element i precedes element j when its key is smaller (larger, when
// descending), or when the keys are equal and i < j. A stable sort with a
// strict comparison of the keys gives exactly that order, for both
// directions: descending is not the reversal of ascending, which would
// reverse the ties as well.
func (c *evalCtx) sortBy(who string, descending bool, items vArray, fn value) vArray {
	keys := make([]value, len(items))
	for i, item := range items {
		key := c.apply(who, fn, []value{item})
		switch key.(type) {
		case vInt, vFloat, vStr:
		case *vSymbol, *vTerm:
			notConcrete(who)
		default:
			typeMismatch("%s: a key must be an integer, a float or a string, got %s", who, describeValue(key))
		}
		if i > 0 && keyKind(key) != keyKind(keys[0]) {
			typeMismatch("%s: the keys of one call are all integers, all floats or all strings, got %s after %s", who, describeValue(key), describeValue(keys[0]))
		}
		keys[i] = key
	}
	order := make([]int, len(items))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool {
		cmp := compareKeys(keys[order[a]], keys[order[b]])
		if descending {
			return cmp > 0
		}
		return cmp < 0
	})
	out := make(vArray, len(items))
	for i, at := range order {
		out[i] = items[at]
	}
	return out
}

// keyKind tells the three types a sort key may have apart.
func keyKind(key value) int {
	switch key.(type) {
	case vInt:
		return 0
	case vFloat:
		return 1
	}
	return 2
}

// compareKeys is -1, 0 or 1 for two keys of the same type. Strings compare
// by Unicode code point, which is the byte order of their UTF-8 encoding and
// so Go's own string comparison; it is not the UTF-16 order lessUTF16 gives.
func compareKeys(a, b value) int {
	switch x := a.(type) {
	case vInt:
		return compareOrdered(x, b.(vInt))
	case vFloat:
		return compareOrdered(x, b.(vFloat))
	}
	return strings.Compare(string(a.(vStr)), string(b.(vStr)))
}

// Concat.

func concatValues(l, r value) value {
	if isSymbolic(l) || isSymbolic(r) {
		notConcrete("<>")
	}
	switch a := l.(type) {
	case vStr:
		if b, ok := r.(vStr); ok {
			return a + b
		}
	case vArray:
		if b, ok := r.(vArray); ok {
			return append(append(vArray{}, a...), b...)
		}
	case *vObject:
		if b, ok := r.(*vObject); ok {
			fields := a.fields.clone()
			for _, k := range b.fields.Keys() {
				v, _ := b.fields.Get(k)
				fields.Set(k, v)
			}
			return &vObject{fields}
		}
	}
	evalFail("ConcatMismatch", "%s and %s", describeValue(l), describeValue(r))
	return nil
}

// Imports.

func (c *evalCtx) forceImport(imp *vImport) value {
	v := c.runLibrary(imp.name, &vObject{imp.params.clone()})
	for _, q := range imp.queued {
		v = c.adaptValue(q, v)
	}
	return v
}

func (c *evalCtx) runLibrary(name string, ctxVal value) value {
	if c.inProgress[name] {
		evalFail("ImportCycle", "%s", name)
	}
	rawProg := c.libs[name]
	if rawProg == nil {
		evalFail("UnknownLibrary", "%s", name)
	}
	// Checked lexically before evaluating anything and deliberately not
	// wrapped in InLibrary: this is a property of the library's own source.
	if len(SymbolSites(rawProg)) > 0 {
		evalFail("AllocationInLibrary", "%s", name)
	}
	prog := withTypeErrors(func() *Program { return eraseTypes(c.libs, rawProg) })

	inProgress := map[string]bool{name: true}
	for k := range c.inProgress {
		inProgress[k] = true
	}
	lib := &evalCtx{libs: c.libs, inProgress: inProgress, mode: c.mode, arithmetic: c.arithmetic, isRoot: false, em: c.em}

	var result value
	err := try(func() {
		stmts, root := Unlets(prog.Root)
		en := initialEnv(lib.arithmetic, ctxVal)
		var names []string
		for _, s := range stmts {
			switch s.Kind {
			case StmtLet, StmtAnnotate:
				en = en.bind(s.Name, lib.eval(en, s.Value))
				if !isHiddenName(s.Name) {
					names = append(names, s.Name)
				}
			case StmtEmit:
				lib.em.constraints = append(lib.em.constraints, collectConstraints(lib.eval(en, s.Value))...)
			}
		}
		rendered := lib.eval(en, root)
		vals := NewOrderedMap[value]()
		for _, n := range names {
			v, _ := en.lookup(n)
			vals.Set(n, v)
		}
		fields := NewOrderedMap[value]()
		fields.Set("rendered", rendered)
		fields.Set("vals", &vImportResult{vals})
		result = &vImportResult{fields}
	})
	if err != nil {
		panic(&EvalError{Kind: "InLibrary", Detail: fmt.Sprintf("%s (%s)", name, err.Error()), Cause: err})
	}
	return result
}

// Action adaptation.

func (c *evalCtx) adaptValue(q queuedAdaptation, v value) value {
	adaptFields := func(fields *OrderedMap[value]) *OrderedMap[value] {
		out := NewOrderedMap[value]()
		for _, k := range fields.Keys() {
			x, _ := fields.Get(k)
			out.Set(k, c.adaptValue(q, x))
		}
		return out
	}
	switch x := v.(type) {
	case *vNode:
		return &vNode{mapActions(x.node, func(a NodeAttribute) NodeAttribute { return c.adaptAction(q, a) })}
	case *vImportResult:
		return &vImportResult{adaptFields(x.fields)}
	case *vObject:
		return &vObject{adaptFields(x.fields)}
	case vArray:
		out := make(vArray, len(x))
		for i, item := range x {
			out[i] = c.adaptValue(q, item)
		}
		return out
	case *vImport:
		queued := append(append([]queuedAdaptation(nil), x.queued...), q)
		return &vImport{name: x.name, params: x.params, queued: queued}
	}
	return v
}

func (c *evalCtx) adaptAction(q queuedAdaptation, a NodeAttribute) NodeAttribute {
	a.Key = adaptKey(q.adaptation, a.Key)
	if q.fn == nil {
		return a
	}
	action := NewOrderedMap[value]()
	action.Set("eventType", vStr(a.Event))
	action.Set("key", vStr(a.Key))
	action.Set("payload", fromJSON(a.Payload))
	result, ok := toJSON(c.apply("adapt-actions", q.fn, []value{&vObject{action}})).(*Object)
	if !ok {
		typeMismatch("adapt-actions: the function must return an object with an eventType field")
	}
	eventType, _ := result.Get("eventType")
	event, ok := eventType.(string)
	if !ok {
		typeMismatch(`adapt-actions: the function's result needs a string "eventType" field`)
	}
	a.Event = event
	a.Payload, _ = result.Get("payload")
	return a
}

// Paths and fields.

func (c *evalCtx) walkFields(context []string, v value, fields []string) value {
	for i := 0; i < len(fields); {
		var container *OrderedMap[value]
		switch x := v.(type) {
		case *vObject:
			container = x.fields
		case *vImportResult:
			container = x.fields
		case *vImport:
			v = c.forceImport(x)
			continue
		case *vSymbol:
			// Projection (section 1.6): reads nothing, and is never rejected.
			path := append(append([]string(nil), x.path...), fields[i:]...)
			return &vSymbol{id: x.id, path: path}
		default:
			typeMismatch("cannot read field %q of %s in path %q", fields[i], describeValue(v), strings.Join(context, "."))
		}
		next, ok := container.Get(fields[i])
		if !ok {
			evalFail("PathNotFound", "%s", pathKey(context))
		}
		v = next
		i++
	}
	return v
}

// Conversion.

// toJSON goes down to JSON, at the boundaries where only JSON is meaningful.
func toJSON(v value) JSON {
	switch x := v.(type) {
	case vNull:
		return nil
	case vBool:
		return bool(x)
	case vInt:
		return int64(x)
	case vFloat:
		return float64(x)
	case vStr:
		return string(x)
	case *vTerm:
		args := make([]JSON, len(x.args))
		for i, a := range x.args {
			args[i] = toJSON(a)
		}
		return NewObject("$term", x.op, "arguments", args)
	case vArray:
		out := make([]JSON, len(x))
		for i, item := range x {
			out[i] = toJSON(item)
		}
		return out
	case *vObject:
		out := NewObject()
		for _, k := range x.fields.Keys() {
			item, _ := x.fields.Get(k)
			out.Set(k, toJSON(item))
		}
		return out
	case *vNode:
		typeMismatch("a document node is not a plain value -- nest it as a child rather than using it where a value is expected")
	case *vClosure:
		typeMismatch("expected a value, got a function -- call it first, e.g. $my-fn(...)")
	case vBuiltin:
		typeMismatch("expected a value, got the builtin %q -- call it first", string(x))
	case *vImportResult:
		typeMismatch("expected a value, got an import result -- read .rendered, .vals, or a binding name from it first")
	case *vImport:
		typeMismatch("expected a value, got the import of %q -- read .rendered or .vals from it to run it first", x.name)
	case *vSymbol:
		return NewObject("$sym", x.id, "path", stringsJSON(x.path))
	case *vConstraint:
		typeMismatch(`a constraint (%q) cannot cross a JSON boundary -- only "!" may consume it`, x.name)
	}
	panic("tramaj: unknown value")
}

// isSymbolic reports whether a value is itself a symbol or a term
// (v3-symbols.md section 1.9), which is the depth at which a container, a
// collection, a condition or an operand is refused: a concrete structure that
// merely holds one is not special (section 1.7). containsSymbol is the other
// depth.
func isSymbolic(v value) bool {
	switch v.(type) {
	case *vSymbol, *vTerm:
		return true
	}
	return false
}

// containsSymbol reports whether a value is, or contains, a symbol or a term.
func containsSymbol(v value) bool {
	switch x := v.(type) {
	case *vSymbol, *vTerm:
		return true
	case vArray:
		for _, item := range x {
			if containsSymbol(item) {
				return true
			}
		}
	case *vObject:
		for _, k := range x.fields.Keys() {
			if item, _ := x.fields.Get(k); containsSymbol(item) {
				return true
			}
		}
	}
	return false
}

func requireConcrete(who string, v value) JSON {
	if containsSymbol(v) {
		notConcrete(who)
	}
	return toJSON(v)
}

func fromJSON(v JSON) value {
	return convertJSON(v, func(*Object) value { return nil })
}

// convertJSON lifts JSON into values; object intercepts an object before its
// fields are converted, returning nil to let the conversion proceed.
func convertJSON(v JSON, object func(*Object) value) value {
	switch x := v.(type) {
	case nil:
		return vNull{}
	case bool:
		return vBool(x)
	case int64:
		return vInt(x)
	case float64:
		return vFloat(normalizeNumber(x))
	case string:
		return vStr(x)
	case []JSON:
		out := make(vArray, len(x))
		for i, item := range x {
			out[i] = convertJSON(item, object)
		}
		return out
	case *Object:
		if special := object(x); special != nil {
			return special
		}
		fields := NewOrderedMap[value]()
		for _, k := range x.Keys() {
			item, _ := x.Get(k)
			fields.Set(k, convertJSON(item, object))
		}
		return &vObject{fields}
	}
	typeMismatch("the context holds a value JSON cannot represent: %v", v)
	return nil
}

// checkedFromJSON is the input context's boundary, decoding the whole
// context before evaluation starts (specs/reference.md section 3,
// v3-symbols.md section 5.3). Every refusal is a TypeMismatch.
//
// First the numbers, by NormalizeNumbers: an integer outside the integer
// range and a float too large for a double are refused, at any depth.
//
// Then the reserved keys: "$sym", "$type" and "$term" are recursively refused
// as ordinary object keys, in every profile. In concrete mode each is refused
// unconditionally. In symbolic mode, seeding (section 5.4) accepts a
// well-formed {"$sym": ..., "path": [...]} back as a symbol and, with the
// arithmetic profile on, a well-formed term back as a term.
func checkedFromJSON(options Options, v JSON) value {
	normalized, err := NormalizeNumbers(v)
	if err != nil {
		typeMismatch("the context holds a number that is not a value: %v", err)
	}
	var object func(obj *Object) value
	object = func(obj *Object) value {
		if obj.Has("$type") {
			typeMismatch(`the context carries the reserved key "$type", which only a typed envelope may use`)
		}
		if sym, isSym := obj.Get("$sym"); isSym {
			if options.Mode == Concrete {
				typeMismatch(`the context carries the reserved key "$sym", which only a symbolic envelope may use`)
			}
			id, okID := sym.(string)
			rawPath, _ := obj.Get("path")
			segments, okPath := rawPath.([]JSON)
			if !okID || !okPath || obj.Len() != 2 {
				typeMismatch(`a "$sym" object must be exactly {"$sym": <id>, "path": [<segment>, ...]}`)
			}
			path := make([]string, len(segments))
			for i, s := range segments {
				seg, ok := s.(string)
				if !ok {
					typeMismatch(`a symbol reference's "path" must be an array of strings`)
				}
				path[i] = seg
			}
			return &vSymbol{id: id, path: path}
		}
		term, isTerm := obj.Get("$term")
		if !isTerm {
			return nil
		}
		if options.Mode == Concrete {
			typeMismatch(`the context carries the reserved key "$term", which only a symbolic envelope may use`)
		}
		op, okOp := term.(string)
		rawArgs, _ := obj.Get("arguments")
		arguments, okArgs := rawArgs.([]JSON)
		if !okOp || !okArgs || obj.Len() != 2 {
			typeMismatch(`a "$term" object must be exactly {"$term": <op>, "arguments": [<argument>, ...]}`)
		}
		args := make([]value, len(arguments))
		for i, a := range arguments {
			args[i] = convertJSON(a, object)
		}
		return seededTerm(options, op, args)
	}
	return convertJSON(normalized, object)
}

// seededTerm checks a term found in the context. A well-formed term is one a
// call could have built (v3-symbols.md section 5.3), so this is the call's
// own check, arithmeticOperands, on arguments already decoded, which holds a
// nested term to the same rule. Two things a call accepts are refused first:
// an array, since a term holds its operands already flattened, and operands
// that are all numbers, since the call would have computed. Without the
// arithmetic profile no op is known, so every term is refused.
func seededTerm(options Options, op string, args []value) value {
	if !options.Arithmetic {
		typeMismatch("the context carries a term (%q), which needs the arithmetic profile", op)
	}
	if !slices.Contains(ArithmeticNames, op) {
		typeMismatch("a term names an unknown operation: %q", op)
	}
	for _, a := range args {
		if _, isArray := a.(vArray); isArray {
			typeMismatch("a term (%q) holds its operands flattened, not in an array", op)
		}
	}
	operands := arithmeticOperands(op, args)
	if !slices.ContainsFunc(operands, isSymbolic) {
		typeMismatch("a term (%q) must hold a symbol or a term among its arguments", op)
	}
	return &vTerm{op: op, args: operands}
}

func describeValue(v value) string {
	switch x := v.(type) {
	case vNull:
		return "null"
	case vBool:
		return "a boolean"
	case vInt:
		return "an integer"
	case vFloat:
		return "a float"
	case *vTerm:
		return fmt.Sprintf("a term (%q)", x.op)
	case vStr:
		return "a string"
	case vArray:
		return "an array"
	case *vObject:
		return "an object"
	case *vNode:
		return "a document node"
	case *vClosure:
		return "a function"
	case *vImportResult:
		return "an import result"
	case *vSymbol:
		return "a symbol"
	case vBuiltin:
		return fmt.Sprintf("the builtin %q", string(x))
	case *vImport:
		return fmt.Sprintf("the not-yet-run import of %q", x.name)
	case *vConstraint:
		return fmt.Sprintf("a constraint (%q)", x.name)
	}
	return "an unknown value"
}

func requireBool(who string, v value) bool {
	switch x := v.(type) {
	case vBool:
		return bool(x)
	case *vSymbol, *vTerm:
		notConcrete(who)
	}
	typeMismatch("%s must be a boolean, got %s", who, describeValue(v))
	return false
}

// Builtins.

func evalBuiltin(name string, args []value) value {
	arity := func(n int) {
		if len(args) != n {
			typeMismatch("%s expects exactly %d argument(s), got %d", name, n, len(args))
		}
	}
	asBool := func(v value) bool {
		b, ok := v.(vBool)
		if !ok {
			typeMismatch("%s expects a boolean argument, got %s", name, describeValue(v))
		}
		return bool(b)
	}
	// A number operand, returned as it is so that its type is still there to
	// check. A symbol or a term is NotConcrete (v3-symbols.md section 1.5).
	asNumber := func(v value) value {
		switch v.(type) {
		case vInt, vFloat:
			return v
		case *vSymbol, *vTerm:
			notConcrete(name)
		}
		typeMismatch("%s expects a number argument, got %s", name, describeValue(v))
		return nil
	}
	asArray := func(v value) vArray {
		a, ok := v.(vArray)
		if !ok {
			typeMismatch("%s expects an array argument, got %s", name, describeValue(v))
		}
		return a
	}

	if slices.Contains(ArithmeticNames, name) {
		return arithmetic(name, args)
	}

	switch name {
	case "cardinality", "count":
		arity(1)
		switch a := args[0].(type) {
		case vArray:
			return vInt(len(a))
		case *vObject:
			return vInt(a.fields.Len())
		case *vSymbol, *vTerm:
			notConcrete(name)
		}
		typeMismatch("%s expects an array or object, got %s", name, describeValue(args[0]))
	case "str":
		arity(1)
		return vStr(DisplayString(requireConcrete(name, args[0])))
	case "not":
		arity(1)
		return vBool(!asBool(args[0]))
	case "and":
		// Short-circuits: an argument after the first false is not inspected.
		acc := true
		for _, a := range args {
			acc = acc && asBool(a)
		}
		return vBool(acc)
	case "or":
		acc := false
		for _, a := range args {
			acc = acc || asBool(a)
		}
		return vBool(acc)
	case "eq":
		arity(2)
		a := requireConcrete(name, args[0])
		return vBool(JSONEqual(a, requireConcrete(name, args[1])))
	case "lt", "lte", "gt", "gte":
		arity(2)
		// Two integers or two floats (specs/reference.md section 11). A mixed
		// pair is a TypeMismatch like any other pair of two types: nothing is
		// promoted, so gt(1.5, 0) is written gt(1.5, 0.0). Each pair is
		// compared in its own domain.
		a, b := asNumber(args[0]), asNumber(args[1])
		var order int
		switch x := a.(type) {
		case vInt:
			y, ok := b.(vInt)
			if !ok {
				typeMismatch("%s expects two integers or two floats, got %s and %s", name, describeValue(a), describeValue(b))
			}
			order = compareOrdered(x, y)
		case vFloat:
			y, ok := b.(vFloat)
			if !ok {
				typeMismatch("%s expects two integers or two floats, got %s and %s", name, describeValue(a), describeValue(b))
			}
			order = compareOrdered(x, y)
		}
		switch name {
		case "lt":
			return vBool(order < 0)
		case "lte":
			return vBool(order <= 0)
		case "gt":
			return vBool(order > 0)
		}
		return vBool(order >= 0)
	case "has":
		arity(2)
		_, found := lookupIn(name, args[0], args[1])
		return vBool(found)
	case "lookup":
		arity(3)
		if v, found := lookupIn(name, args[0], args[1]); found {
			return v
		}
		return args[2]
	case "concat":
		out := vArray{}
		for _, a := range args {
			out = append(out, asArray(a)...)
		}
		return out
	case "append":
		arity(2)
		return append(append(vArray{}, asArray(args[0])...), args[1])
	case "format-number":
		// The arguments are examined left to right, and the first that is not
		// acceptable decides the error.
		arity(3)
		x := asNumber(args[0])
		decimals, ok := args[1].(vInt)
		if !ok {
			if isSymbolic(args[1]) {
				notConcrete(name)
			}
			typeMismatch("%s expects an integer number of decimals, got %s", name, describeValue(args[1]))
		}
		if decimals < 0 || decimals > 20 {
			typeMismatch("%s expects from 0 to 20 decimals, got %d", name, int64(decimals))
		}
		group, ok := args[2].(vStr)
		if !ok {
			if isSymbolic(args[2]) {
				notConcrete(name)
			}
			typeMismatch("%s expects a string as its group separator, got %s", name, describeValue(args[2]))
		}
		exact := new(big.Rat)
		switch n := x.(type) {
		case vInt:
			exact.SetInt64(int64(n))
		case vFloat:
			// A float here is finite, so this is its exact value.
			exact.SetFloat64(float64(n))
		}
		return vStr(formatExact(exact, int(decimals), string(group)))
	}
	evalFail("UnboundName", "%s", name)
	return nil
}

// lookupIn is deliberately tolerant: a missing key, an out-of-range index, or
// a container of the wrong shape all answer "not found", except a symbolic
// container, which is NotConcrete rather than a lie.
func lookupIn(name string, container, key value) (value, bool) {
	switch c := container.(type) {
	case *vSymbol, *vTerm:
		notConcrete(name)
	case *vObject:
		if k, ok := key.(vStr); ok {
			return c.fields.Get(string(k))
		}
	case vArray:
		// An index is a non-negative integer: -1 is not an index, and neither
		// is a float, 1.0 included, since nothing converts a float into an
		// integer here.
		if k, ok := key.(vInt); ok && k >= 0 && int64(k) < int64(len(c)) {
			return c[int(k)], true
		}
	}
	return nil, false
}

// formatExact writes an exact value in positional decimal notation
// (specs/reference.md section 11, Number formatting): the multiple of
// 10^-decimals nearest to it, and of two equally near the one farther from
// zero. Never an exponent, never a negative zero, and group between each
// group of three digits of the integer part. No formatter of the standard
// library follows that rule (strconv rounds ties to even and writes -0.00),
// so it is written out on integers: v * 10^decimals is a fraction n/d, and
// the result is its quotient, one more when twice the remainder reaches d.
func formatExact(v *big.Rat, decimals int, group string) string {
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(decimals)), nil)
	num := new(big.Int).Mul(new(big.Int).Abs(v.Num()), scale)
	q, r := new(big.Int).QuoRem(num, v.Denom(), new(big.Int))
	if r.Lsh(r, 1).Cmp(v.Denom()) >= 0 {
		q.Add(q, big.NewInt(1))
	}
	digits := q.String()
	// At least one digit before the point: 0.50, never .50.
	if pad := decimals + 1 - len(digits); pad > 0 {
		digits = strings.Repeat("0", pad) + digits
	}
	whole, fraction := digits[:len(digits)-decimals], digits[len(digits)-decimals:]
	var b strings.Builder
	// A result whose digits are all zero carries no sign.
	if v.Sign() < 0 && q.Sign() != 0 {
		b.WriteByte('-')
	}
	for i := 0; i < len(whole); i++ {
		if i > 0 && (len(whole)-i)%3 == 0 {
			b.WriteString(group)
		}
		b.WriteByte(whole[i])
	}
	if decimals > 0 {
		b.WriteByte('.')
		b.WriteString(fraction)
	}
	return b.String()
}

// compareOrdered is -1, 0 or 1 as a is below, equal to or above b. A float
// here is finite, so the three cases are exhaustive.
func compareOrdered[T vInt | vFloat](a, b T) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// Arithmetic (specs/reference.md section 11).

// arithmetic applies one of the arithmetic builtins. Operands that are all
// numbers compute; if one is a symbol or a term the result is a term holding
// the flattened operands exactly as written (v3-symbols.md section 1.9).
// Every operand is checked before either happens, so a TypeMismatch takes
// precedence over a NotRepresentable.
func arithmetic(name string, args []value) value {
	operands := arithmeticOperands(name, args)
	if slices.ContainsFunc(operands, isSymbolic) {
		return &vTerm{op: name, args: operands}
	}
	return compute(name, operands)
}

// arithmeticOperands gives the operands of a call, checked as far as they can
// be without knowing what a symbol stands for; every refusal is a
// TypeMismatch.
//
//   - sum and product flatten their arguments by the rule children use: an
//     array contributes each of its elements, recursively, in order. They
//     need at least one operand afterwards. The eight others take a fixed
//     count and do not flatten, so an array given to one is refused whatever
//     it holds.
//   - Each operand is a number, a symbol or a term. A symbol or a term stands
//     for one number of either type and is not looked into.
//   - The operands that are numbers agree with each other in type and with
//     what the builtin accepts. Nothing is converted or promoted.
func arithmeticOperands(name string, args []value) []value {
	operands := args
	switch name {
	case "sum", "product":
		operands = flattenOperands(nil, args)
		if len(operands) == 0 {
			typeMismatch("%s expects at least one operand: seed it with the zero or the one of the intended type", name)
		}
	default:
		arity := 1
		if name == "quotient" || name == "floor-quotient" || name == "modulo" {
			arity = 2
		}
		if len(args) != arity {
			typeMismatch("%s expects exactly %d argument(s), got %d", name, arity, len(args))
		}
	}
	ints, floats := 0, 0
	for _, v := range operands {
		switch v.(type) {
		case vInt:
			ints++
		case vFloat:
			floats++
		case *vSymbol, *vTerm:
		default:
			typeMismatch("%s expects number operands, got %s", name, describeValue(v))
		}
	}
	wanted := ""
	switch name {
	case "quotient", "inverse":
		if ints > 0 {
			wanted = "floats only"
		}
	case "floor-quotient", "modulo":
		if floats > 0 {
			wanted = "integers only"
		}
	case "sum", "product":
		if ints > 0 && floats > 0 {
			wanted = "all integers or all floats"
		}
	}
	// negate, floor, real and round take a number of either type.
	if wanted != "" {
		typeMismatch("%s expects %s, got %d integer(s) and %d float(s)", name, wanted, ints, floats)
	}
	return operands
}

func flattenOperands(out []value, args []value) []value {
	for _, a := range args {
		if arr, ok := a.(vArray); ok {
			out = flattenOperands(out, arr)
		} else {
			out = append(out, a)
		}
	}
	return out
}

// compute applies the concrete rules (specs/reference.md section 11,
// Semantics) to operands arithmeticOperands accepted and that are all
// numbers.
//
// An integer result is checked at every step of a fold and nothing wraps: Go's
// own int64 operators wrap silently, so each one is guarded here.
//
// A float result is one float64 operation at a time, correctly rounded to
// nearest, ties to even. Each is written as an explicit float64(...)
// conversion, which the Go specification says rounds to the precision of the
// type and so keeps a compiler from fusing a product and a sum into a fused
// multiply-add on the architectures where it otherwise may.
func compute(name string, operands []value) value {
	finite := func(d float64) vFloat {
		if math.IsNaN(d) || math.IsInf(d, 0) {
			notRepresentable("%s: the result is not a finite float", name)
		}
		// There is no negative zero.
		return vFloat(normalizeNumber(d))
	}
	outOfRange := func() {
		notRepresentable("%s: the result is outside the integer range, -2^63 to 2^63 - 1", name)
	}
	nonZero := func(b vInt) {
		if b == 0 {
			notRepresentable("%s: the divisor is zero", name)
		}
	}

	switch name {
	case "sum", "product":
		// A left fold from the first operand, each step checked: an integer
		// step out of range is an error although the total would be in range.
		switch acc := operands[0].(type) {
		case vInt:
			for _, o := range operands[1:] {
				var ok bool
				if name == "sum" {
					acc, ok = addInt(acc, o.(vInt))
				} else {
					acc, ok = mulInt(acc, o.(vInt))
				}
				if !ok {
					outOfRange()
				}
			}
			return acc
		case vFloat:
			for _, o := range operands[1:] {
				if name == "sum" {
					acc = finite(float64(float64(acc) + float64(o.(vFloat))))
				} else {
					acc = finite(float64(float64(acc) * float64(o.(vFloat))))
				}
			}
			return acc
		}
	case "negate":
		switch x := operands[0].(type) {
		case vInt:
			if x == math.MinInt64 {
				outOfRange()
			}
			return -x
		case vFloat:
			return finite(-float64(x))
		}
	case "quotient":
		return finite(float64(float64(operands[0].(vFloat)) / float64(operands[1].(vFloat))))
	case "inverse":
		return finite(float64(1 / float64(operands[0].(vFloat))))
	case "floor-quotient":
		// Go's / truncates toward zero; the floor is one below it when the
		// division is inexact and the operands differ in sign.
		a, b := operands[0].(vInt), operands[1].(vInt)
		nonZero(b)
		if a == math.MinInt64 && b == -1 {
			outOfRange()
		}
		q := a / b
		if a%b != 0 && (a < 0) != (b < 0) {
			q--
		}
		return q
	case "modulo":
		// The remainder of the floored division: zero or of the sign of the
		// divisor. It is checked on its own: the remainder of -2^63 by -1 is
		// 0, although the quotient of the same pair is out of range.
		a, b := operands[0].(vInt), operands[1].(vInt)
		nonZero(b)
		if b == -1 {
			return vInt(0)
		}
		r := a % b
		if r != 0 && (r < 0) != (b < 0) {
			r += b
		}
		return r
	case "floor":
		switch x := operands[0].(type) {
		case vInt:
			return x
		case vFloat:
			// Both bounds are powers of two, so each is a double exactly:
			// the floor is in range when it is at least -2^63 and below 2^63.
			f := math.Floor(float64(x))
			if f < -9223372036854775808.0 || f >= 9223372036854775808.0 {
				outOfRange()
			}
			return vInt(int64(f))
		}
	case "round":
		switch x := operands[0].(type) {
		case vInt:
			return x
		case vFloat:
			// math.Round gives the integer nearest to the exact value, and of
			// two equally near the one farther from zero; it adds no 0.5, so
			// 0.49999999999999994 rounds to 0. The range is checked as for
			// floor.
			r := math.Round(float64(x))
			if r < -9223372036854775808.0 || r >= 9223372036854775808.0 {
				outOfRange()
			}
			return vInt(int64(r))
		}
	case "real":
		switch x := operands[0].(type) {
		case vInt:
			// The double nearest to the integer, ties to even: exact up to
			// 2^53, rounded beyond. This is the machine's own conversion.
			return vFloat(float64(x))
		case vFloat:
			return x
		}
	}
	typeMismatch("%s cannot be applied to its operands", name)
	return nil
}

// addInt is a + b, and false when the sum is outside the int64 range.
func addInt(a, b vInt) (vInt, bool) {
	s := a + b
	if (b > 0 && s < a) || (b < 0 && s > a) {
		return 0, false
	}
	return s, true
}

// mulInt is a * b, and false when the product is outside the int64 range.
func mulInt(a, b vInt) (vInt, bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	// -2^63 * -1 wraps back to -2^63, which the division below would not
	// notice, so that pair is tested first.
	if (a == -1 && b == math.MinInt64) || (b == -1 && a == math.MinInt64) {
		return 0, false
	}
	p := a * b
	if p/b != a {
		return 0, false
	}
	return p, true
}
