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
        write("numbers.tmpl", "[$ctx.i, $ctx.f, 2, 2.0, 1e21, cardinality($ctx.xs)]");
        write("numbers.json", r#"{"i": 3, "f": 3.0, "xs": [1, 2]}"#);
        write("too-big.json", r#"{"i": 9223372036854775808, "f": 3.0, "xs": []}"#);
        write("sum.tmpl", "@total=sum($ctx.i, 1)\n.p(\"total `$total`, half `quotient($ctx.f, 2.0)`\")");
        write(
            "table.tmpl",
            "@top=sort-by-descending($ctx.rows, (r) => $r.spend)\n.ul(map($top, (r) => .li($r.name, \" \", format-number($r.spend, 2, \",\"))))",
        );
        write(
            "rows.json",
            r#"{"rows": [{"name": "a", "spend": 1234.5}, {"name": "b", "spend": 1234567.891}, {"name": "c", "spend": 1234.5}]}"#,
        );
        write("round.tmpl", "sort-by($ctx.rows, (r) => round($r.spend))");
        write("sum-lib.tmpl", "@l=import(\"sum\", {i: 1, f: 1.0})\n$l.rendered");

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

#[test]
fn evaluate_keeps_the_two_number_types() {
    let fx = Fixtures::new();
    let out = bin()
        .args([fx.path("numbers.tmpl"), fx.path("numbers.json")])
        .output()
        .unwrap();
    assert_eq!(stdout_of(&out).trim(), "[3,3.0,2,2.0,1e+21,2]");
}

#[test]
fn evaluate_refuses_an_integer_outside_the_range() {
    let fx = Fixtures::new();
    let out = bin()
        .args([fx.path("numbers.tmpl"), fx.path("too-big.json")])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("eval error: TypeMismatch"), "stderr was: {stderr}");
    assert!(stderr.contains("9223372036854775808"), "stderr was: {stderr}");
}

#[test]
fn evaluate_with_arithmetic() {
    let fx = Fixtures::new();
    let out = bin()
        .args(["evaluate", "--arithmetic", &fx.path("sum.tmpl"), &fx.path("numbers.json")])
        .output()
        .unwrap();
    let s = stdout_of(&out);
    assert!(s.contains("total 4, half 1.5"), "stdout was: {s}");
}

#[test]
fn evaluate_without_arithmetic_names_the_flag() {
    let fx = Fixtures::new();
    let out = bin()
        .args([fx.path("sum.tmpl"), fx.path("numbers.json")])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("eval error: UnboundName sum"), "stderr was: {stderr}");
    assert!(
        stderr.contains("references the arithmetic builtins quotient, sum, which are unbound unless --arithmetic is given"),
        "stderr was: {stderr}"
    );
}

#[test]
fn evaluate_error_without_arithmetic_names_has_no_note() {
    let fx = Fixtures::new();
    let out = bin()
        .args([fx.path("eval.tmpl"), fx.path("numbers.json")])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("PathNotFound"), "stderr was: {stderr}");
    assert!(!stderr.contains("--arithmetic"), "stderr was: {stderr}");
}

#[test]
fn analyze_arithmetic_follows_imports() {
    let fx = Fixtures::new();
    let out = bin()
        .args([
            "analyze",
            "arithmetic",
            &fx.path("sum-lib.tmpl"),
            "--lib",
            &format!("sum={}", fx.path("sum.tmpl")),
        ])
        .output()
        .unwrap();
    assert_eq!(stdout_of(&out).trim(), r#"["quotient","sum"]"#);

    let out = bin()
        .args(["analyze", "all", &fx.path("sum.tmpl")])
        .output()
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(&stdout_of(&out)).unwrap();
    assert_eq!(v["arithmetic"], serde_json::json!(["quotient", "sum"]));
}

#[test]
fn analyze_rejects_the_arithmetic_flag() {
    let fx = Fixtures::new();
    let out = bin()
        .args(["analyze", "arithmetic", "--arithmetic", &fx.path("sum.tmpl")])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("--arithmetic is not valid for the analyze command"), "stderr was: {stderr}");
}

#[test]
fn evaluate_sorts_and_formats_without_a_flag() {
    let fx = Fixtures::new();
    let out = bin()
        .args([fx.path("table.tmpl"), fx.path("rows.json")])
        .output()
        .unwrap();
    let s = stdout_of(&out);
    let at = |needle: &str| s.find(needle).unwrap_or_else(|| panic!("no {needle} in: {s}"));
    // Highest spend first, and the two equal spends in input order.
    assert!(at("1,234,567.89") < at("\"a\""), "stdout was: {s}");
    assert!(at("\"a\"") < at("\"c\""), "stdout was: {s}");
    assert!(s.contains("1,234.50"), "stdout was: {s}");
}

#[test]
fn round_belongs_to_the_arithmetic_profile() {
    let fx = Fixtures::new();
    let out = bin()
        .args(["analyze", "arithmetic", &fx.path("round.tmpl")])
        .output()
        .unwrap();
    assert_eq!(stdout_of(&out).trim(), r#"["round"]"#);

    let out = bin()
        .args([fx.path("round.tmpl"), fx.path("rows.json")])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("eval error: UnboundName round"), "stderr was: {stderr}");
    assert!(stderr.contains("unbound unless --arithmetic is given"), "stderr was: {stderr}");

    let out = bin()
        .args(["evaluate", "--arithmetic", &fx.path("round.tmpl"), &fx.path("rows.json")])
        .output()
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(&stdout_of(&out)).unwrap();
    let names: Vec<&str> = v.as_array().unwrap().iter().map(|r| r["name"].as_str().unwrap()).collect();
    // 1234.5 rounds to 1235 twice, and the tie keeps the input order.
    assert_eq!(names, ["a", "c", "b"]);
}
