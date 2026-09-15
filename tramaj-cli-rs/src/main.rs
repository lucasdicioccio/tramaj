//! Standalone CLI over the `tramaj-rs` crate's parser/eval/analysis core.
//! Rust port of `tramaj-cli/src/Main.purs`; see that file for the exact
//! grammar and JSON shapes this mirrors. Two commands are supported:
//!
//! * `tramaj-cli-rs [evaluate] [--lib name=path ...] [--mode concrete|symbolic]
//!   <template-file> <context-json-file>`
//!
//! * `tramaj-cli-rs analyze <subcommand> <template-file> [--lib name=path ...]`
//!
//! Any number of `--lib name=path` flags register a host-supplied
//! `LibraryTable`, letting the template use `import(name, ...)` against files
//! on disk.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::process::ExitCode;

use serde_json::{json, Value};

use tramaj_rs::analysis::{
    deep_action_keys, deep_constraint_kinds, deep_context_holes, deep_symbol_demands,
    program_card, symbol_sites, transitive_import_names, type_declarations, type_params,
    unsupplied_params, unsupplied_type_params, Card, ProgramKind,
};
use tramaj_rs::ast::Program;
use tramaj_rs::eval::{run_program, LibraryTable, Mode};
use tramaj_rs::parser::parse_program;
use tramaj_rs::types::{
    canonical_id, check_type_param_collisions, deep_type_constraints, deep_type_references,
    ResolvedConstraintArg, TypeError,
};

