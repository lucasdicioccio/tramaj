//! Rust port of the Tramaj language (`specs/reference.md`, `specs/v3-symbols.md`,
//! `specs/v4-types.md`, `specs/node-json.md`). Hand-written, not generated from
//! `tramaj/` or `tramaj-hs/`; agreement with those two implementations is
//! enforced by the shared corpus at `corpus/cases/` (see `tests/corpus.rs`),
//! the same way `tramaj-hs` is checked against `tramaj`.
//!
//! **Numbers.** An integer and a float are two types (`specs/reference.md`
//! §3). The integer range of this port is the signed 64-bit one, `-2^63` to
//! `2^63 - 1` (§13): a literal, a context number or an arithmetic result
//! outside it is refused, never rounded. JSON goes in and out as
//! [`json::Json`], which keeps `3` and `3.0` apart; read text with
//! [`json::parse`] and write it with [`json::stringify`].
//!
//! **Arithmetic.** The arithmetic profile (§11) is an option of each
//! evaluation, off by default: [`eval::Options`] with
//! [`eval::run_program_with`] or [`eval::eval_program_with`] turns it on. It
//! has the nine names of [`analysis::ARITHMETIC_NAMES`]; `round` is not
//! provided yet. [`analysis::deep_arithmetic_ops`] tells a host that leaves
//! the profile off which of them a program references.
//!
//! Module layout mirrors `tramaj-hs/src/Tramaj/*.hs` one-to-one so the two
//! sources stay easy to diff against each other during the port.

pub mod analysis;
pub mod ast;
pub mod eval;
pub mod json;
pub mod node;
pub mod parser;
pub mod types;
