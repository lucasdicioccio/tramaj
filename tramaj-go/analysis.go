package tramaj

import (
	"slices"
	"sort"
)

// Static analysis over the AST alone (specs/reference.md section 9,
// specs/v3-symbols.md section 7, specs/v4-types.md section 9): no context, no
// library evaluation, no host code.
//
// Every set-valued answer is returned sorted, so two runs over the same
// program agree on order as well as membership.

// Libraries maps an import name to its parsed program.
type Libraries = map[string]*Program

func pathKey(p []string) string { return CompactJSON(stringsJSON(p)) }

func sortedPaths(xs [][]string) [][]string {
	seen := map[string][]string{}
	keys := []string{}
	for _, p := range xs {
		k := pathKey(p)
		if _, ok := seen[k]; !ok {
			keys = append(keys, k)
		}
		seen[k] = p
	}
	sort.Slice(keys, func(i, j int) bool { return lessUTF16(keys[i], keys[j]) })
	out := make([][]string, len(keys))
	for i, k := range keys {
		out[i] = seen[k]
	}
	return out
}

// everywhere collects from an expression and every expression inside it.
func everywhere[T any](f func(Expr) []T, e Expr) []T {
	out := f(e)
	for _, sub := range SubExprs(e) {
		out = append(out, everywhere(f, sub)...)
	}
	return out
}

// Imports.

// StaticImportNames lists every library this program imports directly.
func StaticImportNames(prog *Program) []string {
	return sortedStrings(everywhere(func(e Expr) []string {
		if imp, ok := e.(*Import); ok {
			return []string{imp.Name}
		}
		return nil
	}, prog.Root))
}

// TransitiveImportNames lists every library reachable from this program,
// directly or through another import. A missing name is still reported; a
// cycle terminates.
func TransitiveImportNames(libs Libraries, prog *Program) []string {
	seen := map[string]bool{}
	var names []string
	frontier := StaticImportNames(prog)
	for len(frontier) > 0 {
		name := frontier[len(frontier)-1]
		frontier = frontier[:len(frontier)-1]
		if seen[name] {
			continue
		}
		seen[name] = true
		names = append(names, name)
		if p := libs[name]; p != nil {
			frontier = append(frontier, StaticImportNames(p)...)
		}
	}
	return sortedStrings(names)
}

// eachLibrary visits every library reachable from prog that the table has.
func eachLibrary(libs Libraries, prog *Program, f func(*Program)) {
	for _, name := range TransitiveImportNames(libs, prog) {
		if p := libs[name]; p != nil {
			f(p)
		}
	}
}

// Arithmetic.

// ArithmeticNames are the names of the arithmetic profile (specs/reference.md
// section 11), in the order the reference lists them: the nine of decisions
// section 18, then round (section 20). They are builtins only in an
// evaluation whose Options turn the profile on.
var ArithmeticNames = []string{
	"sum", "product", "negate", "quotient", "inverse", "floor-quotient", "modulo", "floor", "real", "round",
}

// ArithmeticOps lists which of ArithmeticNames this program references free
// (specs/reference.md section 9), called (sum(1, 2)) or passed by reference
// (fold($xs, 0, $sum)) alike, since both are a Path rooted at the name.
//
// Scope-aware: a name bound by a binding, a lambda parameter or a pattern
// name is not reported where that binding is in scope. A pattern is lowered
// to plain bindings by the parser, so it needs no case here. A binding's own
// right-hand side is outside its scope, so `@sum = sum(1, 2)` reports sum.
//
// Over-approximates like every analysis here: a name used only under a branch
// arm no context will select is still reported.
func ArithmeticOps(prog *Program) []string {
	return sortedStrings(arithmeticOps(nil, prog.Root))
}

func arithmeticOps(bound map[string]bool, e Expr) []string {
	with := func(names ...string) map[string]bool {
		out := make(map[string]bool, len(bound)+len(names))
		for k := range bound {
			out[k] = true
		}
		for _, n := range names {
			out[n] = true
		}
		return out
	}
	switch x := e.(type) {
	case *Path:
		if slices.Contains(ArithmeticNames, x.Root) && !bound[x.Root] {
			return []string{x.Root}
		}
		return nil
	case *Let:
		return append(arithmeticOps(bound, x.Value), arithmeticOps(with(x.Name), x.Body)...)
	case *TypeAnnotate:
		return append(arithmeticOps(bound, x.Value), arithmeticOps(with(x.Name), x.Body)...)
	case *Lambda:
		return arithmeticOps(with(x.Params...), x.Body)
	}
	var out []string
	for _, sub := range SubExprs(e) {
		out = append(out, arithmeticOps(bound, sub)...)
	}
	return out
}

