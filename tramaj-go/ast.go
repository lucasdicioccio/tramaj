// Package tramaj is a native Go implementation of the Tramaj language:
// parser, evaluator (concrete and symbolic modes), the normative Node JSON
// codec, and the static analyses. Agreement with the other implementations is
// enforced by the shared corpus at ../corpus/cases.
package tramaj

import "strings"

// Core AST (specs/reference.md section 2, specs/v3-symbols.md section 3,
// specs/v4-types.md section 1). Mirrors tramaj-py/tramaj/ast.py.

type ProgramKind string

const (
	DocumentProgram   ProgramKind = "document"
	ExpressionProgram ProgramKind = "expression"
)

type Program struct {
	Kind ProgramKind
	Root Expr
}

// Type expressions (v4-types section 1).

type TypeExpr interface{ isTypeExpr() }

type (
	TPrim   struct{ Name string }
	TArray  struct{ Element TypeExpr }
	TRecord struct{ Fields []TypeField }
	TUnion  struct{ Arms []UnionArm }
	TName   struct{ Name string }
	TLibRef struct{ Lib, Name string }
	TVar    struct{ Path []string }
)

type TypeField struct {
	Name string
	Type TypeExpr
}

// UnionArm is one arm of a union; Payload is nil for a nullary arm.
type UnionArm struct {
	Name    string
	Payload TypeExpr
}

func (*TPrim) isTypeExpr()   {}
func (*TArray) isTypeExpr()  {}
func (*TRecord) isTypeExpr() {}
func (*TUnion) isTypeExpr()  {}
func (*TName) isTypeExpr()   {}
func (*TLibRef) isTypeExpr() {}
func (*TVar) isTypeExpr()    {}

// TypeConstraintArg is an argument of !type-constraint: a type when Type is
// non-nil, otherwise the scalar (nil, bool, float64 or string) in Scalar.
type TypeConstraintArg struct {
	Type   TypeExpr
	Scalar JSON
}

// Import parameters.

type ParamValue interface{ isParamValue() }

type (
	PExpr        struct{ Expr Expr }
	PFromContext struct{ Path []string }
	PType        struct{ Type TypeExpr }
)

func (*PExpr) isParamValue()        {}
func (*PFromContext) isParamValue() {}
func (*PType) isParamValue()        {}

type Param struct {
	Name  string
	Value ParamValue
}

// Attributes and adaptations.

type Attribute interface{ isAttribute() }

type Attr struct {
	Name  string
	Value Expr
}

type ActionAttr struct {
	Event, Key string
	Payload    Expr
}

func (*Attr) isAttribute()       {}
func (*ActionAttr) isAttribute() {}

// ActionAdaptation is identity (the zero value) or prefix("...").
type ActionAdaptation struct {
	IsPrefix bool
	Prefix   string
}

func adaptKey(a ActionAdaptation, key string) string {
	if !a.IsPrefix {
		return key
	}
	return a.Prefix + key
}

// Expressions.

type Expr interface{ isExpr() }

type Field struct {
	Name  string
	Value Expr
}

