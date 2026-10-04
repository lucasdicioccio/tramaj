package tramaj

import (
	"sort"
	"strings"
)

// v4-types resolution, normalisation, canonical identity, and the closure and
// constraint machinery output needs (specs/v4-types.md). A static pass over
// parsed programs, evaluating nothing. Mirrors tramaj-py/tramaj/typesys.py.
//
// Inside this file a failure is a panic carrying a *TypeError; the exported
// entry points turn it back into an error.

// ResolvedType is a type expression with its names resolved: RPrim, RArray,
// RRecord, RUnion, RRef or RVar.
type ResolvedType interface{ isResolvedType() }

type (
	RPrim   struct{ Name string }
	RArray  struct{ Element ResolvedType }
	RRecord struct{ Fields []RField }
	RUnion  struct{ Arms []RField }
	// RRef names a declaration: in the root program when Lib is nil, else in
	// that library, instantiated with Args.
	RRef struct {
		Lib  *string
		Name string
		Args []RField
	}
	RVar struct{ Path []string }
)

// RField is a named type: a record field, a union arm (Type is nil for a
// nullary arm) or a reference's type argument.
type RField struct {
	Name string
	Type ResolvedType
}

func (RPrim) isResolvedType()   {}
func (RArray) isResolvedType()  {}
func (RRecord) isResolvedType() {}
func (RUnion) isResolvedType()  {}
func (RRef) isResolvedType()    {}
func (RVar) isResolvedType()    {}

// TypeError is one of v4-types.md section 10's analysis errors. Error() leads
// with the bare kind.
type TypeError struct {
	Kind   string
	Detail string
}

func (e *TypeError) Error() string {
	if e.Detail == "" {
		return e.Kind
	}
	return e.Kind + " " + e.Detail
}

func typeFail(kind, detail string) {
	panic(&TypeError{Kind: kind, Detail: detail})
}

// catchTypeError turns a *TypeError panic into the returned error.
func catchTypeError(err *error) {
	if r := recover(); r != nil {
		te, ok := r.(*TypeError)
		if !ok {
			panic(r)
		}
		*err = te
	}
}

// programTypeDecls gives just the type declarations at the top of a program's
// own statement chain.
func programTypeDecls(prog *Program) map[string]TypeExpr {
	stmts, _ := Unlets(prog.Root)
	out := map[string]TypeExpr{}
	for _, d := range typeDecls(stmts) {
		out[d.Name] = d.Type
	}
	return out
}

func sortFields(fields []RField) {
	sort.SliceStable(fields, func(i, j int) bool { return lessUTF16(fields[i].Name, fields[j].Name) })
}

func resolveTypeExpr(libs Libraries, prog *Program, t TypeExpr) ResolvedType {
	return resolveWith(libs, prog, nil, nil, t)
}

func resolveWith(libs Libraries, prog *Program, subst map[string]ResolvedType, visiting map[string]bool, t TypeExpr) ResolvedType {
	rec := func(x TypeExpr) ResolvedType { return resolveWith(libs, prog, subst, visiting, x) }
	switch x := t.(type) {
	case *TPrim:
		return RPrim{Name: x.Name}
	case *TArray:
		return RArray{Element: rec(x.Element)}
	case *TRecord:
		fields := make([]RField, len(x.Fields))
		for i, f := range x.Fields {
			fields[i] = RField{Name: f.Name, Type: rec(f.Type)}
		}
		sortFields(fields)
		return RRecord{Fields: fields}
	case *TUnion:
		arms := make([]RField, len(x.Arms))
		for i, a := range x.Arms {
			arms[i] = RField{Name: a.Name}
			if a.Payload != nil {
				arms[i].Type = rec(a.Payload)
			}
		}
		sortFields(arms)
		return RUnion{Arms: arms}
	case *TVar:
		// Only a single-segment path is ever substituted.
		if len(x.Path) == 1 {
			if s, ok := subst[x.Path[0]]; ok {
				return s
			}
		}
		return RVar{Path: x.Path}
	case *TName:
		if _, ok := programTypeDecls(prog)[x.Name]; ok {
			return RRef{Name: x.Name}
		}
		typeFail("UnresolvedType", x.Name)
	case *TLibRef:
		key, libProg, params := resolveLibBinding(libs, prog, x.Lib)
		if _, ok := programTypeDecls(libProg)[x.Name]; !ok {
			typeFail("UnresolvedType", x.Name)
		}
		if visiting[key] {
			typeFail("TypeCycle", key)
		}
		visiting2 := map[string]bool{key: true}
		for k := range visiting {
			visiting2[k] = true
		}
		var wanted []string
		for _, p := range TypeParams(libProg) {
			if len(p) > 0 {
				wanted = append(wanted, p[0])
			} else {
				wanted = append(wanted, "")
			}
		}
		supplied := map[string]TypeExpr{}
		for _, p := range params {
			if pt, ok := p.Value.(*PType); ok {
				supplied[p.Name] = pt.Type
			}
		}
		var args []RField
		for _, k := range sortedStrings(wanted) {
			arg := RField{Name: k, Type: RVar{Path: []string{k}}}
			if te, ok := supplied[k]; ok {
				arg.Type = resolveWith(libs, prog, subst, visiting2, te)
			}
			args = append(args, arg)
		}
		return RRef{Lib: &key, Name: x.Name, Args: args}
	}
	panic("tramaj: unknown type expression")
}