#[derive(Debug, Clone)]
enum Command {
    Evaluate {
        lib_specs: Vec<(String, String)>,
        mode: Mode,
        template_path: String,
        context_path: String,
    },
    Analyze {
        lib_specs: Vec<(String, String)>,
        subcommand: AnalyzeSubcommand,
        template_path: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AnalyzeSubcommand {
    Imports,
    Actions,
    Holes,
    Unsupplied,
    Constraints,
    Symbols,
    Types,
    Card,
    All,
}

const USAGE: &str = "usage: tramaj-cli-rs [evaluate] [--lib name=path ...] [--mode concrete|symbolic] <template-file> <context-json-file>\n       tramaj-cli-rs analyze <imports|actions|holes|unsupplied|constraints|symbols|types|card|all> <template-file> [--lib name=path ...]";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match parse_args(&args) {
        Err(err) => die(&format!("{err}\n{USAGE}")),
        Ok(Command::Evaluate {
            lib_specs,
            mode,
            template_path,
            context_path,
        }) => run_evaluate(&lib_specs, mode, &template_path, &context_path),
        Ok(Command::Analyze {
            lib_specs,
            subcommand,
            template_path,
        }) => run_analyze(&lib_specs, subcommand, &template_path),
    }
}

/// Splits `argv` into an optional command (`evaluate` or `analyze`), any
/// number of `--lib name=path` pairs, an optional `--mode`, and the
/// remaining positional arguments. The bare legacy form (no command word) is
/// still accepted and means `evaluate`.
fn parse_args(args: &[String]) -> Result<Command, String> {
    match args.first().map(String::as_str) {
        Some("analyze") => parse_analyze(&args[1..]),
        Some("evaluate") => parse_evaluate(&args[1..]),
        _ => parse_evaluate(args),
    }
}

fn parse_evaluate(args: &[String]) -> Result<Command, String> {
    let g = parse_global_options(true, args)?;
    match g.positional.as_slice() {
        [template_path, context_path] => Ok(Command::Evaluate {
            lib_specs: g.lib_specs,
            mode: g.mode,
            template_path: template_path.clone(),
            context_path: context_path.clone(),
        }),
        _ => Err(format!(
            "evaluate expects <template-file> <context-json-file>, got: {} positional argument(s)",
            g.positional.len()
        )),
    }
}

fn parse_analyze(args: &[String]) -> Result<Command, String> {
    let g = parse_global_options(false, args)?;
    match g.positional.as_slice() {
        [sub, template_path] => {
            let subcommand = parse_subcommand(sub)?;
            Ok(Command::Analyze {
                lib_specs: g.lib_specs,
                subcommand,
                template_path: template_path.clone(),
            })
        }
        _ => Err(format!(
            "analyze expects <subcommand> <template-file>, got: {} positional argument(s)",
            g.positional.len()
        )),
    }
}

fn parse_subcommand(s: &str) -> Result<AnalyzeSubcommand, String> {
    match s {
        "imports" => Ok(AnalyzeSubcommand::Imports),
        "actions" => Ok(AnalyzeSubcommand::Actions),
        "holes" => Ok(AnalyzeSubcommand::Holes),
        "unsupplied" => Ok(AnalyzeSubcommand::Unsupplied),
        "constraints" => Ok(AnalyzeSubcommand::Constraints),
        "symbols" => Ok(AnalyzeSubcommand::Symbols),
        "types" => Ok(AnalyzeSubcommand::Types),
        "card" => Ok(AnalyzeSubcommand::Card),
        "all" => Ok(AnalyzeSubcommand::All),
        other => Err(format!("unknown analyze subcommand: {other}")),
    }
}

struct GlobalParseResult {
    lib_specs: Vec<(String, String)>,
    mode: Mode,
    positional: Vec<String>,
}

/// Parses `--lib name=path` pairs, an optional `--mode` (only when
/// `mode_allowed` is true), and collects every other token as positional.
fn parse_global_options(mode_allowed: bool, args: &[String]) -> Result<GlobalParseResult, String> {
    let mut lib_specs = Vec::new();
    let mut mode = Mode::Concrete;
    let mut positional = Vec::new();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--lib" => {
                let spec = args
                    .get(i + 1)
                    .ok_or_else(|| "--lib expects a following name=path argument".to_string())?;
                match split_on_first(spec, '=') {
                    None => return Err(format!("--lib expects name=path, got: {spec}")),
                    Some((name, path)) => {
                        lib_specs.push((name, path));
                        i += 2;
                    }
                }
            }
            "--mode" if !mode_allowed => {
                return Err("--mode is not valid for the analyze command".to_string());
            }
            "--mode" => {
                let val = args
                    .get(i + 1)
                    .ok_or_else(|| "--mode expects a following concrete|symbolic argument".to_string())?;
                match val.as_str() {
                    "concrete" => {
                        mode = Mode::Concrete;
                        i += 2;
                    }
                    "symbolic" => {
                        mode = Mode::Symbolic;
                        i += 2;
                    }
                    other => return Err(format!("--mode expects concrete|symbolic, got: {other}")),
                }
            }
            other => {
                positional.push(other.to_string());
                i += 1;
            }
        }
    }

    Ok(GlobalParseResult {
        lib_specs,
        mode,
        positional,
    })
}

fn split_on_first(s: &str, sep: char) -> Option<(String, String)> {
    let idx = s.find(sep)?;
    let (a, b) = s.split_at(idx);
    Some((a.to_string(), b[sep.len_utf8()..].to_string()))
}

fn run_evaluate(lib_specs: &[(String, String)], mode: Mode, template_path: &str, context_path: &str) -> ExitCode {
    let libs = match load_libraries(lib_specs) {
        Err(err) => return die(&err),
        Ok(libs) => libs,
    };

    let template_src = match fs::read_to_string(template_path) {
        Ok(s) => s,
        Err(err) => return die(&format!("{err}")),
    };
    let ctx_src = match fs::read_to_string(context_path) {
        Ok(s) => s,
        Err(err) => return die(&format!("{err}")),
    };

    let ctx_json: Value = match serde_json::from_str(&ctx_src) {
        Ok(v) => v,
        Err(err) => return die(&format!("invalid JSON context ({context_path}): {err}")),
    };

    let program = match parse_program(&template_src) {
        Ok(p) => p,
        Err(err) => return die(&format!("parse error ({template_path}): {err}")),
    };

    match run_program(mode, &libs, &ctx_json, &program) {
        Ok(result) => {
            println!("{}", serde_json::to_string(&result).expect("serializing evaluate output"));
            ExitCode::SUCCESS
        }
        Err(err) => die(&format!("eval error: {err}")),
    }
}