type (
	Path struct {
		Root   string
		Fields []string
	}
	FieldAccess struct {
		Target Expr
		Fields []string
	}
	Call struct {
		Fn   Expr
		Args []Expr
	}
	Lambda struct {
		Params []string
		Body   Expr
	}
	Let struct {
		Name        string
		Value, Body Expr
	}
	StringLit struct{ Value string }
	NumberLit struct{ Value float64 }
	BoolLit   struct{ Value bool }
	NullLit   struct{}
	ArrayLit  struct{ Elements []Expr }
	ObjectLit struct{ Fields []Field }
	Element   struct {
		Tag        string
		Attributes []Attribute
		Value      Expr
		Children   []Expr
	}
	Fragment struct{ Children []Expr }
	Branch   struct{ Condition, Then, Else Expr }
	Map      struct{ Collection, Fn Expr }
	Filter   struct{ Collection, Fn Expr }
	Scan     struct{ Collection, Initial, Fn Expr }
	Fold     struct{ Collection, Initial, Fn Expr }
	Concat   struct{ Left, Right Expr }
	Import   struct {
		Name   string
		Params []Param
	}
	// AdaptActions has a nil Fn when no function was given.
	AdaptActions struct {
		Target     Expr
		Adaptation ActionAdaptation
		Fn         Expr
	}
	// Constrain is constraint(name, args...) (v3-symbols.md section 2.1).
	Constrain struct {
		Name string
		Args []Expr
	}
	// Emit is !expr (section 2.2): a statement, nesting into the same chain
	// Let does.
	Emit struct{ Constraint, Body Expr }
	// Alloc is ?(key) (section 1.2). Site is assigned by numberAllocs after
	// parsing rather than by the parser, so agreement between implementations
	// rests on that one pure function.
	Alloc struct {
		Site int
		Key  Expr
	}
	// Demand is ?ctx.a.b (section 1.3): the path is always rooted at ctx,
	// which is not stored.
	Demand   struct{ Path []string }
	TypeDecl struct {
		Name string
		Type TypeExpr
		Body Expr
	}
	TypeAnnotate struct {
		Name        string
		Type        TypeExpr
		Value, Body Expr
	}
	TypeEmit struct {
		Name string
		Args []TypeConstraintArg
		Body Expr
	}
)

func (*Path) isExpr()         {}
func (*FieldAccess) isExpr()  {}
func (*Call) isExpr()         {}
func (*Lambda) isExpr()       {}
func (*Let) isExpr()          {}
func (*StringLit) isExpr()    {}
func (*NumberLit) isExpr()    {}
func (*BoolLit) isExpr()      {}
func (*NullLit) isExpr()      {}
func (*ArrayLit) isExpr()     {}
func (*ObjectLit) isExpr()    {}
func (*Element) isExpr()      {}
func (*Fragment) isExpr()     {}
func (*Branch) isExpr()       {}
func (*Map) isExpr()          {}
func (*Filter) isExpr()       {}
func (*Scan) isExpr()         {}
func (*Fold) isExpr()         {}
func (*Concat) isExpr()       {}
func (*Import) isExpr()       {}
func (*AdaptActions) isExpr() {}
func (*Constrain) isExpr()    {}
func (*Emit) isExpr()         {}
func (*Alloc) isExpr()        {}
func (*Demand) isExpr()       {}
func (*TypeDecl) isExpr()     {}
func (*TypeAnnotate) isExpr() {}
func (*TypeEmit) isExpr()     {}

// SubExprs returns the immediately-contained expressions of an expression, in
// source order.
func SubExprs(e Expr) []Expr {
	switch x := e.(type) {
	case *Path, *StringLit, *NumberLit, *BoolLit, *NullLit, *Demand:
		return nil
	case *FieldAccess:
		return []Expr{x.Target}
	case *Call:
		return append([]Expr{x.Fn}, x.Args...)
	case *Lambda:
		return []Expr{x.Body}
	case *Let:
		return []Expr{x.Value, x.Body}
	case *ArrayLit:
		return x.Elements
	case *ObjectLit:
		out := make([]Expr, len(x.Fields))
		for i, f := range x.Fields {
			out[i] = f.Value
		}
		return out
	case *Element:
		out := make([]Expr, 0, len(x.Attributes)+1+len(x.Children))
		for _, a := range x.Attributes {
			switch at := a.(type) {
			case *Attr:
				out = append(out, at.Value)
			case *ActionAttr:
				out = append(out, at.Payload)
			}
		}
		out = append(out, x.Value)
		return append(out, x.Children...)
	case *Fragment:
		return x.Children
	case *Branch:
		return []Expr{x.Condition, x.Then, x.Else}
	case *Map:
		return []Expr{x.Collection, x.Fn}
	case *Filter:
		return []Expr{x.Collection, x.Fn}
	case *Scan:
		return []Expr{x.Collection, x.Initial, x.Fn}
	case *Fold:
		return []Expr{x.Collection, x.Initial, x.Fn}
	case *Concat:
		return []Expr{x.Left, x.Right}
	case *Import:
		var out []Expr
		for _, p := range x.Params {
			if pe, ok := p.Value.(*PExpr); ok {
				out = append(out, pe.Expr)
			}
		}
		return out
	case *AdaptActions:
		if x.Fn == nil {
			return []Expr{x.Target}
		}
		return []Expr{x.Target, x.Fn}
	case *Constrain:
		return x.Args
	case *Emit:
		return []Expr{x.Constraint, x.Body}
	case *Alloc:
		return []Expr{x.Key}
	case *TypeDecl:
		return []Expr{x.Body}
	case *TypeAnnotate:
		return []Expr{x.Value, x.Body}
	case *TypeEmit:
		return []Expr{x.Body}
	}
	panic("tramaj: unknown expression")
}

