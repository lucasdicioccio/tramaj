//! `?shape(key, shape)` and its `~name` markers (`specs/v3-symbols.md` §1.2,
//! `specs/decisions.md` §19), for what the shared corpus has no shape for:
//! the AST the form lowers to, its site numbering, the parse errors one by
//! one, and `symbol_sites`.

use std::collections::{HashMap, HashSet};

use tramaj_rs::analysis::symbol_sites;
use tramaj_rs::ast::{Expr, SHAPE_KEY_NAME};
use tramaj_rs::eval::{run_program_with, Mode, Options};
use tramaj_rs::json::{parse, stringify, Json};
use tramaj_rs::parser::parse_program;

fn shape_key() -> Expr {
    Expr::Path(SHAPE_KEY_NAME.to_string(), vec![])
}

fn marker_at(site: usize, name: &str, key: Option<Expr>) -> Expr {
    let mut elements = vec![shape_key(), Expr::StringLit(name.to_string())];
    elements.extend(key);
    Expr::Alloc(site, Box::new(Expr::ArrayLit(elements)))
}

fn shape(key: &str, body: Expr) -> Expr {
    Expr::Let(
        SHAPE_KEY_NAME.to_string(),
        Box::new(Expr::StringLit(key.to_string())),
        Box::new(body),
    )
}

fn root(src: &str) -> Expr {
    parse_program(src)
        .unwrap_or_else(|e| panic!("parse error in {src:?}: {e}"))
        .root()
        .clone()
}

fn run(mode: Mode, src: &str) -> Json {
    let prog = parse_program(src).unwrap_or_else(|e| panic!("parse error in {src:?}: {e}"));
    let options = Options { mode, arithmetic: false };
    run_program_with(&options, &HashMap::new(), &Json::Null, &prog).expect("evaluates")
}

#[test]
fn lowers_to_a_hidden_binding_with_markers_at_the_forms_one_site() {
    assert_eq!(
        root(r#"?shape("d", {~replicas, ports: [~http($x)]})"#),
        shape(
            "d",
            Expr::ObjectLit(vec![
                ("replicas".to_string(), marker_at(0, "replicas", None)),
                (
                    "ports".to_string(),
                    Expr::ArrayLit(vec![marker_at(0, "http", Some(Expr::Path("x".to_string(), vec![])))]),
                ),
            ]),
        )
    );
}

#[test]
fn a_plain_alloc_inside_a_shape_takes_the_next_site() {
    assert_eq!(
        root(r#"?shape("o", [~a, ?("p")])"#),
        shape(
            "o",
            Expr::ArrayLit(vec![
                marker_at(0, "a", None),
                Expr::Alloc(1, Box::new(Expr::StringLit("p".to_string()))),
            ]),
        )
    );
}

#[test]
fn symbol_sites_counts_a_shape_once_in_one_sequence_with_alloc() {
    let prog = parse_program(r#"[?shape("o", {~a, b: [~b, ~c(1)], i: ?shape("i", {~d})}), ?("p")]"#)
        .expect("parses");
    assert_eq!(symbol_sites(&prog), HashSet::from([0, 1, 2]));
}

#[test]
fn allocates_name_and_keyed_symbols_with_a_null_binding_even_when_bound() {
    let out = run(Mode::Symbolic, "@d = ?shape(\"d\", {~a, b: map([1, 2], (x) => ~b($x))})\n$d");
    let expected = parse(
        r##"[
          {"id": "#0:[\"d\",\"a\"]", "origin": {"kind": "alloc", "site": 0, "key": ["d", "a"]}, "binding": null},
          {"id": "#0:[\"d\",\"b\",1]", "origin": {"kind": "alloc", "site": 0, "key": ["d", "b", 1]}, "binding": null},
          {"id": "#0:[\"d\",\"b\",2]", "origin": {"kind": "alloc", "site": 0, "key": ["d", "b", 2]}, "binding": null}
        ]"##,
    )
    .expect("expected is JSON");
    let symbols = match &out {
        Json::Object(fields) => fields
            .get("symbols")
            .cloned()
            .unwrap_or_else(|| panic!("no symbols in {}", stringify(&out))),
        _ => panic!("not an envelope: {}", stringify(&out)),
    };
    assert_eq!(stringify(&symbols), stringify(&expected));
}

#[test]
fn leaves_dollar_shape_and_at_shape_alone() {
    assert_eq!(stringify(&run(Mode::Concrete, "@shape = 1\n$shape")), "1");
}

#[test]
fn rejects_misused_markers_and_malformed_shapes() {
    let rejects = [
        ("a marker outside any shape", "[~a]"),
        ("a marker in a ?shape's key", r#"?shape(~k, {~a})"#),
        ("a marker in a nested ?shape's key", r#"?shape("o", {~a, i: ?shape(~k, {~b})})"#),
        ("a bare marker under a lambda inside the shape", r#"?shape("d", map($xs, (x) => ~a))"#),
        ("a bare shorthand marker under a lambda", r#"?shape("d", map($xs, (x) => {~a}))"#),
        ("a duplicate marker name, bare and keyed", r#"?shape("d", [~a, map($xs, (x) => ~a($x))])"#),
        ("a shape with no marker", r#"?shape("d", {a: 1})"#),
        ("?shape with three arguments", r#"?shape("d", {~a}, 1)"#),
        ("?shape with one argument", r#"?shape("d")"#),
        ("a space after the marker leader", r#"?shape("d", ~ a)"#),
        ("?(a, b)", r#"?("a", "b")"#),
    ];
    for (what, src) in rejects {
        assert!(parse_program(src).is_err(), "should reject {what}: {src}");
    }
}
