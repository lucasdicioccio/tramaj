# tramaj-hpdf

Folds an evaluated `tramaj-hs` `Node` into a PDF document with
[HPDF](https://hackage.haskell.org/package/HPDF). The print counterpart of
`tramaj-react` and `tramaj-halogen`: the evaluator produces the tree, this
package decides what it looks like on a page.

## Use

```haskell
import qualified Data.ByteString.Lazy as BL
import Tramaj.Hpdf

main = do
  fonts <- loadFonts
  BL.writeFile "out.pdf" (renderPdf fonts defaultOptions node)
```

`renderPdfToFile path opts node` does both. `Options` sets the page size and
margins (`a4` by default), the document's author and subject, and whether
page streams are compressed.

The CLI renders a template against a context, or an already-evaluated node
in the normative Node JSON (`specs/node-json.md`):

```
cabal run tramaj-hpdf -- template.tramaj context.json out.pdf
cabal run tramaj-hpdf -- --node node.json out.pdf
```

## What a node becomes

`Tramaj.Hpdf.Layout` is pure: `nodeBlocks` reads the tree as a document and
`layoutPages` breaks it into lines and pages, given font widths. It can be
tested, or drawn by another backend, without HPDF.

- `h1`–`h6`: bold headings, 22pt down to 11pt.
- `p`, `pre`, `blockquote`, `ul`, `ol`, `li`, `hr`: paragraphs, preformatted
  Courier text, indented quotes, bulleted and numbered lists (a fragment
  inside a list, as `map` makes, is looked through), and rules.
- `strong`/`b`, `em`/`i`, `code`/`kbd`/`samp`, `small`/`sub`/`sup` and the
  other inline tags in `inlineTags` style text within its paragraph; `br`
  breaks the line.
- Any other tag is a plain block container, so its content still shows.
- A fragment contributes its children. Text directly inside a container is
  gathered into paragraphs between its block siblings.
- Values render as `str` writes them: an integer as its digits, a float
  always with a fraction (`3.0`). An element with a value slot and no
  children shows the value, as `tramaj-react` does.
- Attributes and actions are ignored: a page has nothing to wire an action
  to.

Lines wrap greedily at spaces; a word wider than the line is cut by
character; `pre` keeps its spaces and breaks at newlines.

## Limits, and what an HPDF fork would add

Upstream HPDF writes only the PDF standard 14 fonts, which the viewer
supplies, with a single-byte encoding (MacRoman). So:

- **No Unicode beyond Western European Latin.** A character the encoding
  lacks (CJK, Greek, Cyrillic, most symbols) is drawn as `?`.
- **No font embedding.** The output depends on the viewer's Helvetica and
  Courier.
- **Not PDF/A.** PDF/A requires every font embedded, plus XMP metadata and
  an output intent.

Lifting these needs changes inside HPDF itself: loading a TrueType/OpenType
font, embedding it as a CIDFontType2 with Identity-H encoding, a
`ToUnicode` CMap so text can be copied out, subsetting to keep files small,
and the PDF/A metadata objects. That is a fork of HPDF (or patches sent
upstream), not something this package can do from outside; `fontMetrics`
and `Metrics.encodable` are where such fonts would plug in.

Also not done yet: links (`a href` as a link annotation), images, tables
laid out as grids, the v3 symbol and term labels `tramaj-react` shows, and
page headers/footers.

## Tests

```
cabal test hpdf --enable-tests
```

Layout tests use a fixed-width fake font; the HPDF tests check widths,
encodability, the page count and the content stream; and every node in the
conformance corpus (`corpus/cases/*/expected.json`) must fold to a PDF.
