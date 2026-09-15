//! End-to-end tests for the `tramaj-cli-rs` binary, adapted from
//! `tramaj-cli/test/run.sh` (the PureScript CLI's own shell test) to the
//! standard `CARGO_BIN_EXE_<bin>` integration-test pattern.

use std::io::Write;
use std::process::{Command, Output};

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_tramaj-cli-rs"))
}

struct Fixtures {
    dir: tempfile::TempDir,
}

impl Fixtures {
    fn new() -> Self {
        let dir = tempfile::tempdir().expect("tempdir");
        let write = |name: &str, contents: &str| {
            let path = dir.path().join(name);
            let mut f = std::fs::File::create(&path).expect("create fixture");
            f.write_all(contents.as_bytes()).expect("write fixture");
        };

        write("button.tmpl", r#".button(action("on-click", "deploy", {}), "go")"#);
        write(
            "root.tmpl",
            "@b=import(\"button\", {})\n.div(.b(action(\"on-click\", \"save\", {})), $b.rendered)",
        );
        write(
            "typed.tmpl",
            "type Json = string\n!type-constraint(\"has-default\", %Json)\ntrue",
        );
        write(
            "with-type.tmpl",
            "@t=import(\"typed\", {})\ntype Envelope = { payload : $t.types.Json }\ntrue",
        );
        write(
            "eval.tmpl",
            "@n=cardinality($ctx.items)\n.p(\"there are `$n` item(s)\")",
        );
        write("ctx.json", r#"{"items":["a","b","c"]}"#);

        Fixtures { dir }
    }

    fn path(&self, name: &str) -> String {
        self.dir.path().join(name).to_string_lossy().into_owned()
    }
}

fn stdout_of(output: &Output) -> String {
    assert!(
        output.status.success(),
        "expected success, got status={:?} stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).into_owned()
}

#[test]
fn evaluate_bare_form() {
    let fx = Fixtures::new();
    let out = bin()
        .args([fx.path("eval.tmpl"), fx.path("ctx.json")])
        .output()
        .unwrap();
    let s = stdout_of(&out);
    assert!(s.contains("there are 3 item(s)"), "stdout was: {s}");
}

#[test]
fn evaluate_explicit_command() {
    let fx = Fixtures::new();
    let out = bin()
        .args(["evaluate", &fx.path("eval.tmpl"), &fx.path("ctx.json")])
        .output()
        .unwrap();
    let s = stdout_of(&out);
    assert!(s.contains("there are 3 item(s)"), "stdout was: {s}");
}

#[test]
fn analyze_imports() {
    let fx = Fixtures::new();
    let out = bin()
        .args([
            "analyze",
            "imports",
            &fx.path("root.tmpl"),
            "--lib",
            &format!("button={}", fx.path("button.tmpl")),
        ])
        .output()
        .unwrap();
    let s = stdout_of(&out);
    assert!(s.contains("\"button\""), "stdout was: {s}");
}

#[test]
fn analyze_actions() {
    let fx = Fixtures::new();
    let out = bin()
        .args([
            "analyze",
            "actions",
            &fx.path("root.tmpl"),
            "--lib",
            &format!("button={}", fx.path("button.tmpl")),
        ])
        .output()
        .unwrap();
    let s = stdout_of(&out);
    assert!(s.contains("\"save\""), "stdout was: {s}");
    assert!(s.contains("\"deploy\""), "stdout was: {s}");
}

#[test]
fn analyze_constraints() {
    let fx = Fixtures::new();
    let out = bin()
        .args([
            "analyze",
            "constraints",
            &fx.path("with-type.tmpl"),
            "--lib",
            &format!("typed={}", fx.path("typed.tmpl")),
        ])
        .output()
        .unwrap();
    let s = stdout_of(&out);
    assert!(s.contains("\"has-default\""), "stdout was: {s}");
}

#[test]
fn analyze_types() {
    let fx = Fixtures::new();
    let out = bin()
        .args([
            "analyze",
            "types",
            &fx.path("with-type.tmpl"),
            "--lib",
            &format!("typed={}", fx.path("typed.tmpl")),
        ])
        .output()
        .unwrap();
    let s = stdout_of(&out);
    assert!(s.contains("Envelope"), "stdout was: {s}");
    assert!(s.contains("typed"), "stdout was: {s}");
}

#[test]
fn analyze_all() {
    let fx = Fixtures::new();
    let out = bin()
        .args([
            "analyze",
            "all",
            &fx.path("root.tmpl"),
            "--lib",
            &format!("button={}", fx.path("button.tmpl")),
        ])
        .output()
        .unwrap();
    let s = stdout_of(&out);
    assert!(s.contains("\"imports\""), "stdout was: {s}");
    assert!(s.contains("\"actions\""), "stdout was: {s}");
}

#[test]
fn analyze_holes() {
    // `eval.tmpl` reads `$ctx.items` directly, which is a context *read*
    // (surfaced by `analyze card`'s `requires`), not a declared `ctx(...)`
    // hole (what `analyze holes` reports) — so this program has none.
    let fx = Fixtures::new();
    let out = bin().args(["analyze", "holes", &fx.path("eval.tmpl")]).output().unwrap();
    let s = stdout_of(&out);
    assert_eq!(s.trim(), "[]");
}

#[test]
fn analyze_symbols() {
    let fx = Fixtures::new();
    let out = bin()
        .args(["analyze", "symbols", &fx.path("eval.tmpl")])
        .output()
        .unwrap();
    let s = stdout_of(&out);
    let v: serde_json::Value = serde_json::from_str(&s).unwrap();
    assert_eq!(v["sites"], serde_json::json!([]));
    assert_eq!(v["demands"], serde_json::json!([]));
}

#[test]
fn analyze_unsupplied() {
    let fx = Fixtures::new();
    let out = bin()
        .args([
            "analyze",
            "unsupplied",
            &fx.path("root.tmpl"),
            "--lib",
            &format!("button={}", fx.path("button.tmpl")),
        ])
        .output()
        .unwrap();
    let s = stdout_of(&out);
    let v: serde_json::Value = serde_json::from_str(&s).unwrap();
    let arr = v.as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["name"], "button");
}

#[test]
fn analyze_card() {
    let fx = Fixtures::new();
    let out = bin().args(["analyze", "card", &fx.path("eval.tmpl")]).output().unwrap();
    let s = stdout_of(&out);
    let v: serde_json::Value = serde_json::from_str(&s).unwrap();
    assert_eq!(v["produces"], "document");
    assert_eq!(v["requires"], serde_json::json!([["items"]]));
}

#[test]
fn evaluate_missing_template_file_errors() {
    let fx = Fixtures::new();
    let out = bin()
        .args(["missing.tmpl", &fx.path("ctx.json")])
        .output()
        .unwrap();
    assert!(!out.status.success());
}

#[test]
fn evaluate_invalid_json_context_errors() {
    let fx = Fixtures::new();
    let bad_ctx = fx.path("bad.json");
    std::fs::write(&bad_ctx, "not json").unwrap();
    let out = bin().args([fx.path("eval.tmpl"), bad_ctx]).output().unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("invalid JSON context"), "stderr was: {stderr}");
}

#[test]
fn analyze_unknown_subcommand_errors() {
    let fx = Fixtures::new();
    let out = bin()
        .args(["analyze", "bogus", &fx.path("eval.tmpl")])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("unknown analyze subcommand"), "stderr was: {stderr}");
}
