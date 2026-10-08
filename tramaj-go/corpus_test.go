package tramaj

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Runs the shared cross-implementation corpus at corpus/cases (see
// corpus/README.md), the Go counterpart of tramaj-py/tests/test_corpus.py. A
// case here is JSON-value equality between independently written
// implementations, not merely "this implementation agrees with itself".

// findCorpusRoot walks upward until corpus/cases is found: it lives at the
// repository root.
func findCorpusRoot(t *testing.T) string {
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		candidate := filepath.Join(dir, "corpus", "cases")
		if st, err := os.Stat(candidate); err == nil && st.IsDir() {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("could not locate corpus/cases above the test directory")
		}
		dir = parent
	}
}

func readFile(t *testing.T, path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func readJSON(t *testing.T, path string) JSON {
	v, err := ParseJSON(readFile(t, path))
	if err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return v
}

func readLibs(t *testing.T, caseDir string) Libraries {
	libs := Libraries{}
	paths, _ := filepath.Glob(filepath.Join(caseDir, "libs", "*.tramaj"))
	for _, path := range paths {
		prog, err := ParseProgram(string(readFile(t, path)))
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		libs[strings.TrimSuffix(filepath.Base(path), ".tramaj")] = prog
	}
	return libs
}

type caseMeta struct {
	Name string `json:"name"`
	// Mode is absent in an "expect": "analysis" case, which evaluates nothing.
	Mode      Mode     `json:"mode"`
	Expect    string   `json:"expect"`
	ErrorKind string   `json:"errorKind"`
	Profiles  []string `json:"profiles"`
	// Requires is the key "profiles" replaced. A case that still has it is
	// refused rather than run without its gate.
	Requires json.RawMessage `json:"requires"`
}

// providedProfiles holds the profiles ("profiles" in meta.json, see
// corpus/README.md) this port can provide. A case naming any other one is
// skipped. "base" is the language without any profile; this port has no
// other yet, and no integer range to name until it has the two number types
// ("int-float").
var providedProfiles = map[string]bool{"base": true}

// missingProfiles lists the profiles a case names that this port does not
// provide.
func missingProfiles(meta caseMeta) []string {
	var missing []string
	for _, r := range meta.Profiles {
		if !providedProfiles[r] {
			missing = append(missing, r)
		}
	}
	return missing
}

// providedAnalyses holds the static analyses (reference.md §9) this port
// provides to an "expect": "analysis" case, by the name analysis.json gives
// them. A case naming any other one is skipped.
var providedAnalyses = map[string]func(libs Libraries, prog *Program) any{
	"staticImportNames":     func(_ Libraries, prog *Program) any { return StaticImportNames(prog) },
	"transitiveImportNames": func(libs Libraries, prog *Program) any { return TransitiveImportNames(libs, prog) },
	"staticActionKeys":      func(_ Libraries, prog *Program) any { return StaticActionKeys(prog) },
	"deepActionKeys":        func(libs Libraries, prog *Program) any { return DeepActionKeys(libs, prog) },
	"contextHoles":          func(_ Libraries, prog *Program) any { return ContextHoles(prog) },
	"deepContextHoles":      func(libs Libraries, prog *Program) any { return DeepContextHoles(libs, prog) },
	"contextReads":          func(_ Libraries, prog *Program) any { return ContextReads(prog) },
}

// elementSet reads a JSON array as the sorted JSON texts of its elements, so
// a set of names and a set of paths compare the same way. The second result
// is false when an element is repeated.
func elementSet(t *testing.T, data []byte) ([]string, bool) {
	var elems []json.RawMessage
	if err := json.Unmarshal(data, &elems); err != nil {
		t.Fatalf("not an array: %v", err)
	}
	seen := map[string]bool{}
	out := []string{}
	for _, e := range elems {
		var v any
		if err := json.Unmarshal(e, &v); err != nil {
			t.Fatal(err)
		}
		canon, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		if !seen[string(canon)] {
			seen[string(canon)] = true
			out = append(out, string(canon))
		}
	}
	sort.Strings(out)
	return out, len(out) == len(elems)
}

// runAnalysisCase runs an "expect": "analysis" case: no context and no
// evaluation. Each named analysis runs over the parsed template (and libs/,
// for a deep variant) and its result is compared, as a set, with the array
// analysis.json gives. The names are the keys of analysis.json, which holds
// no number, so reading it before deciding to skip is safe on every port.
func runAnalysisCase(t *testing.T, caseDir string, missing []string) {
	var expected map[string]json.RawMessage
	if err := json.Unmarshal(readFile(t, filepath.Join(caseDir, "analysis.json")), &expected); err != nil {
		t.Fatalf("analysis.json: %v", err)
	}
	names := make([]string, 0, len(expected))
	for name := range expected {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if providedAnalyses[name] == nil {
			missing = append(missing, "analysis "+name)
		}
	}
	if len(missing) > 0 {
		t.Skipf("not provided: %s", strings.Join(missing, ", "))
	}
	prog, err := ParseProgram(string(readFile(t, filepath.Join(caseDir, "template.tramaj"))))
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	libs := readLibs(t, caseDir)
	for _, name := range names {
		want, distinct := elementSet(t, expected[name])
		if !distinct {
			t.Fatalf("analysis.json: %s repeats an element", name)
		}
		actualJSON, err := json.Marshal(providedAnalyses[name](libs, prog))
		if err != nil {
			t.Fatal(err)
		}
		if string(actualJSON) == "null" {
			actualJSON = []byte("[]")
		}
		actual, _ := elementSet(t, actualJSON)
		if strings.Join(actual, ",") != strings.Join(want, ",") {
			t.Fatalf("%s mismatch\n  expected: %s\n  actual:   %s", name, strings.Join(want, ","), strings.Join(actual, ","))
		}
	}
}

func readMeta(t *testing.T, caseDir string) caseMeta {
	var meta caseMeta
	if err := json.Unmarshal(readFile(t, filepath.Join(caseDir, "meta.json")), &meta); err != nil {
		t.Fatal(err)
	}
	return meta
}

func runCase(t *testing.T, caseDir string, meta caseMeta) {
	if meta.Requires != nil {
		t.Fatal(`"requires" was replaced by "profiles" (corpus/README.md)`)
	}
	missing := missingProfiles(meta)
	if meta.Expect == "analysis" {
		runAnalysisCase(t, caseDir, missing)
		return
	}
	if len(missing) > 0 {
		t.Skipf("not provided: %s", strings.Join(missing, ", "))
	}
	if meta.Mode != Concrete && meta.Mode != Symbolic {
		t.Fatalf("unknown mode %q", meta.Mode)
	}
	prog, parseErr := ParseProgram(string(readFile(t, filepath.Join(caseDir, "template.tramaj"))))

	if meta.Expect == "parse-error" {
		if parseErr == nil {
			t.Fatal("expected a parse error, but the template parsed")
		}
		return
	}
	if parseErr != nil {
		t.Fatalf("parse error: %v", parseErr)
	}

	libs := readLibs(t, caseDir)
	ctx := readJSON(t, filepath.Join(caseDir, "ctx.json"))
	actual, err := RunProgram(meta.Mode, libs, ctx, prog)

	switch meta.Expect {
	case "eval-error":
		if meta.ErrorKind == "" {
			t.Fatal("eval-error case needs errorKind")
		}
		if err == nil {
			t.Fatalf("expected eval error %s, but evaluation succeeded", meta.ErrorKind)
		}
		if kind := err.(*EvalError).Kind; kind != meta.ErrorKind {
			t.Fatalf("expected eval error %s, got %s (%v)", meta.ErrorKind, kind, err)
		}
	case "", "success":
		if err != nil {
			t.Fatalf("eval error: %v", err)
		}
		expected := readJSON(t, filepath.Join(caseDir, "expected.json"))
		if !JSONEqual(actual, expected) {
			t.Fatalf("output mismatch\n  expected: %s\n  actual:   %s", CompactJSON(expected), CompactJSON(actual))
		}
	default:
		t.Fatalf("unknown expect %q", meta.Expect)
	}
}

func TestCorpus(t *testing.T) {
	root := findCorpusRoot(t)
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	var dirs []string
	for _, e := range entries {
		if e.IsDir() {
			dirs = append(dirs, e.Name())
		}
	}
	sort.Strings(dirs)
	if len(dirs) == 0 {
		t.Fatal("corpus has no cases")
	}
	for _, name := range dirs {
		caseDir := filepath.Join(root, name)
		t.Run(name, func(t *testing.T) {
			runCase(t, caseDir, readMeta(t, caseDir))
		})
	}
}

// corpus/runner-checks/unsupported-profile would fail if it ran: its
// expected.json does not match what the template evaluates to.
func TestCorpusSkipsUnprovidedProfile(t *testing.T) {
	caseDir := filepath.Join(filepath.Dir(findCorpusRoot(t)), "runner-checks", "unsupported-profile")
	skipped := false
	t.Run("unsupported-profile", func(t *testing.T) {
		defer func() { skipped = t.Skipped() }()
		runCase(t, caseDir, readMeta(t, caseDir))
	})
	if !skipped {
		t.Fatal("a case naming a profile this port does not provide was not skipped")
	}
}
