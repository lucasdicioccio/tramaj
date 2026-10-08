// Command tramaj-go evaluates and analyzes Tramaj templates, mirroring
// tramaj-cli-rs and `python -m tramaj`:
//
//	tramaj-go [evaluate] [--lib name=path ...] [--mode concrete|symbolic] [--arithmetic] <template-file> <context-json-file>
//	tramaj-go analyze <imports|actions|holes|unsupplied|constraints|symbols|types|arithmetic|card|all> <template-file> [--lib name=path ...]
//
// Evaluation prints the result JSON (the node-json document, the plain value,
// or the symbolic envelope) on stdout. A parse error exits 2, an evaluation
// error 1, each with the error on stderr, leading with its kind.
//
// --arithmetic turns the arithmetic profile on for the run (reference.md
// section 11). It is off by default, since the profile is a host's choice.
package main

import (
	"fmt"
	"os"
	"strings"

	tramaj "github.com/lucasdicioccio/tramaj/tramaj-go"
)

const usage = `usage: tramaj-go [evaluate] [--lib name=path ...] [--mode concrete|symbolic] [--arithmetic] <template-file> <context-json-file>
       tramaj-go analyze <imports|actions|holes|unsupplied|constraints|symbols|types|arithmetic|card|all> <template-file> [--lib name=path ...]`

// exit is how a helper below ends the program: main recovers it.
type exit struct {
	code int
	msg  string
}

func die(code int, format string, args ...any) {
	panic(exit{code, fmt.Sprintf(format, args...)})
}

func main() {
	defer func() {
		if r := recover(); r != nil {
			e, ok := r.(exit)
			if !ok {
				panic(r)
			}
			if e.code == 0 {
				fmt.Println(e.msg)
			} else {
				fmt.Fprintln(os.Stderr, e.msg)
			}
			os.Exit(e.code)
		}
	}()
	fmt.Println(tramaj.PrettyJSON(run(os.Args[1:])))
}

type options struct {
	libs       [][2]string // name, path
	mode       tramaj.Mode
	arithmetic bool
	positional []string
}

func splitArgs(argv []string) options {
	opts := options{mode: tramaj.Concrete}
	addLib := func(spec string) {
		name, path, ok := strings.Cut(spec, "=")
		if !ok {
			die(2, "--lib expects name=path\n%s", usage)
		}
		opts.libs = append(opts.libs, [2]string{name, path})
	}
	for i := 0; i < len(argv); i++ {
		a := argv[i]
		switch {
		case a == "--lib" || a == "--mode":
			i++
			if i >= len(argv) {
				die(2, "%s expects a value\n%s", a, usage)
			}
			if a == "--lib" {
				addLib(argv[i])
			} else {
				opts.mode = tramaj.Mode(argv[i])
			}
		case strings.HasPrefix(a, "--lib="):
			addLib(strings.TrimPrefix(a, "--lib="))
		case strings.HasPrefix(a, "--mode="):
			opts.mode = tramaj.Mode(strings.TrimPrefix(a, "--mode="))
		case a == "--arithmetic":
			opts.arithmetic = true
		case a == "-h" || a == "--help":
			die(0, "%s", usage)
		default:
			opts.positional = append(opts.positional, a)
		}
	}
	if opts.mode != tramaj.Concrete && opts.mode != tramaj.Symbolic {
		die(2, "unknown mode %q: expected concrete or symbolic\n%s", opts.mode, usage)
	}
	return opts
}

func read(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		die(2, "%v", err)
	}
	return data
}

func parse(what, path string) *tramaj.Program {
	prog, err := tramaj.ParseProgram(string(read(path)))
	if err != nil {
		die(2, "%sparse error: %v", what, err)
	}
	return prog
}

func loadLibs(pairs [][2]string) tramaj.Libraries {
	libs := tramaj.Libraries{}
	for _, p := range pairs {
		libs[p[0]] = parse(fmt.Sprintf("library %q (%s): ", p[0], p[1]), p[1])
	}
	return libs
}

func run(argv []string) tramaj.JSON {
	if len(argv) > 0 && argv[0] == "analyze" {
		opts := splitArgs(argv[1:])
		if len(opts.positional) != 2 {
			die(2, "%s", usage)
		}
		analysis, ok := analyses[opts.positional[0]]
		if !ok && opts.positional[0] != "all" {
			die(2, "%s", usage)
		}
		libs := loadLibs(opts.libs)
		prog := parse("", opts.positional[1])
		if ok {
			return analysis(libs, prog)
		}
		all := tramaj.NewObject()
		for _, name := range analysisOrder {
			if name != "card" {
				all.Set(name, analyses[name](libs, prog))
			}
		}
		return all
	}

	if len(argv) > 0 && argv[0] == "evaluate" {
		argv = argv[1:]
	}
	opts := splitArgs(argv)
	if len(opts.positional) != 2 {
		die(2, "%s", usage)
	}
	libs := loadLibs(opts.libs)
	prog := parse("", opts.positional[0])
	ctx, err := tramaj.ParseJSON(read(opts.positional[1]))
	if err != nil {
		die(2, "context %s: %v", opts.positional[1], err)
	}
	out, err := tramaj.RunProgramWith(tramaj.Options{Mode: opts.mode, Arithmetic: opts.arithmetic}, libs, ctx, prog)
	if err != nil {
		// Without the profile an arithmetic name is unbound like any other,
		// so say which ones the program references and how to turn them on.
		if ops := tramaj.DeepArithmeticOps(libs, prog); !opts.arithmetic && len(ops) > 0 {
			die(1, "eval error: %v\nthe program references the arithmetic builtins %s: pass --arithmetic to turn the arithmetic profile on", err, strings.Join(ops, ", "))
		}
		die(1, "eval error: %v", err)
	}
	return out
}