fn run_analyze(lib_specs: &[(String, String)], subcommand: AnalyzeSubcommand, template_path: &str) -> ExitCode {
    let libs = match load_libraries(lib_specs) {
        Err(err) => return die(&err),
        Ok(libs) => libs,
    };

    let template_src = match fs::read_to_string(template_path) {
        Ok(s) => s,
        Err(err) => return die(&format!("{err}")),
    };

    let program = match parse_program(&template_src) {
        Ok(p) => p,
        Err(err) => return die(&format!("parse error ({template_path}): {err}")),
    };

    if let Err(collision_err) = check_type_param_collisions(&program) {
        return die(&format!("type error: {collision_err}"));
    }

    match analyze_to_json(&libs, &program, subcommand) {
        Ok(result) => {
            println!("{}", serde_json::to_string(&result).expect("serializing analyze output"));
            ExitCode::SUCCESS
        }
        Err(type_err) => die(&format!("type error: {type_err}")),
    }
}

fn analyze_to_json(libs: &LibraryTable, prog: &Program, sub: AnalyzeSubcommand) -> Result<Value, TypeError> {
    match sub {
        AnalyzeSubcommand::Imports => Ok(string_set_to_json(&transitive_import_names(libs, prog))),
        AnalyzeSubcommand::Actions => Ok(string_set_to_json(&deep_action_keys(libs, prog))),
        AnalyzeSubcommand::Holes => Ok(path_set_to_json(&deep_context_holes(libs, prog))),
        AnalyzeSubcommand::Unsupplied => Ok(unsupplied_to_json(
            &unsupplied_params(libs, prog),
            &unsupplied_type_params(libs, prog),
        )),
        AnalyzeSubcommand::Constraints => constraints_block(libs, prog),
        AnalyzeSubcommand::Symbols => Ok(symbols_block(libs, prog)),
        AnalyzeSubcommand::Types => types_block(libs, prog),
        AnalyzeSubcommand::Card => Ok(card_to_json(&program_card(libs, prog))),
        AnalyzeSubcommand::All => {
            let constraints = constraints_block(libs, prog)?;
            let types = types_block(libs, prog)?;
            Ok(json!({
                "imports": string_set_to_json(&transitive_import_names(libs, prog)),
                "actions": string_set_to_json(&deep_action_keys(libs, prog)),
                "holes": path_set_to_json(&deep_context_holes(libs, prog)),
                "unsupplied": unsupplied_to_json(
                    &unsupplied_params(libs, prog),
                    &unsupplied_type_params(libs, prog),
                ),
                "constraints": constraints,
                "symbols": symbols_block(libs, prog),
                "types": types,
            }))
        }
    }
}

fn constraints_block(libs: &LibraryTable, prog: &Program) -> Result<Value, TypeError> {
    let kinds = string_set_to_json(&deep_constraint_kinds(libs, prog));
    let constraints = type_constraints_to_json(&deep_type_constraints(libs, prog)?);
    Ok(json!({ "kinds": kinds, "typeConstraints": constraints }))
}

fn symbols_block(libs: &LibraryTable, prog: &Program) -> Value {
    json!({
        "sites": int_set_to_json(&symbol_sites(prog)),
        "demands": path_set_to_json(&deep_symbol_demands(libs, prog)),
    })
}

fn types_block(libs: &LibraryTable, prog: &Program) -> Result<Value, TypeError> {
    let references = string_set_to_json(&deep_type_references(libs, prog)?);
    let constraints = type_constraints_to_json(&deep_type_constraints(libs, prog)?);
    Ok(json!({
        "declarations": string_set_to_json(&type_declarations(prog)),
        "params": path_set_to_json(&type_params(prog)),
        "references": references,
        "constraints": constraints,
    }))
}

