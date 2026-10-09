//! Runs the shared cross-implementation corpus at `corpus/cases` (see
//! `corpus/README.md`), the Rust counterpart of
//! `tramaj-hs/test/unit/Tramaj/CorpusSpec.hs` and `tramaj/test/Test/Corpus.purs`.
//! A case here is byte-equality (well, JSON-value equality) between
//! independently written implementations, not merely "this implementation
//! agrees with itself".

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use tramaj_rs::analysis::{
    arithmetic_ops, context_holes, context_reads, deep_action_keys, deep_arithmetic_ops,
    deep_context_holes, static_action_keys, static_import_names, transitive_import_names,
};
use tramaj_rs::ast::Program;
use tramaj_rs::eval::{run_program_with, LibraryTable, Mode, Options};
use tramaj_rs::json::Json;
use tramaj_rs::parser::parse_program;

#[derive(Deserialize)]
struct CaseMeta {
    name: String,
    /// Absent in an `"expect": "analysis"` case, which evaluates nothing.
    #[serde(default)]
    mode: String,
    #[serde(default = "default_expect")]
    expect: String,
    #[serde(rename = "errorKind", default)]
    error_kind: Option<String>,
    #[serde(default)]
    profiles: Vec<String>,
    /// The key `profiles` replaced. A case that still has it is refused
    /// rather than run without its gate.
    #[serde(default)]
    requires: Option<serde_json::Value>,
}

/// The profiles (`profiles` in `meta.json`, see `corpus/README.md`) this port
/// can provide. A case naming any other one is skipped. `base` is the
/// language without any profile. `int-float` is the two number types, and
/// `int64` the integer range this port has (`tramaj_rs::json`). `arithmetic`
/// is the arithmetic profile: it is an option of each evaluation, and
/// `run_case` turns it on only for a case that lists it. `round` is its
/// tenth name, which a case that calls it lists as well. `sort` is the two
/// sorts and `format-number` the builtin of that name, both part of every
/// evaluation.
const PROVIDED_PROFILES: &[&str] = &[
    "base",
    "int-float",
    "arithmetic",
    "int64",
    "sort",
    "format-number",
    "round",
];

/// The profiles every port provides (`corpus/README.md`). A case naming one
/// that `PROVIDED_PROFILES` lacks fails instead of being skipped.
const REQUIRED_PROFILES: &[&str] = &["int-float", "arithmetic"];

/// The profiles a case names that this port does not provide.
fn missing_profiles(meta: &CaseMeta) -> Vec<String> {
    meta.profiles
        .iter()
        .filter(|r| !PROVIDED_PROFILES.contains(&r.as_str()))
        .cloned()
        .collect()
}

/// The elements of a set-valued analysis result, each as its JSON text, so
/// a set of names and a set of paths compare the same way.
type AnalysisResult = BTreeSet<String>;

fn as_result<T: serde::Serialize>(xs: impl IntoIterator<Item = T>) -> AnalysisResult {
    xs.into_iter()
        .map(|x| serde_json::to_string(&x).expect("serializable analysis element"))
        .collect()
}

/// The static analyses (reference.md §9) this port provides to an
/// `"expect": "analysis"` case, by the name `analysis.json` gives them. A
/// case naming any other one is skipped.
fn provided_analysis(name: &str, libs: &LibraryTable, prog: &Program) -> Option<AnalysisResult> {
    Some(match name {
        "staticImportNames" => as_result(static_import_names(prog)),
        "transitiveImportNames" => as_result(transitive_import_names(libs, prog)),
        "staticActionKeys" => as_result(static_action_keys(prog)),
        "deepActionKeys" => as_result(deep_action_keys(libs, prog)),
        "contextHoles" => as_result(context_holes(prog)),
        "deepContextHoles" => as_result(deep_context_holes(libs, prog)),
        "contextReads" => as_result(context_reads(prog)),
        "arithmeticOps" => as_result(arithmetic_ops(prog)),
        "deepArithmeticOps" => as_result(deep_arithmetic_ops(libs, prog)),
        _ => return None,
    })
}

/// What `run_case` did with a case. A failing case panics instead.
#[derive(Debug, PartialEq)]
enum Outcome {
    Passed,
    /// Not run: the case names these profiles (or, written `analysis <name>`,
    /// these analyses), which this port does not provide.
    Skipped(Vec<String>),
}

fn default_expect() -> String {
    "success".to_string()
}

/// `corpus/cases` lives at the repo root, but `cargo test`'s working
/// directory is the crate root — walk upward until it is found, exactly
/// like `CorpusSpec.hs`'s `findCorpusRoot`.
fn find_corpus_root() -> PathBuf {
    let mut dir = PathBuf::from(".");
    loop {
        let candidate = dir.join("corpus").join("cases");
        if candidate.is_dir() {
            return candidate;
        }
        let parent = dir.join("..");
        let abs_here = fs::canonicalize(&dir).expect("canonicalize dir");
        let abs_up = fs::canonicalize(&parent).expect("canonicalize parent");
        if abs_here == abs_up {
            panic!("could not locate corpus/cases above the test working directory");
        }
        dir = parent;
    }
}

