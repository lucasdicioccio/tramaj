//! What the shared corpus has no shape for: the per-evaluation option and
//! its default, a library running with the profile of the evaluation that
//! reached it, a seeded term with and without the profile, the two
//! arithmetic analyses, and integer arithmetic at the ends of the 64-bit
//! range (`specs/reference.md` §3, §9, §11, §13; `specs/v3-symbols.md` §1.9,
//! §5.3, §5.4).

use std::collections::{HashMap, HashSet};

use tramaj_rs::analysis::{arithmetic_ops, deep_arithmetic_ops, ARITHMETIC_NAMES};
use tramaj_rs::eval::{run_program, run_program_with, EvalError, LibraryTable, Mode, Options};
use tramaj_rs::json::{parse, stringify, Json};
use tramaj_rs::parser::parse_program;

const ON: Options = Options { mode: Mode::Concrete, arithmetic: true };
const SYMBOLIC_ON: Options = Options { mode: Mode::Symbolic, arithmetic: true };

fn run(options: &Options, libs: &LibraryTable, ctx: &str, src: &str) -> Result<String, EvalError> {
    let prog = parse_program(src).unwrap_or_else(|e| panic!("parse error in {src:?}: {e}"));
    let ctx = parse(ctx).expect("context is JSON");
    run_program_with(options, libs, &ctx, &prog).map(|j| stringify(&j))
}

fn eval(src: &str) -> Result<String, EvalError> {
    run(&ON, &HashMap::new(), "null", src)
}

fn kind(r: Result<String, EvalError>) -> String {
    match r {
        Ok(v) => format!("ok {v}"),
        Err(e) => e.to_string().split_whitespace().next().unwrap_or("").to_string(),
    }
}

fn names(xs: &[&str]) -> HashSet<String> {
    xs.iter().map(|s| s.to_string()).collect()
}

#[test]
fn the_profile_is_off_by_default() {
    assert_eq!(Options::default(), Options { mode: Mode::Concrete, arithmetic: false });
    let prog = parse_program("sum(1, 2)").unwrap();
    let r = run_program(Mode::Concrete, &HashMap::new(), &Json::Null, &prog);
    assert_eq!(r, Err(EvalError::UnboundName("sum".to_string())));
    for name in ARITHMETIC_NAMES {
        let src = format!("${name}");
        assert_eq!(
            kind(run(&Options::default(), &HashMap::new(), "null", &src)),
            "UnboundName",
            "{name} should be unbound without the profile"
        );
        assert_eq!(kind(eval(&src)), "TypeMismatch", "{name} is a builtin with the profile");
    }
}

#[test]
fn the_profile_has_nine_names_and_round_is_not_one() {
    assert_eq!(ARITHMETIC_NAMES.len(), 9);
    assert_eq!(kind(eval("round(2.5)")), "UnboundName");
    assert_eq!(arithmetic_ops(&parse_program("round(2.5)").unwrap()), names(&[]));
}

#[test]
fn a_library_runs_with_the_profile_of_the_evaluation() {
    let mut libs: LibraryTable = HashMap::new();
    libs.insert("lib".to_string(), parse_program("@total=sum($ctx.a, 1)\n$total").unwrap());
    let src = "@l=import(\"lib\", {a: 41})\n$l.vals.total";
    assert_eq!(run(&ON, &libs, "null", src), Ok("42".to_string()));
    let off = run(&Options::default(), &libs, "null", src);
    assert_eq!(
        off,
        Err(EvalError::InLibrary(
            "lib".to_string(),
            Box::new(EvalError::UnboundName("sum".to_string()))
        ))
    );
}