// DeepArithmeticOps is ArithmeticOps of this program and of every library it
// imports, directly or not. A library has its own scope, so a binding in the
// importing program shadows nothing there. This is what a host that leaves
// the arithmetic profile off checks before running a program: non-empty means
// the program would fail with UnboundName, and with the profile on it names
// the operations a term can carry (v3-symbols.md section 7).
func DeepArithmeticOps(libs Libraries, prog *Program) []string {
	out := arithmeticOps(nil, prog.Root)
	eachLibrary(libs, prog, func(p *Program) { out = append(out, arithmeticOps(nil, p.Root)...) })
	return sortedStrings(out)
}

// Actions.

func ownActionKeys(e Expr) []string {
	el, ok := e.(*Element)
	if !ok {
		return nil
	}
	var out []string
	for _, a := range el.Attributes {
		if act, ok := a.(*ActionAttr); ok {
			out = append(out, act.Key)
		}
	}
	return out
}

// followImports folds own over an expression tree, following each import into
// its library once and applying action adaptations to what is found beneath
// them. With libs nil, imports are not followed.
func followImports(libs Libraries, adapt bool, own func(Expr) []string, root Expr) []string {
	seen := map[string]bool{}
	var walk func(e Expr) []string
	walk = func(e Expr) []string {
		if ad, ok := e.(*AdaptActions); ok && adapt {
			out := walk(ad.Target)
			for i, k := range out {
				out[i] = adaptKey(ad.Adaptation, k)
			}
			if ad.Fn != nil {
				out = append(out, walk(ad.Fn)...)
			}
			return out
		}
		out := own(e)
		for _, sub := range SubExprs(e) {
			out = append(out, walk(sub)...)
		}
		if imp, ok := e.(*Import); ok && libs != nil && !seen[imp.Name] {
			seen[imp.Name] = true
			if lib := libs[imp.Name]; lib != nil {
				out = append(out, walk(lib.Root)...)
			}
		}
		return out
	}
	return sortedStrings(walk(root))
}

// StaticActionKeys lists every action key this program can emit from its own
// AST; adaptation is applied, not ignored.
func StaticActionKeys(prog *Program) []string {
	return followImports(nil, true, ownActionKeys, prog.Root)
}

// DeepActionKeys lists every action key this program can emit, following
// imports. An over-approximation.
func DeepActionKeys(libs Libraries, prog *Program) []string {
	if libs == nil {
		libs = Libraries{}
	}
	return followImports(libs, true, ownActionKeys, prog.Root)
}

// Context holes.

func ownContextHoles(e Expr) [][]string {
	imp, ok := e.(*Import)
	if !ok {
		return nil
	}
	var out [][]string
	for _, p := range imp.Params {
		if fc, ok := p.Value.(*PFromContext); ok {
			out = append(out, fc.Path)
		}
	}
	return out
}

// ContextHoles lists every path this program declares as a hole with
// ctx(path).
func ContextHoles(prog *Program) [][]string {
	return sortedPaths(everywhere(ownContextHoles, prog.Root))
}

func DeepContextHoles(libs Libraries, prog *Program) [][]string {
	out := ContextHoles(prog)
	eachLibrary(libs, prog, func(p *Program) { out = append(out, ContextHoles(p)...) })
	return sortedPaths(out)
}

// ContextReads lists every path this program reads out of its own context,
// however written.
func ContextReads(prog *Program) [][]string {
	return sortedPaths(everywhere(func(e Expr) [][]string {
		if path, ok := e.(*Path); ok && path.Root == "ctx" {
			return [][]string{path.Fields}
		}
		return ownContextHoles(e)
	}, prog.Root))
}

// Unsupplied names an import and the paths its library wants that the import
// does not supply.
type Unsupplied struct {
	Name  string
	Paths [][]string
}

// unsuppliedBy reports, for each import in source order, the wanted paths
// whose first segment the import does not supply.
func unsuppliedBy(libs Libraries, prog *Program, wanted func(*Program) [][]string, supplies func(Param) bool) []Unsupplied {
	return everywhere(func(e Expr) []Unsupplied {
		imp, ok := e.(*Import)
		if !ok {
			return nil
		}
		supplied := map[string]bool{}
		for _, p := range imp.Params {
			if supplies(p) {
				supplied[p.Name] = true
			}
		}
		paths := [][]string{}
		if lib := libs[imp.Name]; lib != nil {
			for _, path := range wanted(lib) {
				if len(path) > 0 && !supplied[path[0]] {
					paths = append(paths, path)
				}
			}
		}
		return []Unsupplied{{Name: imp.Name, Paths: paths}}
	}, prog.Root)
}

// UnsuppliedParams reports, for each import in this program, the paths its
// library reads from its context that the import does not supply. Attributed
// by the read's first segment.
func UnsuppliedParams(libs Libraries, prog *Program) []Unsupplied {
	return unsuppliedBy(libs, prog, ContextReads, func(Param) bool { return true })
}