// Analyses, rendered as JSON.

var analysisOrder = []string{"imports", "actions", "holes", "unsupplied", "constraints", "symbols", "types", "arithmetic", "card"}

var analyses = map[string]func(tramaj.Libraries, *tramaj.Program) tramaj.JSON{
	"imports": func(libs tramaj.Libraries, prog *tramaj.Program) tramaj.JSON {
		return stringsJSON(tramaj.TransitiveImportNames(libs, prog))
	},
	"actions": func(libs tramaj.Libraries, prog *tramaj.Program) tramaj.JSON {
		return stringsJSON(tramaj.DeepActionKeys(libs, prog))
	},
	"holes": func(libs tramaj.Libraries, prog *tramaj.Program) tramaj.JSON {
		return pathsJSON(tramaj.DeepContextHoles(libs, prog))
	},
	"unsupplied": func(libs tramaj.Libraries, prog *tramaj.Program) tramaj.JSON {
		// One entry per imported name, in first-import order; when a name is
		// imported more than once its last import is the one reported.
		byName := tramaj.NewObject()
		for _, u := range tramaj.UnsuppliedParams(libs, prog) {
			byName.Set(u.Name, tramaj.NewObject("name", u.Name, "valueParams", pathsJSON(u.Paths), "typeParams", pathsJSON(nil)))
		}
		for _, u := range tramaj.UnsuppliedTypeParams(libs, prog) {
			entry, _ := byName.Get(u.Name)
			entry.(*tramaj.Object).Set("typeParams", pathsJSON(u.Paths))
		}
		out := []tramaj.JSON{}
		for _, name := range byName.Keys() {
			entry, _ := byName.Get(name)
			out = append(out, entry)
		}
		return out
	},
	"constraints": func(libs tramaj.Libraries, prog *tramaj.Program) tramaj.JSON {
		return tramaj.NewObject(
			"kinds", stringsJSON(tramaj.DeepConstraintKinds(libs, prog)),
			"typeConstraints", typeConstraintsJSON(libs, prog),
		)
	},
	"symbols": func(libs tramaj.Libraries, prog *tramaj.Program) tramaj.JSON {
		sites := []tramaj.JSON{}
		for _, s := range tramaj.SymbolSites(prog) {
			sites = append(sites, int64(s))
		}
		return tramaj.NewObject("sites", sites, "demands", pathsJSON(tramaj.DeepSymbolDemands(libs, prog)))
	},
	"types": func(libs tramaj.Libraries, prog *tramaj.Program) tramaj.JSON {
		refs, err := tramaj.DeepTypeReferences(libs, prog)
		typeErr(err)
		return tramaj.NewObject(
			"declarations", stringsJSON(tramaj.TypeDeclarations(prog)),
			"params", pathsJSON(tramaj.TypeParams(prog)),
			"references", stringsJSON(refs),
			"constraints", typeConstraintsJSON(libs, prog),
		)
	},
	"arithmetic": func(libs tramaj.Libraries, prog *tramaj.Program) tramaj.JSON {
		return stringsJSON(tramaj.DeepArithmeticOps(libs, prog))
	},
	"card": func(libs tramaj.Libraries, prog *tramaj.Program) tramaj.JSON {
		card := tramaj.ProgramCard(libs, prog)
		unsupplied := []tramaj.JSON{}
		for _, u := range card.Unsupplied {
			unsupplied = append(unsupplied, tramaj.NewObject("name", u.Name, "paths", pathsJSON(u.Paths)))
		}
		return tramaj.NewObject(
			"produces", card.Produces,
			"requires", pathsJSON(card.Requires),
			"imports", stringsJSON(card.Imports),
			"emits", stringsJSON(card.Emits),
			"unsupplied", unsupplied,
		)
	},
}

func typeErr(err error) {
	if err != nil {
		die(1, "type error: %v", err)
	}
}

func typeConstraintsJSON(libs tramaj.Libraries, prog *tramaj.Program) tramaj.JSON {
	tcs, err := tramaj.DeepTypeConstraints(libs, prog)
	typeErr(err)
	out := []tramaj.JSON{}
	for _, tc := range tcs {
		out = append(out, tramaj.NewObject("name", tc.Name, "arguments", tc.Arguments))
	}
	return out
}

func stringsJSON(xs []string) tramaj.JSON {
	out := []tramaj.JSON{}
	for _, x := range xs {
		out = append(out, x)
	}
	return out
}

func pathsJSON(ps [][]string) tramaj.JSON {
	out := []tramaj.JSON{}
	for _, p := range ps {
		out = append(out, stringsJSON(p))
	}
	return out
}
