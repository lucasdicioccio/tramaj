//! Sorting, `format-number` and `round` (`specs/reference.md` §11, *Sorting*
//! and *Number formatting*; `specs/decisions.md` §20), for what the shared
//! corpus has no shape for: that the key function of a sort is applied once
//! per element, that every analysis sees inside a sort, the parser's forms
//! and refusals, and `format-number` at the ends of what a double holds.

use std::collections::HashMap;

use tramaj_rs::analysis::{
    arithmetic_ops, constraint_kinds, context_holes, context_reads, deep_action_keys, deep_arithmetic_ops,
    deep_constraint_kinds, deep_context_holes, deep_symbol_demands, static_action_keys, static_import_names,
    symbol_demands, symbol_sites, transitive_import_names, ARITHMETIC_NAMES,
};
use tramaj_rs::ast::{Expr, Program};
use tramaj_rs::eval::{
    builtin_names, emitted_constraint_count, run_program_with, EvalError, LibraryTable, Mode, Options,
};
use tramaj_rs::json::{parse, stringify, Json};
use tramaj_rs::parser::parse_program;

const ON: Options = Options { mode: Mode::Concrete, arithmetic: true };
const SYMBOLIC_ON: Options = Options { mode: Mode::Symbolic, arithmetic: true };

fn run(options: &Options, ctx: &str, src: &str) -> Result<String, EvalError> {
    let prog = parse_program(src).unwrap_or_else(|e| panic!("parse error in {src:?}: {e}"));
    let ctx = parse(ctx).expect("context is JSON");
    run_program_with(options, &HashMap::new(), &ctx, &prog).map(|j| stringify(&j))
}

/// Without the arithmetic profile: the sorts and `format-number` need none.
fn eval(src: &str) -> Result<String, EvalError> {
    run(&Options::default(), "null", src)
}

fn kind(r: Result<String, EvalError>) -> String {
    match r {
        Ok(v) => format!("ok {v}"),
        Err(e) => e.to_string().split_whitespace().next().unwrap_or("").to_string(),
    }
}

fn ok(src: &str) -> String {
    eval(src).unwrap_or_else(|e| panic!("{src:?} failed: {e}"))
}

fn path(name: &str) -> Expr {
    Expr::Path(name.to_string(), vec![])
}

// Parser ------------------------------------------------------------------------

#[test]
fn both_names_and_the_dollar_spelling_lower_to_sort_by() {
    let root = |src: &str| match parse_program(src).unwrap_or_else(|e| panic!("{src:?}: {e}")) {
        Program::ExpressionProgram(e) => e,
        other => panic!("{src:?} is not an expression program: {other:?}"),
    };
    let sort = |descending: bool| {
        Expr::SortBy(
            descending,
            Box::new(Expr::Path("ctx".to_string(), vec!["xs".to_string()])),
            Box::new(path("f")),
        )
    };
    assert_eq!(root("sort-by($ctx.xs, $f)"), sort(false));
    assert_eq!(root("$sort-by($ctx.xs, $f)"), sort(false));
    assert_eq!(root("sort-by-descending($ctx.xs, $f)"), sort(true));
    assert_eq!(root("$sort-by-descending($ctx.xs, $f)"), sort(true));
    // A longer name is an ordinary one.
    assert!(matches!(root("sort-by-name($ctx.xs, $f)"), Expr::Call(_, _)));
}

#[test]
fn a_wrong_argument_count_is_a_parse_error() {
    for name in ["sort-by", "sort-by-descending"] {
        for args in ["()", "($ctx.xs)", "($ctx.xs, $f, 1)"] {
            let src = format!("{name}{args}");
            assert!(parse_program(&src).is_err(), "{src} should not parse");
        }
    }
}

#[test]
fn a_sort_name_passed_by_reference_is_a_parse_error() {
    for name in ["sort-by", "sort-by-descending"] {
        for src in [format!("${name}"), format!("map($ctx.xs, ${name})"), format!("@s=${name}\n$s")] {
            assert!(parse_program(&src).is_err(), "{src} should not parse");
        }
        // Nor bound: a special form cannot be shadowed.
        let src = format!("@{name}=(xs, f) => $xs\n{name}([2, 3, 1], (x) => $x)");
        let sorted = if name == "sort-by" { "ok [1,2,3]" } else { "ok [3,2,1]" };
        assert_eq!(kind(run(&Options::default(), "null", &src)), sorted);
    }
}