// resolveLibBinding finds the last `@lib = import("name", {...})` among the
// program's own statements.
func resolveLibBinding(libs Libraries, prog *Program, lib string) (string, *Program, []Param) {
	stmts, _ := Unlets(prog.Root)
	var found *Import
	for _, s := range stmts {
		if imp, ok := s.Value.(*Import); ok && s.Kind == StmtLet && s.Name == lib {
			found = imp
		}
	}
	if found == nil || libs[found.Name] == nil {
		typeFail("NotStaticallyResolvable", lib)
	}
	return found.Name, libs[found.Name], found.Params
}

// CanonicalID renders v4-types.md section 3's grammar. It renders the order
// it is given; it does not sort.
func CanonicalID(rt ResolvedType) string {
	var b strings.Builder
	writeCanonicalID(&b, rt)
	return b.String()
}

func writeCanonicalID(b *strings.Builder, rt ResolvedType) {
	switch x := rt.(type) {
	case RPrim:
		b.WriteString(x.Name)
	case RArray:
		b.WriteByte('[')
		writeCanonicalID(b, x.Element)
		b.WriteByte(']')
	case RRecord:
		b.WriteByte('{')
		for i, f := range x.Fields {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(f.Name + ":")
			writeCanonicalID(b, f.Type)
		}
		b.WriteByte('}')
	case RUnion:
		for _, a := range x.Arms {
			b.WriteString("|" + a.Name)
			if a.Type != nil {
				b.WriteByte(' ')
				writeCanonicalID(b, a.Type)
			}
		}
	case RRef:
		if x.Lib == nil {
			b.WriteString("root")
		} else {
			b.WriteString(`"` + *x.Lib + `"`)
		}
		b.WriteString(":" + x.Name)
		if len(x.Args) > 0 {
			b.WriteByte('[')
			for i, a := range x.Args {
				if i > 0 {
					b.WriteByte(',')
				}
				b.WriteString(a.Name + "=")
				writeCanonicalID(b, a.Type)
			}
			b.WriteByte(']')
		}
	case RVar:
		b.WriteString("%ctx")
		for _, p := range x.Path {
			b.WriteString("." + p)
		}
	}
}

// children lists the types directly inside a resolved type, in order.
func resolvedChildren(rt ResolvedType) []ResolvedType {
	var fields []RField
	switch x := rt.(type) {
	case RArray:
		return []ResolvedType{x.Element}
	case RRecord:
		fields = x.Fields
	case RUnion:
		fields = x.Arms
	case RRef:
		fields = x.Args
	}
	var out []ResolvedType
	for _, f := range fields {
		if f.Type != nil {
			out = append(out, f.Type)
		}
	}
	return out
}

// firstVarPath finds the first %ctx hole in a type, in rendering order.
func firstVarPath(rt ResolvedType) ([]string, bool) {
	if v, ok := rt.(RVar); ok {
		return v.Path, true
	}
	for _, c := range resolvedChildren(rt) {
		if p, ok := firstVarPath(c); ok {
			return p, true
		}
	}
	return nil, false
}

// requireClosed enforces v4-types.md section 4: a type reaching the root must
// be closed.
func requireClosed(rt ResolvedType) ResolvedType {
	if path, open := firstVarPath(rt); open {
		typeFail("PartialType", CanonicalID(rt)+" "+pathKey(path))
	}
	return rt
}

// CheckTypeParamCollisions fails with TypeParamCollision when a name is used
// both as a value read and as a type hole.
func CheckTypeParamCollisions(prog *Program) error {
	if xs := TypeParamCollisions(prog); len(xs) > 0 {
		return &TypeError{Kind: "TypeParamCollision", Detail: xs[0]}
	}
	return nil
}

// Output: the transitive closure of referenced types (v4-types section 8).

func collectRefs(rt ResolvedType) []RRef {
	var out []RRef
	if r, ok := rt.(RRef); ok {
		out = append(out, r)
	}
	for _, c := range resolvedChildren(rt) {
		out = append(out, collectRefs(c)...)
	}
	return out
}

