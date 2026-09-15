//! Rust port of the Tramaj language (`specs/reference.md`, `specs/v3-symbols.md`,
//! `specs/v4-types.md`, `specs/node-json.md`). Hand-written, not generated from
//! `tramaj/` or `tramaj-hs/`; agreement with those two implementations is
//! enforced by the shared corpus at `corpus/cases/` (see `tests/corpus.rs`),
//! the same way `tramaj-hs` is checked against `tramaj`.
//!
//! Module layout mirrors `tramaj-hs/src/Tramaj/*.hs` one-to-one so the two
//! sources stay easy to diff against each other during the port.

pub mod analysis;
pub mod ast;
pub mod eval;
pub mod node;
pub mod parser;
pub mod types;