// Sorting -----------------------------------------------------------------------

#[test]
fn the_sorts_need_no_profile_and_are_stable_each_on_its_own_terms() {
    let rows = r#"[{"n": "a", "k": 2}, {"n": "b", "k": 1}, {"n": "c", "k": 2}]"#;
    let names = |form: &str| ok(&format!("map({form}({rows}, (r) => $r.k), (r) => $r.n)"));
    assert_eq!(names("sort-by"), r#"["b","a","c"]"#);
    assert_eq!(names("sort-by-descending"), r#"["a","c","b"]"#);
    assert_eq!(ok("sort-by([1.5, -2.0, 0.0], (x) => $x)"), "[-2.0,0.0,1.5]");
    assert_eq!(ok("sort-by([], (x) => $x.missing)"), "[]");
}

#[test]
fn string_keys_compare_by_code_point() {
    // U+FF5E before U+1F600, which UTF-16 code units would put the other way.
    assert_eq!(ok("sort-by([\"\u{1F600}\", \"\u{FF5E}\"], (x) => $x)"), "[\"\u{FF5E}\",\"\u{1F600}\"]");
    assert_eq!(
        ok(r#"sort-by(["éclair", "banana", "Zebra", "9", "eclair", "10", "apple", ""], (x) => $x)"#),
        r#"["","10","9","Zebra","apple","banana","eclair","éclair"]"#
    );
}

#[test]
fn the_first_element_that_fails_decides_the_error() {
    assert_eq!(kind(eval("sort-by(1, (x) => $x)")), "TypeMismatch");
    assert_eq!(kind(eval("sort-by([1], 2)")), "TypeMismatch");
    assert_eq!(kind(eval("sort-by([1], (x) => null)")), "TypeMismatch");
    assert_eq!(kind(eval("sort-by([1, 2.0], (x) => $x)")), "TypeMismatch");
    assert_eq!(kind(eval("sort-by([1, \"a\"], (x) => $x)")), "TypeMismatch");
    // The application of the second element fails before the key of the third is looked at.
    assert_eq!(kind(eval("sort-by([{k: 1}, {}, {k: null}], (r) => $r.k)")), "PathNotFound");
    assert_eq!(kind(eval("sort-by([{k: 1}, {k: null}, {}], (r) => $r.k)")), "TypeMismatch");
    let symbolic = Options { mode: Mode::Symbolic, arithmetic: false };
    assert_eq!(kind(run(&symbolic, "null", "sort-by([1, ?(\"s\")], (x) => $x)")), "NotConcrete");
    assert_eq!(kind(run(&symbolic, "null", "sort-by(?(\"s\"), (x) => $x)")), "NotConcrete");
    // The elements themselves are never inspected.
    assert!(run(&symbolic, "null", "sort-by([?(\"s\"), ?(\"t\")], (x) => 1)").is_ok());
}

/// No program can observe how many times the key function runs, so this one
/// is built as an AST whose key function emits a constraint each time, and
/// the emissions are counted before equal ones are made one.
#[test]
fn the_key_function_is_applied_once_per_element() {
    let lists: &[&[i64]] = &[
        &[],
        &[7],
        &[1, 2, 3, 4, 5, 6, 7, 8],
        &[8, 7, 6, 5, 4, 3, 2, 1],
        &[5, 1, 8, 3, 7, 2, 6, 4, 1, 5, 9, 0, 3],
        &[4, 4, 4, 4, 4, 4],
    ];
    for descending in [false, true] {
        for list in lists {
            let key_fn = Expr::Lambda(
                vec!["x".to_string()],
                Box::new(Expr::Emit(
                    Box::new(Expr::Constrain("seen".to_string(), vec![path("x")])),
                    Box::new(path("x")),
                )),
            );
            let items = Expr::ArrayLit(list.iter().map(|n| Expr::IntLit(*n)).collect());
            let prog = Program::ExpressionProgram(Expr::SortBy(descending, Box::new(items), Box::new(key_fn)));
            let options = Options { mode: Mode::Symbolic, arithmetic: false };
            let count = emitted_constraint_count(&options, &HashMap::new(), &Json::Null, &prog);
            assert_eq!(count, Ok(list.len()), "descending: {descending}, list: {list:?}");
        }
    }
}

// Analyses ----------------------------------------------------------------------

/// A sort is traversed as `map` is (reference.md §9): each analysis gives,
/// for a sort, what it gives for the `map` of the same two arguments, and
/// that is not empty.
#[test]
fn every_analysis_sees_inside_a_sort() {
    let mut libs: LibraryTable = HashMap::new();
    libs.insert(
        "lib".to_string(),
        parse_program("!constraint(\"deep\", sum(?ctx.d, 1))\n.b(action(\"on-click\", \"inner\", {}), $ctx.deep)").unwrap(),
    );
    let collection = "concat($ctx.rows, [?ctx.extra, ?(\"site\")])";
    let key_fn = "(r) => branch(.b(action(\"on-click\", \"go\", {})), eq($r, ?(\"other\")), \
                  lookup(import(\"lib\", {d: ctx(spec.d)}), constraint(\"shallow\", $r), floor($ctx.k)))";
    for name in ["sort-by", "sort-by-descending"] {
        let sorted = parse_program(&format!("{name}({collection}, {key_fn})")).unwrap();
        let mapped = parse_program(&format!("map({collection}, {key_fn})")).unwrap();

        macro_rules! same {
            ($analysis:expr) => {{
                let of_sort = $analysis(&sorted);
                assert_eq!(of_sort, $analysis(&mapped), "{name}: {}", stringify!($analysis));
                assert!(!of_sort.is_empty(), "{name}: {} is empty", stringify!($analysis));
            }};
        }
        same!(static_import_names);
        same!(|p| transitive_import_names(&libs, p));
        same!(static_action_keys);
        same!(|p| deep_action_keys(&libs, p));
        same!(context_holes);
        same!(|p| deep_context_holes(&libs, p));
        same!(context_reads);
        same!(constraint_kinds);
        same!(|p| deep_constraint_kinds(&libs, p));
        same!(symbol_sites);
        same!(symbol_demands);
        same!(|p| deep_symbol_demands(&libs, p));
        same!(arithmetic_ops);
        same!(|p| deep_arithmetic_ops(&libs, p));

        assert_eq!(symbol_sites(&sorted).len(), 2, "{name}: both allocation sites are numbered");
        assert!(context_reads(&sorted).contains(&vec!["rows".to_string()]));
        assert!(context_reads(&sorted).contains(&vec!["k".to_string()]));
        assert!(arithmetic_ops(&sorted).contains("floor"));
        assert!(deep_arithmetic_ops(&libs, &sorted).contains("sum"));
    }
    // A parameter of the key function shadows an arithmetic name inside it.
    let shadowed = parse_program("sort-by($ctx.rows, (round) => $round)").unwrap();
    assert!(arithmetic_ops(&shadowed).is_empty());
}

// round -------------------------------------------------------------------------

#[test]
fn round_is_the_tenth_arithmetic_name() {
    assert_eq!(ARITHMETIC_NAMES.len(), 10);
    assert!(ARITHMETIC_NAMES.contains(&"round"));
    assert!(!builtin_names().contains(&"round"));
    assert_eq!(kind(eval("round(2.5)")), "UnboundName");
    assert_eq!(arithmetic_ops(&parse_program("round(2.5)").unwrap()).len(), 1);
    assert_eq!(arithmetic_ops(&parse_program("map($ctx.xs, $round)").unwrap()).len(), 1);
    assert!(arithmetic_ops(&parse_program("@round=(x) => $x\nround(2.5)").unwrap()).is_empty());
}

#[test]
fn round_takes_a_tie_away_from_zero_and_stays_in_the_integer_range() {
    let round = |x: &str| kind(run(&ON, "null", &format!("round({x})")));
    assert_eq!(round("2.5"), "ok 3");
    assert_eq!(round("-2.5"), "ok -3");
    assert_eq!(round("0.5"), "ok 1");
    assert_eq!(round("-0.5"), "ok -1");
    assert_eq!(round("1.5"), "ok 2");
    assert_eq!(round("0.49999999999999994"), "ok 0");
    assert_eq!(round("-0.49999999999999994"), "ok 0");
    assert_eq!(round("7"), "ok 7");
    assert_eq!(round("-9223372036854775808"), "ok -9223372036854775808");
    // The largest double below 2^52 + 1/2, and a whole one beyond 2^53.
    assert_eq!(round("4503599627370495.5"), "ok 4503599627370496");
    assert_eq!(round("9007199254740993.0"), "ok 9007199254740992");
    assert_eq!(round("-9223372036854775808.0"), "ok -9223372036854775808");
    assert_eq!(round("9223372036854774784.0"), "ok 9223372036854774784");
    assert_eq!(round("9223372036854775808.0"), "NotRepresentable");
    assert_eq!(round("-9223372036854777856.0"), "NotRepresentable");
    assert_eq!(round("1e300"), "NotRepresentable");
    assert_eq!(round("\"2.5\""), "TypeMismatch");
    assert_eq!(round("[2.5]"), "TypeMismatch");
    assert_eq!(kind(run(&ON, "null", "round(1.0, 2.0)")), "TypeMismatch");
}

#[test]
fn round_builds_a_term_over_a_symbol_and_a_seeded_one_is_accepted() {
    let term = r##"{"$term":"round","arguments":[{"$sym":"#0:\"s\"","path":[]}]}"##;
    let out = run(&SYMBOLIC_ON, "null", "round(?(\"s\"))").unwrap();
    let envelope = parse(&out).unwrap();
    let Json::Object(fields) = envelope else { panic!("not an envelope: {out}") };
    assert_eq!(stringify(&fields["root"]), term);

    let seeded = format!(r#"{{"t": {term}}}"#);
    let out = run(&SYMBOLIC_ON, &seeded, "sum($ctx.t, 1)").unwrap();
    assert!(out.contains(r#""$term":"sum""#) && out.contains(r#""$term":"round""#), "{out}");
    // A term of numbers only is one a call would have computed.
    let computed = r#"{"t": {"$term": "round", "arguments": [2.5]}}"#;
    assert_eq!(kind(run(&SYMBOLIC_ON, computed, "1")), "TypeMismatch");
    let two = r##"{"t": {"$term": "round", "arguments": [{"$sym": "#0:\"s\"", "path": []}, 1]}}"##;
    assert_eq!(kind(run(&SYMBOLIC_ON, two, "1")), "TypeMismatch");
}

// format-number -----------------------------------------------------------------

#[test]
fn format_number_is_an_ordinary_builtin_of_every_profile() {
    assert!(builtin_names().contains(&"format-number"));
    assert_eq!(ok("format-number(1234567.891, 2, \",\")"), "\"1,234,567.89\"");
    // Passed by reference, and shadowed.
    assert_eq!(ok("@f=$format-number\n$f(1234, 2, \",\")"), "\"1,234.00\"");
    assert_eq!(ok("@format-number=(x, d, g) => \"mine\"\nformat-number(1, 2, \"\")"), "\"mine\"");
    assert_eq!(kind(eval("format-number(1, 2)")), "TypeMismatch");
    assert_eq!(kind(eval("format-number(1, 2, \"\", 4)")), "TypeMismatch");
}

#[test]
fn format_number_rounds_the_exact_value() {
    let f = |x: &str, decimals: u32, group: &str| ok(&format!("format-number({x}, {decimals}, {group:?})"));
    assert_eq!(f("2.5", 0, ""), "\"3\"");
    assert_eq!(f("-2.5", 0, ""), "\"-3\"");
    assert_eq!(f("0.125", 2, ""), "\"0.13\"");
    assert_eq!(f("1.005", 2, ""), "\"1.00\"");
    assert_eq!(f("2.675", 2, ""), "\"2.67\"");
    assert_eq!(f("999.995", 2, ""), "\"1000.00\"");
    assert_eq!(f("-0.001", 2, ""), "\"0.00\"");
    assert_eq!(f("-0.005", 2, ""), "\"-0.01\"");
    assert_eq!(f("0.0", 0, ","), "\"0\"");
    assert_eq!(f("0", 3, ","), "\"0.000\"");
    assert_eq!(f("1e21", 0, ","), "\"1,000,000,000,000,000,000,000\"");
    assert_eq!(f("1e23", 0, ""), "\"99999999999999991611392\"");
    assert_eq!(f("0.1", 20, ""), "\"0.10000000000000000555\"");
    assert_eq!(f("-1234567", 0, ","), "\"-1,234,567\"");
    assert_eq!(f("123", 0, ","), "\"123\"");
    assert_eq!(f("1234", 1, "' '"), "\"1' '234.0\"");
    assert_eq!(f("-9223372036854775808", 0, "_"), "\"-9_223_372_036_854_775_808\"");
    assert_eq!(f("9223372036854775807", 20, ""), "\"9223372036854775807.00000000000000000000\"");
}

#[test]
fn format_number_writes_every_double_without_an_exponent() {
    let f = |x: &str, decimals: u32| ok(&format!("format-number({x}, {decimals}, \"\")"));
    // The smallest positive double, 2^-1074: nothing at 20 decimals.
    assert_eq!(f("5e-324", 20), "\"0.00000000000000000000\"");
    assert_eq!(f("-5e-324", 20), "\"0.00000000000000000000\"");
    // Either side of half a unit of the last digit asked for.
    assert_eq!(f("6e-21", 20), "\"0.00000000000000000001\"");
    assert_eq!(f("4e-21", 20), "\"0.00000000000000000000\"");
    // The largest double, 2^1024 - 2^971: 309 digits, the exact ones.
    let largest = f("1.7976931348623157e308", 0);
    assert_eq!(largest.len(), 309 + 2);
    assert!(largest.starts_with("\"17976931348623157081452742373170435679807056752584499659891747680315726078002853876058955"));
    assert!(largest.ends_with("4124858368\""));
    let with_decimals = f("-1.7976931348623157e308", 20);
    assert_eq!(with_decimals.len(), 1 + 309 + 1 + 20 + 2);
    assert!(with_decimals.starts_with("\"-1797693134862315708145274237317043567980705675258449965989174768"));
    assert!(with_decimals.ends_with("4124858368.00000000000000000000\""));
    // 2^53 + 2, where an `f64` holds even numbers only.
    assert_eq!(f("9007199254740994.0", 3), "\"9007199254740994.000\"");
}

#[test]
fn format_number_examines_its_arguments_left_to_right() {
    assert_eq!(kind(eval("format-number(\"1\", 2, \"\")")), "TypeMismatch");
    assert_eq!(kind(eval("format-number(null, 99, 1)")), "TypeMismatch");
    assert_eq!(kind(eval("format-number(1, 2.0, \"\")")), "TypeMismatch");
    assert_eq!(kind(eval("format-number(1, -1, \"\")")), "TypeMismatch");
    assert_eq!(kind(eval("format-number(1, 21, \"\")")), "TypeMismatch");
    assert_eq!(kind(eval("format-number(1, 20, 0)")), "TypeMismatch");
    assert_eq!(kind(eval("format-number(1, 20, \"\")")), "ok \"1.00000000000000000000\"");
    let symbolic = Options { mode: Mode::Symbolic, arithmetic: false };
    let f = |args: &str| kind(run(&symbolic, "null", &format!("@s=?(\"s\")\nformat-number({args})")));
    assert_eq!(f("$s, 2, \"\""), "NotConcrete");
    assert_eq!(f("$s, 99, 1"), "NotConcrete");
    assert_eq!(f("\"x\", $s, \"\""), "TypeMismatch");
    assert_eq!(f("1, $s, 1"), "NotConcrete");
    assert_eq!(f("1, 99, $s"), "TypeMismatch");
    assert_eq!(f("1, 2, $s"), "NotConcrete");
}