// Constraints.

func ownConstraintKinds(e Expr) []string {
	if c, ok := e.(*Constrain); ok {
		return []string{c.Name}
	}
	return nil
}

func ConstraintKinds(prog *Program) []string {
	return sortedStrings(everywhere(ownConstraintKinds, prog.Root))
}

func DeepConstraintKinds(libs Libraries, prog *Program) []string {
	if libs == nil {
		libs = Libraries{}
	}
	return followImports(libs, false, ownConstraintKinds, prog.Root)
}

// Symbols.

// SymbolSites lists the ?(k) allocation sites this program contains: sites,
// not keys.
func SymbolSites(prog *Program) []int {
	sites := everywhere(func(e Expr) []int {
		if a, ok := e.(*Alloc); ok {
			return []int{a.Site}
		}
		return nil
	}, prog.Root)
	sort.Ints(sites)
	out := sites[:0]
	for i, s := range sites {
		if i == 0 || s != sites[i-1] {
			out = append(out, s)
		}
	}
	return out
}

func SymbolDemands(prog *Program) [][]string {
	return sortedPaths(everywhere(func(e Expr) [][]string {
		if d, ok := e.(*Demand); ok {
			return [][]string{d.Path}
		}
		return nil
	}, prog.Root))
}

func DeepSymbolDemands(libs Libraries, prog *Program) [][]string {
	out := SymbolDemands(prog)
	eachLibrary(libs, prog, func(p *Program) { out = append(out, SymbolDemands(p)...) })
	return sortedPaths(out)
}

// Types.

func TypeDeclarations(prog *Program) []string {
	stmts, _ := Unlets(prog.Root)
	var names []string
	for _, d := range typeDecls(stmts) {
		names = append(names, d.Name)
	}
	return sortedStrings(names)
}

func typeParamsIn(t TypeExpr) [][]string {
	var out [][]string
	switch x := t.(type) {
	case *TArray:
		return typeParamsIn(x.Element)
	case *TRecord:
		for _, f := range x.Fields {
			out = append(out, typeParamsIn(f.Type)...)
		}
	case *TUnion:
		for _, a := range x.Arms {
			if a.Payload != nil {
				out = append(out, typeParamsIn(a.Payload)...)
			}
		}
	case *TVar:
		return [][]string{x.Path}
	}
	return out
}

// typeExprsIn lists every TypeExpr sitting in one expression's own syntax,
// not recursing into subexpressions.
func typeExprsIn(e Expr) []TypeExpr {
	var out []TypeExpr
	switch x := e.(type) {
	case *TypeDecl:
		return []TypeExpr{x.Type}
	case *TypeAnnotate:
		return []TypeExpr{x.Type}
	case *TypeEmit:
		for _, a := range x.Args {
			if a.Type != nil {
				out = append(out, a.Type)
			}
		}
	case *Import:
		for _, p := range x.Params {
			if pt, ok := p.Value.(*PType); ok {
				out = append(out, pt.Type)
			}
		}
	}
	return out
}

// TypeParams lists every %ctx.path type hole this program's types mention.
func TypeParams(prog *Program) [][]string {
	return sortedPaths(everywhere(func(e Expr) [][]string {
		var out [][]string
		for _, t := range typeExprsIn(e) {
			out = append(out, typeParamsIn(t)...)
		}
		return out
	}, prog.Root))
}

func UnsuppliedTypeParams(libs Libraries, prog *Program) []Unsupplied {
	return unsuppliedBy(libs, prog, TypeParams, func(p Param) bool {
		_, ok := p.Value.(*PType)
		return ok
	})
}

// TypeParamCollisions lists the names used both as a value read and as a type
// hole.
func TypeParamCollisions(prog *Program) []string {
	reads := map[string]bool{}
	for _, p := range ContextReads(prog) {
		if len(p) > 0 {
			reads[p[0]] = true
		}
	}
	var out []string
	for _, p := range TypeParams(prog) {
		if len(p) > 0 && reads[p[0]] {
			out = append(out, p[0])
		}
	}
	return sortedStrings(out)
}

// Card.

// Card is a one-glance summary of a program's static interface.
type Card struct {
	Produces   string // "document" or "value"
	Requires   [][]string
	Imports    []string
	Emits      []string
	Unsupplied []Unsupplied
}

func ProgramCard(libs Libraries, prog *Program) Card {
	produces := "value"
	if prog.Kind == DocumentProgram {
		produces = "document"
	}
	return Card{
		Produces:   produces,
		Requires:   ContextReads(prog),
		Imports:    TransitiveImportNames(libs, prog),
		Emits:      DeepActionKeys(libs, prog),
		Unsupplied: UnsuppliedParams(libs, prog),
	}
}
