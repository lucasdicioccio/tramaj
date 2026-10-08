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
//! has the ten names of [`analysis::ARITHMETIC_NAMES`], `round` included.
//! [`analysis::deep_arithmetic_ops`] tells a host that leaves the profile
//! off which of them a program references.
//!
//! **Sorting and number formatting.** `sort-by(list, fn)` and
//! `sort-by-descending(list, fn)` are two special forms over one
//! constructor, [`ast::Expr::SortBy`]: a stable sort by the key a function
//! gives each element, the keys being all integers, all floats or all
//! strings, compared by code point (§11, *Sorting*). `format-number(x,
//! decimals, group)` is an ordinary builtin that writes a number in
//! positional decimal notation, rounding its exact value with a tie going
//! away from zero (§11, *Number formatting*). Neither needs a profile.
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
