//! Runs the shared cross-implementation corpus at `corpus/cases` (see
//! `corpus/README.md`), the Rust counterpart of
//! `tramaj-hs/test/unit/Tramaj/CorpusSpec.hs` and `tramaj/test/Test/Corpus.purs`.
//! A case here is byte-equality (well, JSON-value equality) between
//! independently written implementations, not merely "this implementation
//! agrees with itself".

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value as Json;

use tramaj_rs::eval::{run_program, LibraryTable, Mode};
use tramaj_rs::parser::parse_program;

#[derive(Deserialize)]
struct CaseMeta {
    name: String,
    mode: String,
    #[serde(default = "default_expect")]
    expect: String,
    #[serde(rename = "errorKind", default)]
    error_kind: Option<String>,
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

fn read_json_file(path: &Path) -> Json {
    let bytes = fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&bytes).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
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

fn run_case(dir: &Path) {
    let meta: CaseMeta = {
        let bytes = fs::read_to_string(dir.join("meta.json")).unwrap();
        serde_json::from_str(&bytes).unwrap()
    };
    let mode = mode_from_meta(dir, &meta.mode);
    let src = fs::read_to_string(dir.join("template.tramaj")).unwrap();
    let libs = read_libs(dir);
    let label = &meta.name;

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
                Ok(prog) => match run_program(mode, &libs, &ctx, &prog) {
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
                Ok(prog) => match run_program(mode, &libs, &ctx, &prog) {
                    Err(e) => panic!("{label}: eval error: {e}"),
                    Ok(actual) => assert_eq!(actual, expected, "{label}: output mismatch"),
                },
            }
        }
        other => panic!("{label}: unknown expect {other}"),
    }
}

fn case_mode(dir: &Path) -> String {
    let meta: CaseMeta = {
        let bytes = fs::read_to_string(dir.join("meta.json")).unwrap();
        serde_json::from_str(&bytes).unwrap()
    };
    meta.mode
}

/// Runs every corpus case whose `meta.json` mode is in `modes`, collecting
/// (not short-circuiting on) failures so one run reports the whole set.
/// Phase-gated: R1 targets `concrete` only, R2 adds `symbolic`.
fn run_corpus_subset(modes: &[&str]) {
    let root = find_corpus_root();
    let all_dirs = load_case_dirs(&root);
    assert!(!all_dirs.is_empty(), "no corpus cases found under {}", root.display());
    let dirs: Vec<PathBuf> = all_dirs
        .into_iter()
        .filter(|d| modes.contains(&case_mode(d).as_str()))
        .collect();
    assert!(
        !dirs.is_empty(),
        "no corpus cases found for modes {modes:?} under {}",
        root.display()
    );

    let mut failures = Vec::new();
    for dir in &dirs {
        let name = dir.file_name().unwrap().to_string_lossy().to_string();
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_case(dir)));
        if let Err(payload) = result {
            let msg = payload
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "<non-string panic payload>".to_string());
            failures.push(format!("{name}: {msg}"));
        }
    }

    if !failures.is_empty() {
        panic!(
            "{}/{} corpus cases failed ({modes:?}):\n{}",
            failures.len(),
            dirs.len(),
            failures.join("\n")
        );
    }
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

/// Full suite, both modes together — the final gate before Rust is at parity.
#[test]
fn shared_corpus_all() {
    run_corpus_subset(&["concrete", "symbolic"]);
}