/// Reads and parses each `--lib name=path` file into a `LibraryTable`.
fn load_libraries(specs: &[(String, String)]) -> Result<LibraryTable, String> {
    let mut acc: LibraryTable = HashMap::new();
    for (name, path) in specs {
        let src = fs::read_to_string(path).map_err(|err| format!("library \"{name}\" ({path}): {err}"))?;
        match parse_program(&src) {
            Ok(lib_prog) => {
                acc.insert(name.clone(), lib_prog);
            }
            Err(err) => return Err(format!("library \"{name}\" ({path}): {err}")),
        }
    }
    Ok(acc)
}

// JSON helpers ----------------------------------------------------------------

fn string_set_to_json(set: &HashSet<String>) -> Value {
    let mut xs: Vec<&String> = set.iter().collect();
    xs.sort();
    Value::Array(xs.into_iter().map(|s| Value::String(s.clone())).collect())
}

fn path_set_to_json(set: &HashSet<Vec<String>>) -> Value {
    let mut xs: Vec<&Vec<String>> = set.iter().collect();
    xs.sort();
    Value::Array(
        xs.into_iter()
            .map(|path| Value::Array(path.iter().map(|s| Value::String(s.clone())).collect()))
            .collect(),
    )
}

fn int_set_to_json(set: &HashSet<usize>) -> Value {
    let mut xs: Vec<&usize> = set.iter().collect();
    xs.sort();
    Value::Array(xs.into_iter().map(|n| Value::Number((*n).into())).collect())
}

fn unsupplied_to_json(
    value_params: &[(String, HashSet<Vec<String>>)],
    type_params: &[(String, HashSet<Vec<String>>)],
) -> Value {
    Value::Array(
        value_params
            .iter()
            .zip(type_params.iter())
            .map(|((name, v_missing), (_, t_missing))| {
                json!({
                    "name": name,
                    "valueParams": path_set_to_json(v_missing),
                    "typeParams": path_set_to_json(t_missing),
                })
            })
            .collect(),
    )
}

fn type_constraints_to_json(constraints: &[(String, Vec<ResolvedConstraintArg>)]) -> Value {
    Value::Array(
        constraints
            .iter()
            .map(|(name, args)| {
                json!({
                    "name": name,
                    "arguments": args.iter().map(resolved_constraint_arg_to_json).collect::<Vec<_>>(),
                })
            })
            .collect(),
    )
}

fn resolved_constraint_arg_to_json(arg: &ResolvedConstraintArg) -> Value {
    match arg {
        ResolvedConstraintArg::Type(rt) => json!({ "$type": canonical_id(rt) }),
        ResolvedConstraintArg::ScalarStr(s) => Value::String(s.clone()),
        ResolvedConstraintArg::ScalarNum(n) => {
            serde_json::Number::from_f64(*n).map(Value::Number).unwrap_or(Value::Null)
        }
        ResolvedConstraintArg::ScalarBool(b) => Value::Bool(*b),
        ResolvedConstraintArg::ScalarNull => Value::Null,
    }
}

fn card_to_json(card: &Card) -> Value {
    let produces = match card.produces {
        ProgramKind::ProducesDocument => "document",
        ProgramKind::ProducesValue => "value",
    };
    let unsupplied = Value::Array(
        card.unsupplied
            .iter()
            .map(|(name, missing)| json!({ "name": name, "params": path_set_to_json(missing) }))
            .collect(),
    );
    json!({
        "produces": produces,
        "requires": path_set_to_json(&card.requires),
        "imports": string_set_to_json(&card.imports),
        "emits": string_set_to_json(&card.emits),
        "unsupplied": unsupplied,
    })
}

fn die(msg: &str) -> ExitCode {
    eprintln!("{msg}");
    ExitCode::FAILURE
}