#[test]
fn a_number_keeps_its_type_from_the_context_to_the_output() {
    let none = HashMap::new();
    assert_eq!(run(&ON, &none, r#"{"n": 3}"#, "$ctx.n"), Ok("3".to_string()));
    assert_eq!(run(&ON, &none, r#"{"n": 3.0}"#, "$ctx.n"), Ok("3.0".to_string()));
    assert_eq!(run(&ON, &none, r#"{"n": 3e0}"#, "$ctx.n"), Ok("3.0".to_string()));
    assert_eq!(run(&ON, &none, r#"{"n": -0.0}"#, "$ctx.n"), Ok("0.0".to_string()));
    assert_eq!(run(&ON, &none, r#"{"n": -0}"#, "$ctx.n"), Ok("0".to_string()));
    assert_eq!(run(&ON, &none, r#"{"n": 3.0}"#, "eq($ctx.n, 3)"), Ok("false".to_string()));
    assert_eq!(run(&ON, &none, r#"{"n": 3.0}"#, "str($ctx.n)"), Ok("\"3.0\"".to_string()));
    assert_eq!(
        run(&ON, &none, r#"{"n": 9223372036854775807}"#, "$ctx.n"),
        Ok("9223372036854775807".to_string())
    );
}

#[test]
fn a_context_number_that_is_not_a_value_is_refused_unread() {
    let none = HashMap::new();
    for ctx in [
        r#"{"deep": [{"n": 9223372036854775808}]}"#,
        r#"{"deep": [{"n": -9223372036854775809}]}"#,
        r#"{"deep": [{"n": 1e400}]}"#,
    ] {
        assert_eq!(kind(run(&Options::default(), &none, ctx, "1")), "TypeMismatch", "{ctx}");
    }
}

#[test]
fn a_literal_outside_the_range_does_not_parse() {
    assert!(parse_program("9223372036854775807").is_ok());
    assert!(parse_program("-9223372036854775808").is_ok());
    assert!(parse_program("9223372036854775808").is_err());
    assert!(parse_program("-9223372036854775809").is_err());
    assert!(parse_program("1e400").is_err());
    assert!(parse_program("{\"$term\": 1}").is_err());
}

#[test]
fn integer_arithmetic_is_exact_or_an_error_at_the_ends_of_the_range() {
    assert_eq!(eval("sum(9223372036854775806, 1)"), Ok("9223372036854775807".to_string()));
    assert_eq!(kind(eval("sum(9223372036854775807, 1)")), "NotRepresentable");
    assert_eq!(kind(eval("sum(9223372036854775807, 1, -1)")), "NotRepresentable");
    assert_eq!(kind(eval("product(4294967296, 4294967296, 0)")), "NotRepresentable");
    assert_eq!(eval("product(3037000499, 3037000499)"), Ok("9223372030926249001".to_string()));
    assert_eq!(kind(eval("product(3037000500, 3037000500)")), "NotRepresentable");
    assert_eq!(kind(eval("negate(-9223372036854775808)")), "NotRepresentable");
    assert_eq!(kind(eval("floor-quotient(-9223372036854775808, -1)")), "NotRepresentable");
    assert_eq!(eval("modulo(-9223372036854775808, -1)"), Ok("0".to_string()));
    assert_eq!(eval("floor-quotient(-7, 2)"), Ok("-4".to_string()));
    assert_eq!(eval("floor-quotient(7, -2)"), Ok("-4".to_string()));
    assert_eq!(eval("modulo(-7, 2)"), Ok("1".to_string()));
    assert_eq!(eval("modulo(7, -2)"), Ok("-1".to_string()));
    assert_eq!(kind(eval("modulo(1, 0)")), "NotRepresentable");
    assert_eq!(kind(eval("floor-quotient(1, 0)")), "NotRepresentable");
}

#[test]
fn the_conversions_hold_the_range() {
    assert_eq!(eval("floor(-0.5)"), Ok("-1".to_string()));
    assert_eq!(eval("floor(1e16)"), Ok("10000000000000000".to_string()));
    assert_eq!(eval("floor(-9223372036854775808.0)"), Ok("-9223372036854775808".to_string()));
    assert_eq!(kind(eval("floor(9223372036854775808.0)")), "NotRepresentable");
    assert_eq!(kind(eval("floor(1e19)")), "NotRepresentable");
    assert_eq!(eval("real(9007199254740993)"), Ok("9007199254740992.0".to_string()));
    assert_eq!(eval("real(3)"), Ok("3.0".to_string()));
}

#[test]
fn floats_are_one_rounded_operation_at_a_time_without_a_negative_zero() {
    assert_eq!(eval("sum(0.1, 0.2, 0.3)"), Ok("0.6000000000000001".to_string()));
    assert_eq!(eval("product(49.0, inverse(49.0))"), Ok("0.9999999999999999".to_string()));
    assert_eq!(eval("quotient(49.0, 49.0)"), Ok("1.0".to_string()));
    assert_eq!(eval("negate(0.0)"), Ok("0.0".to_string()));
    assert_eq!(eval("product(-1.0, 0.0)"), Ok("0.0".to_string()));
    assert_eq!(kind(eval("sum(1e308, 1e308)")), "NotRepresentable");
    assert_eq!(kind(eval("inverse(0.0)")), "NotRepresentable");
    assert_eq!(kind(eval("sum(1e308, 1e308, \"a\")")), "TypeMismatch");
    assert_eq!(kind(eval("sum(1, 1.5)")), "TypeMismatch");
    assert_eq!(kind(eval("sum([])")), "TypeMismatch");
    assert_eq!(kind(eval("negate([1])")), "TypeMismatch");
    assert_eq!(kind(eval("gt(1.5, 0)")), "TypeMismatch");
}

#[test]
fn a_symbol_operand_builds_a_term_with_the_operands_as_written() {
    let none = HashMap::new();
    let out = run(&SYMBOLIC_ON, &none, "{}", "sum(1, [?ctx.s, 2])").unwrap();
    let v = parse(&out).unwrap();
    let Json::Object(envelope) = v else { panic!("not an envelope: {out}") };
    assert_eq!(
        stringify(&envelope["root"]),
        r##"{"$term":"sum","arguments":[1,{"$sym":"#ctx.s","path":[]},2]}"##
    );
    assert_eq!(kind(run(&SYMBOLIC_ON, &none, "{}", "@t=sum(?ctx.s, 1)\n$t.field")), "TypeMismatch");
    assert_eq!(kind(run(&SYMBOLIC_ON, &none, "{}", "str(sum(?ctx.s, 1))")), "NotConcrete");
    assert_eq!(kind(run(&SYMBOLIC_ON, &none, "{}", "sum(1, ?ctx.s, 2.0)")), "TypeMismatch");
}

#[test]
fn a_seeded_term_needs_symbolic_mode_and_the_profile() {
    let none = HashMap::new();
    let ctx = r##"{"t": {"$term": "sum", "arguments": [1, {"$sym": "#0:\"s\"", "path": []}]}}"##;
    let term = r##"{"$term":"sum","arguments":[1,{"$sym":"#0:\"s\"","path":[]}]}"##;
    let out = run(&SYMBOLIC_ON, &none, ctx, "$ctx.t").unwrap();
    let Json::Object(envelope) = parse(&out).unwrap() else { panic!("not an envelope: {out}") };
    assert_eq!(stringify(&envelope["root"]), term);

    let symbolic_off = Options { mode: Mode::Symbolic, arithmetic: false };
    assert_eq!(kind(run(&symbolic_off, &none, ctx, "1")), "TypeMismatch");
    assert_eq!(kind(run(&ON, &none, ctx, "1")), "TypeMismatch");
    // All numbers: a call would have computed, so this is not a term.
    let all_numbers = r#"{"t": {"$term": "sum", "arguments": [1, 2]}}"#;
    assert_eq!(kind(run(&SYMBOLIC_ON, &none, all_numbers, "1")), "TypeMismatch");
    let unknown = r##"{"t": {"$term": "round", "arguments": [{"$sym": "#0:\"s\"", "path": []}]}}"##;
    assert_eq!(kind(run(&SYMBOLIC_ON, &none, unknown, "1")), "TypeMismatch");
}

#[test]
fn arithmetic_ops_is_scope_aware_and_follows_imports() {
    let ops = |src: &str| arithmetic_ops(&parse_program(src).unwrap());
    assert_eq!(ops("sum(1, floor(2.5))"), names(&["sum", "floor"]));
    assert_eq!(ops("fold($ctx.xs, 0, $sum)"), names(&["sum"]));
    assert_eq!(ops("@sum=(a, b) => $a\nsum(1, 2)"), names(&[]));
    assert_eq!(ops("@sum=sum(1, 2)\n$sum"), names(&["sum"]));
    assert_eq!(ops("map($ctx.xs, (negate) => $negate)"), names(&[]));
    assert_eq!(ops("@{product}=$ctx\nproduct(1, 2)"), names(&[]));
    assert_eq!(ops("cardinality($ctx.xs)"), names(&[]));

    let mut libs: LibraryTable = HashMap::new();
    libs.insert("lib".to_string(), parse_program("modulo($ctx.a, 2)").unwrap());
    let root = parse_program("@sum=1\n@l=import(\"lib\", {a: 1})\n.p(real(1), $l.rendered)").unwrap();
    assert_eq!(arithmetic_ops(&root), names(&["real"]));
    assert_eq!(deep_arithmetic_ops(&libs, &root), names(&["real", "modulo"]));
}
