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
	Name      string `json:"name"`
	Mode      Mode   `json:"mode"`
	Expect    string `json:"expect"`
	ErrorKind string `json:"errorKind"`
}

func runCase(t *testing.T, caseDir string, meta caseMeta) {
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
			var meta caseMeta
			if err := json.Unmarshal(readFile(t, filepath.Join(caseDir, "meta.json")), &meta); err != nil {
				t.Fatal(err)
			}
			runCase(t, caseDir, meta)
		})
	}
}