func lookupDecl(libs Libraries, prog *Program, ref RRef) (*Program, TypeExpr) {
	declProg := prog
	if ref.Lib != nil {
		if declProg = libs[*ref.Lib]; declProg == nil {
			typeFail("NotStaticallyResolvable", *ref.Lib)
		}
	}
	body, ok := programTypeDecls(declProg)[ref.Name]
	if !ok {
		typeFail("UnresolvedType", ref.Name)
	}
	return declProg, body
}

// typeClosure computes the transitive closure of every type referenced from
// roots, cut by canonical id so a cycle terminates.
func typeClosure(libs Libraries, prog *Program, roots []ResolvedType) map[string]ResolvedType {
	acc := map[string]ResolvedType{}
	var queue []RRef
	for _, r := range roots {
		queue = append(queue, collectRefs(r)...)
	}
	for len(queue) > 0 {
		r := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		cid := CanonicalID(r)
		if _, done := acc[cid]; done {
			continue
		}
		declProg, body := lookupDecl(libs, prog, r)
		subst := map[string]ResolvedType{}
		for _, a := range r.Args {
			subst[a.Name] = a.Type
		}
		definition := resolveWith(libs, declProg, subst, nil, body)
		queue = append(queue, collectRefs(definition)...)
		acc[cid] = definition
	}
	return acc
}

// Erasure (v4-types section 7).

// eraseTypes rewrites every TypeAnnotate into the Let plus Emit section 7
// specifies, resolving and closing its type first. A TypeDecl is left in
// place; a TypeEmit is dropped.
func eraseTypes(libs Libraries, prog *Program) *Program {
	var erase func(e Expr) Expr
	eraseAll := func(xs []Expr) []Expr {
		if xs == nil {
			return nil
		}
		out := make([]Expr, len(xs))
		for i, x := range xs {
			out[i] = erase(x)
		}
		return out
	}
	erase = func(e Expr) Expr {
		switch x := e.(type) {
		case *Path, *StringLit, *NumberLit, *BoolLit, *NullLit, *Demand:
			return e
		case *FieldAccess:
			return &FieldAccess{Target: erase(x.Target), Fields: x.Fields}
		case *Call:
			return &Call{Fn: erase(x.Fn), Args: eraseAll(x.Args)}
		case *Lambda:
			return &Lambda{Params: x.Params, Body: erase(x.Body)}
		case *Let:
			return &Let{Name: x.Name, Value: erase(x.Value), Body: erase(x.Body)}
		case *ArrayLit:
			return &ArrayLit{Elements: eraseAll(x.Elements)}
		case *ObjectLit:
			fields := make([]Field, len(x.Fields))
			for i, f := range x.Fields {
				fields[i] = Field{Name: f.Name, Value: erase(f.Value)}
			}
			return &ObjectLit{Fields: fields}
		case *Element:
			attrs := make([]Attribute, len(x.Attributes))
			for i, a := range x.Attributes {
				switch at := a.(type) {
				case *Attr:
					attrs[i] = &Attr{Name: at.Name, Value: erase(at.Value)}
				case *ActionAttr:
					attrs[i] = &ActionAttr{Event: at.Event, Key: at.Key, Payload: erase(at.Payload)}
				}
			}
			return &Element{Tag: x.Tag, Attributes: attrs, Value: erase(x.Value), Children: eraseAll(x.Children)}
		case *Fragment:
			return &Fragment{Children: eraseAll(x.Children)}
		case *Branch:
			return &Branch{Condition: erase(x.Condition), Then: erase(x.Then), Else: erase(x.Else)}
		case *Map:
			return &Map{Collection: erase(x.Collection), Fn: erase(x.Fn)}
		case *Filter:
			return &Filter{Collection: erase(x.Collection), Fn: erase(x.Fn)}
		case *Scan:
			return &Scan{Collection: erase(x.Collection), Initial: erase(x.Initial), Fn: erase(x.Fn)}
		case *Fold:
			return &Fold{Collection: erase(x.Collection), Initial: erase(x.Initial), Fn: erase(x.Fn)}
		case *Concat:
			return &Concat{Left: erase(x.Left), Right: erase(x.Right)}
		case *Import:
			params := make([]Param, len(x.Params))
			for i, p := range x.Params {
				params[i] = p
				if pe, ok := p.Value.(*PExpr); ok {
					params[i].Value = &PExpr{Expr: erase(pe.Expr)}
				}
			}
			return &Import{Name: x.Name, Params: params}
		case *AdaptActions:
			out := &AdaptActions{Target: erase(x.Target), Adaptation: x.Adaptation}
			if x.Fn != nil {
				out.Fn = erase(x.Fn)
			}
			return out
		case *Constrain:
			return &Constrain{Name: x.Name, Args: eraseAll(x.Args)}
		case *Emit:
			return &Emit{Constraint: erase(x.Constraint), Body: erase(x.Body)}
		case *Alloc:
			return &Alloc{Site: x.Site, Key: erase(x.Key)}
		case *TypeDecl:
			return &TypeDecl{Name: x.Name, Type: x.Type, Body: erase(x.Body)}
		case *TypeAnnotate:
			rt := requireClosed(resolveTypeExpr(libs, prog, x.Type))
			hasType := &Constrain{Name: "has-type", Args: []Expr{
				&Path{Root: x.Name},
				&ObjectLit{Fields: []Field{{Name: "$type", Value: &StringLit{Value: CanonicalID(rt)}}}},
			}}
			return &Let{Name: x.Name, Value: erase(x.Value), Body: &Emit{Constraint: hasType, Body: erase(x.Body)}}
		case *TypeEmit:
			return erase(x.Body)
		}
		panic("tramaj: unknown expression")
	}
	return &Program{Kind: prog.Kind, Root: erase(prog.Root)}
}

