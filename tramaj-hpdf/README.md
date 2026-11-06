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
  fonts <- loadDefaultFonts   -- the bundled Noto Sans; loadFonts for the standard 14
  Right images <- loadImages "." node
  BL.writeFile "out.pdf" (renderPdf fonts images defaultOptions node)
```

`renderPdfToFile path opts node` does all three. `Options` sets the page
size and margins (`a4` by default), the document's author and subject,
whether page streams are compressed, and the directory a relative
`img src` is read from (`optBaseDir`; the CLI uses the template's), a
directory of Noto Sans fonts to use instead of the bundled ones
(`optFontDir`), and what to do about missing glyphs (`optMissingGlyphs`).

The CLI renders a template against a context, or an already-evaluated node
in the normative Node JSON (`specs/node-json.md`):

```
cabal run tramaj-hpdf -- template.tramaj context.json out.pdf
cabal run tramaj-hpdf -- --node node.json out.pdf
cabal run tramaj-hpdf -- --fonts /usr/share/fonts/truetype/noto template.tramaj context.json out.pdf
cabal run tramaj-hpdf -- --missing-glyphs error template.tramaj context.json out.pdf
```

## Building: the HPDF fork

Embedding TrueType fonts needs an HPDF fork,
https://github.com/lucasdicioccio/HPDF (branch `unicode-truetype`), which
loads TrueType fonts and embeds them as Type0/CIDFontType2 with Identity-H,
a `ToUnicode` CMap and subsetting. It is not on Hackage and not proposed
upstream; the repository's `cabal.project` pins it by commit as a
`source-repository-package`, so a clean checkout builds as is. A project
that depends on tramaj-hpdf needs the same stanza in its own
`cabal.project` (copy it from this repository's).

## Fonts

Text is set in Noto Sans (Regular, Bold, Italic, BoldItalic) and Noto Sans
Mono (Regular, Bold), bundled in [`fonts/`](fonts/) and compiled into the
library, so nothing is read from the system at run time. They are the
unmodified Noto Sans 2.004 / Noto Sans Mono 2.006 files (Debian
`fonts-noto-core`/`fonts-noto-mono` 20201225), under the **SIL Open Font
License 1.1** ([`fonts/OFL.txt`](fonts/OFL.txt)); the package's own code is
MIT. A PDF embeds a subset of each face it uses (only the glyphs it shows),
so `examples/cyrillic` comes to about 45 KB. They cover Latin (every EU language),
Greek and Cyrillic, and the euro sign; not CJK, Arabic or Indic scripts.

`--fonts DIR` (`optFontDir`) takes the six files from another directory
instead, by the Noto file names (`notoSans`); `loadTrueTypeFonts` takes any
TrueType files per face. `loadFonts` keeps the PDF standard 14 fonts
(Helvetica, Courier: nothing embedded, MacRoman only).

### Missing glyphs

A character the face has no glyph for is never dropped: it is drawn as
U+FFFD REPLACEMENT CHARACTER (`�`; `?` in the standard 14 fonts, which lack
it). `renderPdfToFile` and the CLI then list the characters on stderr:

```
tramaj-hpdf: warning: no glyph for U+65E5 '日' (Regular); drawn as a replacement character
```

With `optMissingGlyphs = FailOnMissingGlyphs` (`--missing-glyphs error`)
they fail with that list instead and write no file, for documents such as
invoices where a replacement character must not go out. `missingGlyphsIn`
gives the list for a node, to check before rendering with `renderPdf`.

## Example

[`examples/report/`](examples/report/) renders a deployment report from a
template and a JSON context ([`report.pdf`](examples/report/report.pdf)):

<img src="examples/report/report-page1.png" alt="page 1 of the example report" width="400">

## Factur-X invoices (PDF/A-3b)

With the HPDF fork (below), `optArchive = Just (facturX icc level xml)`
writes the document as PDF/A-3b: XMP metadata, an sRGB output intent, the
XML attached as `factur-x.xml` (`/AFRelationship /Alternative`) and the
Factur-X XMP properties at that level (`BASIC`, `EN 16931`…). It needs
embedded fonts, which the bundled Noto Sans are: `renderPdfE` refuses a
PDF/A document set in the standard 14 fonts (`loadFonts`), which are not
embedded.

`Tramaj.Hpdf.Xml.renderXml` writes an evaluated node as XML, so the invoice's
XML comes from a tramaj template over the same context as the page. A tag
has no `:`, so a namespace prefix is written with a `-`: `ram-ID` becomes
`ram:ID` when an `xmlns:ram` attribute is in scope. The CLI:

```
cabal run tramaj-hpdf -- \
  --factur-x factur-x.tramaj [--factur-x-level BASIC] [--icc sRGB.icc] [--xml-out factur-x.xml] \
  invoice.tramaj invoice.json invoice.pdf