fn load_case_dirs(root: &Path) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = fs::read_dir(root)
        .unwrap_or_else(|e| panic!("reading {}: {e}", root.display()))
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|p| p.is_dir())
        .collect();
    dirs.sort();
    dirs
}

/// Reads `ctx.json` or `expected.json` with the port's own parser, which
/// keeps `3` and `3.0` apart and the digits of an integer beyond 2^53
/// (`corpus/README.md`). It refuses no number: a number the value domain
/// does not hold reaches the evaluator as it was written, and it is the
/// evaluator that refuses it.
fn read_json_file(path: &Path) -> Json {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    tramaj_rs::json::parse(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn read_libs(dir: &Path) -> LibraryTable {
    let libs_dir = dir.join("libs");
    let mut table = HashMap::new();
    if !libs_dir.is_dir() {
        return table;
    }
    for entry in fs::read_dir(&libs_dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("tramaj") {
            continue;
        }
        let name = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap()
            .to_string();
        let src = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        match parse_program(&src) {
            Ok(prog) => {
                table.insert(name, prog);
            }
            Err(e) => panic!("{}: parse error: {e}", path.display()),
        }
    }
    table
}

fn mode_from_meta(dir: &Path, m: &str) -> Mode {
    match m {
        "concrete" => Mode::Concrete,
        "symbolic" => Mode::Symbolic,
        other => panic!("{}: unknown mode {other}", dir.display()),
    }
}

/// The constructor name an `EvalError`'s `Display` leads with, mirroring
/// `tramaj-hs`'s `errorConstructor`.
fn error_constructor(e: &tramaj_rs::eval::EvalError) -> String {
    e.to_string()
        .split_whitespace()
        .next()
        .unwrap_or("")
        .to_string()
}

fn run_case(dir: &Path) -> Outcome {
    let meta: CaseMeta = {
        let bytes = fs::read_to_string(dir.join("meta.json")).unwrap();
        serde_json::from_str(&bytes).unwrap()
    };
    let label = &meta.name;
    if meta.requires.is_some() {
        panic!("{label}: \"requires\" was replaced by \"profiles\" (corpus/README.md)");
    }
    let missing = missing_profiles(&meta);
    if let Some(r) = missing.iter().find(|r| REQUIRED_PROFILES.contains(&r.as_str())) {
        panic!("{label}: not provided, but required of every port: {r}");
    }
    if meta.expect == "analysis" {
        return run_analysis_case(dir, label, missing);
    }
    if !missing.is_empty() {
        return Outcome::Skipped(missing);
    }
    // The arithmetic profile is on only for a case that lists it: every
    // other case runs with the ten names unbound.
    let options = Options {
        mode: mode_from_meta(dir, &meta.mode),
        arithmetic: meta.profiles.iter().any(|p| p == "arithmetic"),
    };
    let src = fs::read_to_string(dir.join("template.tramaj")).unwrap();
    let libs = read_libs(dir);

    match meta.expect.as_str() {
        "parse-error" => {
            if parse_program(&src).is_ok() {
                panic!("{label}: expected a parse error, but the template parsed");
            }
        }
        "eval-error" => {
            let error_kind = meta
                .error_kind
                .as_deref()
                .unwrap_or_else(|| panic!("{label}: eval-error case needs errorKind"));
            let ctx = read_json_file(&dir.join("ctx.json"));
            match parse_program(&src) {
                Err(e) => panic!("{label}: parse error: {e}"),
                Ok(prog) => match run_program_with(&options, &libs, &ctx, &prog) {
                    Ok(_) => panic!(
                        "{label}: expected eval error {error_kind}, but evaluation succeeded"
                    ),
                    Err(e) => {
                        let actual_kind = error_constructor(&e);
                        assert_eq!(
                            actual_kind, error_kind,
                            "{label}: expected eval error {error_kind}, got {actual_kind} ({e})"
                        );
                    }
                },
            }
        }
        "success" => {
            let ctx = read_json_file(&dir.join("ctx.json"));
            let expected = read_json_file(&dir.join("expected.json"));
            match parse_program(&src) {
                Err(e) => panic!("{label}: parse error: {e}"),
                Ok(prog) => match run_program_with(&options, &libs, &ctx, &prog) {
                    Err(e) => panic!("{label}: eval error: {e}"),
                    Ok(actual) => assert_eq!(actual, expected, "{label}: output mismatch"),
                },
            }
        }
        other => panic!("{label}: unknown expect {other}"),
    }
    Outcome::Passed
}

/// An `"expect": "analysis"` case: no context and no evaluation. Each named
/// analysis runs over the parsed template (and `libs/`, for a deep variant)
/// and its result is compared, as a set, with the array `analysis.json`
/// gives. The names are the keys of `analysis.json`, which holds no number,
/// so reading it before deciding to skip is safe on every port.
fn run_analysis_case(dir: &Path, label: &str, mut missing: Vec<String>) -> Outcome {
    let expected: BTreeMap<String, Vec<serde_json::Value>> = {
        let path = dir.join("analysis.json");
        let bytes = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        serde_json::from_str(&bytes).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
    };
    let src = fs::read_to_string(dir.join("template.tramaj")).unwrap();
    let libs = read_libs(dir);
    let prog = parse_program(&src).unwrap_or_else(|e| panic!("{label}: parse error: {e}"));
    let mut results = Vec::new();
    for (name, want) in &expected {
        match provided_analysis(name, &libs, &prog) {
            Some(actual) => results.push((name, actual, want)),
            None => missing.push(format!("analysis {name}")),
        }
    }
    if !missing.is_empty() {
        return Outcome::Skipped(missing);
    }
    for (name, actual, want) in results {
        let want_set = as_result(want);
        // A repeated element is refused: the file is a set.
        assert_eq!(
            want_set.len(),
            want.len(),
            "{label}: analysis.json: {name} repeats an element"
        );
        assert_eq!(actual, want_set, "{label}: {name} mismatch");
    }
    Outcome::Passed
}

/// The group a case is run in: its mode, or `analysis` for an
/// `"expect": "analysis"` case, which has none.
fn case_group(dir: &Path) -> String {
    let meta: CaseMeta = {
        let bytes = fs::read_to_string(dir.join("meta.json")).unwrap();
        serde_json::from_str(&bytes).unwrap()
    };
    if meta.expect == "analysis" {
        "analysis".to_string()
    } else {
        meta.mode
    }
}

/// Runs every corpus case whose group (`case_group`) is in `modes`, collecting
/// (not short-circuiting on) failures so one run reports the whole set.
/// Phase-gated: R1 targets `concrete` only, R2 adds `symbolic`.
fn run_corpus_subset(modes: &[&str]) {
    let root = find_corpus_root();
    let all_dirs = load_case_dirs(&root);
    assert!(!all_dirs.is_empty(), "no corpus cases found under {}", root.display());
    let dirs: Vec<PathBuf> = all_dirs
        .into_iter()
        .filter(|d| modes.contains(&case_group(d).as_str()))
        .collect();
    assert!(
        !dirs.is_empty(),
        "no corpus cases found for modes {modes:?} under {}",
        root.display()
    );

    let mut failures = Vec::new();
    let mut skipped = Vec::new();
    for dir in &dirs {
        let name = dir.file_name().unwrap().to_string_lossy().to_string();
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_case(dir)));
        match result {
            Ok(Outcome::Passed) => {}
            Ok(Outcome::Skipped(missing)) => {
                skipped.push(format!("{name} (not provided: {})", missing.join(", ")))
            }
            Err(payload) => {
                let msg = payload
                    .downcast_ref::<String>()
                    .cloned()
                    .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
                    .unwrap_or_else(|| "<non-string panic payload>".to_string());
                failures.push(format!("{name}: {msg}"));
            }
        }
    }
    report_skipped(modes, dirs.len(), &skipped);

    if !failures.is_empty() {
        panic!(
            "{}/{} corpus cases failed ({modes:?}):\n{}",
            failures.len(),
            dirs.len(),
            failures.join("\n")
        );
    }
}