// Type constraints (v4-types section 5).

// TypeConstraint is a resolved !type-constraint. Each argument is in its wire
// form: a scalar, or {"$type": <canonical id>} for a type.
type TypeConstraint struct {
	Name      string
	Arguments []JSON
}

func (tc TypeConstraint) toJSON() JSON {
	return NewObject("name", tc.Name, "arguments", tc.Arguments)
}

func typeConstraintsOf(libs Libraries, prog *Program) []TypeConstraint {
	return everywhere(func(e Expr) []TypeConstraint {
		te, ok := e.(*TypeEmit)
		if !ok {
			return nil
		}
		args := make([]JSON, len(te.Args))
		for i, a := range te.Args {
			args[i] = a.Scalar
			if a.Type != nil {
				args[i] = NewObject("$type", CanonicalID(resolveTypeExpr(libs, prog, a.Type)))
			}
		}
		return []TypeConstraint{{Name: te.Name, Arguments: args}}
	}, prog.Root)
}

// dedupeConstraints keeps the first of each run of equal constraints. Two
// resolved types are equal exactly when their canonical ids are, so comparing
// wire forms is comparing constraints.
func dedupeConstraints(xs []TypeConstraint) []TypeConstraint {
	out := []TypeConstraint{}
	for _, x := range xs {
		seen := false
		for _, y := range out {
			if x.Name == y.Name && JSONEqual(x.Arguments, y.Arguments) {
				seen = true
				break
			}
		}
		if !seen {
			out = append(out, x)
		}
	}
	return out
}

func deepTypeConstraints(libs Libraries, prog *Program) []TypeConstraint {
	out := typeConstraintsOf(libs, prog)
	eachLibrary(libs, prog, func(p *Program) { out = append(out, typeConstraintsOf(libs, p)...) })
	return dedupeConstraints(out)
}

// TypeConstraints lists every !type-constraint this program's own chain
// collects.
func TypeConstraints(libs Libraries, prog *Program) (out []TypeConstraint, err error) {
	defer catchTypeError(&err)
	return dedupeConstraints(typeConstraintsOf(libs, prog)), nil
}

// DeepTypeConstraints is TypeConstraints, following imports.
func DeepTypeConstraints(libs Libraries, prog *Program) (out []TypeConstraint, err error) {
	defer catchTypeError(&err)
	return deepTypeConstraints(libs, prog), nil
}

// Type references (v4-types section 9).

// programTypeRoots resolves every TypeExpr in a type-bearing position of
// prog's own syntax.
func programTypeRoots(libs Libraries, prog *Program) []ResolvedType {
	var out []ResolvedType
	for _, t := range everywhere(typeExprsIn, prog.Root) {
		out = append(out, resolveTypeExpr(libs, prog, t))
	}
	return out
}

func typeReferences(libs Libraries, prog *Program) []string {
	var ids []string
	for _, rt := range programTypeRoots(libs, prog) {
		ids = append(ids, CanonicalID(rt))
	}
	return ids
}

// TypeReferences lists the canonical ids of the types this program mentions.
func TypeReferences(libs Libraries, prog *Program) (out []string, err error) {
	defer catchTypeError(&err)
	return sortedStrings(typeReferences(libs, prog)), nil
}

// DeepTypeReferences is TypeReferences, following imports.
func DeepTypeReferences(libs Libraries, prog *Program) (out []string, err error) {
	defer catchTypeError(&err)
	ids := typeReferences(libs, prog)
	eachLibrary(libs, prog, func(p *Program) { ids = append(ids, typeReferences(libs, p)...) })
	return sortedStrings(ids), nil
}

// ResolveTypeExpr resolves a type expression written in prog.
func ResolveTypeExpr(libs Libraries, prog *Program, t TypeExpr) (rt ResolvedType, err error) {
	defer catchTypeError(&err)
	return resolveTypeExpr(libs, prog, t), nil
}