cabal run tramaj-hpdf -- --xml factur-x.tramaj invoice.json factur-x.xml
```

`--factur-x-xml FILE` attaches an XML file as it is. The ICC profile
defaults to colord's sRGB (`/usr/share/color/icc/colord/sRGB.icc`, CC0-1.0,
an ICC v4 profile); none is shipped with this package. See
[`examples/invoice/`](examples/invoice/): a commercial invoice (TypeCode 380), BASIC profile.

<img src="examples/invoice/invoice-page1.png" alt="page 1 of the example invoice" width="400">

The example passes veraPDF (PDF/A-3b: compliant, 146/146 rules) and
Mustang 2.26.0 (Factur-X BASIC, with the EN 16931 and French BR-FR
rules: valid, 0 errors, 0 warnings).

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
- `table`: a grid. Rows are the `tr` children (directly or in `thead`,
  `tbody`, `tfoot`), cells their `td`/`th`. The header is the `thead` rows,
  or else the leading rows made only of `th`; `th` is bold. Columns are as
  wide as their content when the table fits the text width; otherwise each
  gets its longest word and the rest of the width is shared by need, and
  cells wrap. A cell holding a number is right-aligned, `align: "left" |
  "center" | "right"` sets it, and a header cell follows its column. Heavy
  rules frame the table and the header, light ones separate body rows. A
  table breaks between rows, and the header is repeated at the top of each
  new page. A `caption` (and anything else that is not a row) is laid out
  above the table. A cell shows text only: nested lists, rules, images and
  tables inside it are flattened to their text.
- `img`: an image on a line of its own, from `src` (a file path, relative
  to `optBaseDir`; not a URL). `width` and `height` are in points (a number,
  or `"72"`, `"72pt"`, `"72px"`); with one of them the other keeps the
  aspect ratio, and with neither the image is its pixel size, shrunk to
  the text width. `align` places it left, center or right. JPEG is embedded
  as is; PNG and the other formats JuicyPixels reads are decoded to RGB,
  with transparency flattened onto white. An image the layout has no size
  for shows its `alt` text, or `[image: src]`; `renderPdfToFile` fails
  instead, naming the `src` it could not read.
- Any other tag is a plain block container, so its content still shows.
- A fragment contributes its children. Text directly inside a container is
  gathered into paragraphs between its block siblings.
- Values render as `str` writes them: an integer as its digits, a float
  always with a fraction (`3.0`). An element with a value slot and no
  children shows the value, as `tramaj-react` does.
- Other attributes, and actions, are ignored: a page has nothing to wire an
  action to.

Lines wrap greedily at spaces; a word wider than the line is cut by
character; `pre` keeps its spaces and breaks at newlines.

## Limits

[`examples/cyrillic`](examples/cyrillic/) shows Cyrillic, Greek and
accented Latin in all the faces, copied out as Unicode. PDF/A-3b and
Factur-X are above; they need the HPDF fork's `factur-x` branch (built on
`unicode-truetype`), which `cabal.project` pins. Still missing: kerning,
shaping for complex scripts (no glyph substitution or positioning), and
font fallback (one font per face; a character outside it is a missing
glyph).

Also not done yet: links (`a href` as a link annotation), `colspan` and
`rowspan`, a table row taller than a page (it overflows instead of
splitting), images inline in text or in table cells, the v3 symbol and
term labels `tramaj-react` shows, and page headers/footers.

## Tests

```
cabal test hpdf --enable-tests
```

Layout tests use a fixed-width fake font; the HPDF tests check widths,
encodability, the page count and the content stream; and every node in the
conformance corpus (`corpus/cases/*/expected.json`) must fold to a PDF.
