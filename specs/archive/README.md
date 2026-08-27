# Archived specs

These documents are **design history**. None of them describes the language
as it is now, and none is maintained. They are kept because the reasoning in
them is worth having, not because it is current.

For the language as implemented, read [`../reference.md`](../reference.md).

| file | what it was | superseded by |
|---|---|---|
| `llm.md` | the v1 reference — grammar, AST, embedding guide, CLI | `../reference.md` |
| `templating-language.md` | the v1 design record: every decision in the order it was made, superseded intermediates preserved on purpose | `../reference.md` |
| `position.md` | the v1-era position paper the static-analysis restrictions were argued from | `../laws.md`, `../reference.md` |
| `core.md` | a condensed v2 core-AST sketch | `../reference.md` §2 |
| `merged.md` | an early v2 merge of the drafts | `merged2.md`, then `../reference.md` |
| `merged2.md` | the fullest v2 draft — `constraints.md` plus the `FromContext` import design | `../reference.md` |
| `constraints.md` | `merged2.md` with an older §17; otherwise identical | `merged2.md`, then `../reference.md` |
| `v2.md` | an early v2 sketch | `../reference.md` |
| `value.md` | the dedicated Node-AST draft, with six constructors | `../node-json.md`, `../reference.md` §4 |

## Two things to know before reading them

**They contradict each other.** That is the point of
[`../decisions.md`](../decisions.md), which records which reading won for each
conflict and why. Seven conflicts were resolved that way; `core.md` and
`merged2.md` §23 disagree with `merged2.md` §17 about whether a
`PartialImport` constructor exists at all, and `value.md` and `merged2.md` §1
disagree about how many `Node` constructors there are.

**Their internal paths are stale.** A document here that says
`specs/llm.md` means what is now `specs/archive/llm.md`. Cross-references
between archived documents still resolve, since they all moved together. The
documents themselves were not edited on the way in — rewriting a historical
record to fit a later layout would defeat the purpose of keeping it.