// numberAllocs assigns each Alloc the index of its ?(...) among all of them,
// in source order (v3-symbols.md section 1.4): a plain pre-order,
// left-to-right walk over the freshly parsed tree.
func numberAllocs(e Expr) {
	counter := 0
	var walk func(x Expr)
	walk = func(x Expr) {
		if a, ok := x.(*Alloc); ok {
			a.Site = counter
			counter++
		}
		for _, sub := range SubExprs(x) {
			walk(sub)
		}
	}
	walk(e)
}

// Statements.

type StmtKind int

const (
	StmtLet StmtKind = iota
	StmtEmit
	StmtTypeDecl
	StmtAnnotate
	StmtTypeEmit
)

// Stmt is one statement of a program's leading chain. Value is the bound
// expression of a Let or Annotate and the constraint of an Emit; Type belongs
// to TypeDecl and Annotate; Args to TypeEmit.
type Stmt struct {
	Kind  StmtKind
	Name  string
	Type  TypeExpr
	Value Expr
	Args  []TypeConstraintArg
}

// isHiddenName reports a name the parser invents when lowering a binding
// pattern (decisions section 17): it starts with '#', which no surface name
// can. Such a binding is never reported as a symbol's "binding" and never
// exposed through a library's vals.
func isHiddenName(n string) bool {
	return strings.HasPrefix(n, "#")
}

// Unlets peels the outermost Let/Emit/TypeDecl/TypeAnnotate/TypeEmit chain
// back off, stopping at the first non-statement constructor.
func Unlets(e Expr) ([]Stmt, Expr) {
	var stmts []Stmt
	cur := e
	for {
		switch x := cur.(type) {
		case *Let:
			stmts = append(stmts, Stmt{Kind: StmtLet, Name: x.Name, Value: x.Value})
			cur = x.Body
		case *Emit:
			stmts = append(stmts, Stmt{Kind: StmtEmit, Value: x.Constraint})
			cur = x.Body
		case *TypeDecl:
			stmts = append(stmts, Stmt{Kind: StmtTypeDecl, Name: x.Name, Type: x.Type})
			cur = x.Body
		case *TypeAnnotate:
			stmts = append(stmts, Stmt{Kind: StmtAnnotate, Name: x.Name, Type: x.Type, Value: x.Value})
			cur = x.Body
		case *TypeEmit:
			stmts = append(stmts, Stmt{Kind: StmtTypeEmit, Name: x.Name, Args: x.Args})
			cur = x.Body
		default:
			return stmts, cur
		}
	}
}

func typeDecls(stmts []Stmt) []TypeField {
	var out []TypeField
	for _, s := range stmts {
		if s.Kind == StmtTypeDecl {
			out = append(out, TypeField{s.Name, s.Type})
		}
	}
	return out
}