/// libtest has no way to mark part of a test as skipped, and it captures
/// what a passing test prints through `println!`/`eprintln!`. Writing to the
/// stderr handle directly is not captured, so a skipped case shows up in an
/// ordinary `cargo test` run rather than being counted silently as passed.
fn report_skipped(modes: &[&str], total: usize, skipped: &[String]) {
    if skipped.is_empty() {
        return;
    }
    let mut err = std::io::stderr().lock();
    let _ = writeln!(
        err,
        "shared corpus ({modes:?}): skipped {} of {total} cases",
        skipped.len()
    );
    for line in skipped {
        let _ = writeln!(err, "  skipped: {line}");
    }
}

/// `corpus/runner-checks/unsupported-profile` would fail if it ran: its
/// `expected.json` does not match what the template evaluates to.
#[test]
fn case_with_unprovided_profile_is_skipped() {
    let root = find_corpus_root();
    let dir = root
        .join("..")
        .join("runner-checks")
        .join("unsupported-profile");
    assert_eq!(
        run_case(&dir),
        Outcome::Skipped(vec!["never-declared".to_string()])
    );
}

/// R1's target: every `concrete`-mode case (specs/reference.md, no v3/v4).
#[test]
fn shared_corpus_concrete() {
    run_corpus_subset(&["concrete"]);
}

/// R2's target: `symbolic`-mode cases (specs/v3-symbols.md) on top of R1.
#[test]
fn shared_corpus_symbolic() {
    run_corpus_subset(&["symbolic"]);
}

/// The `"expect": "analysis"` cases (specs/reference.md §9), which have no mode.
#[test]
fn shared_corpus_analysis() {
    run_corpus_subset(&["analysis"]);
}

/// Full suite, every group together — the final gate before Rust is at parity.
#[test]
fn shared_corpus_all() {
    run_corpus_subset(&["concrete", "symbolic", "analysis"]);
}
