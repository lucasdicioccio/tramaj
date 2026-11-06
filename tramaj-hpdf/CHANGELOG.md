# Changelog

## Unreleased

Factur-X invoices. Needs the HPDF fork's `factur-x` branch (commit
`dc7cdb7`, built on `unicode-truetype`), which `cabal.project` pins.

- `optArchive` / `facturX` write PDF/A-3b with the invoice's XML attached
  as `factur-x.xml` (`/CreationDate` and `/ModDate` from the invoice's
  issue date, `invoiceIssueDate`) and the Factur-X XMP properties;
  `renderPdfE` reports a PDF/A document that uses a non-embedded font. The
  bundled fonts are embedded, so no `--fonts` is needed. CLI flags
  `--factur-x`, `--factur-x-xml`, `--factur-x-level`, `--icc`,
  `--xml-out`, `--title`, `--author`.
- `Tramaj.Hpdf.Xml`: an evaluated node written as XML (`ram-ID` is
  `ram:ID` under an `xmlns:ram`); CLI `--xml`.
- Example: `examples/invoice/`, a commercial invoice (TypeCode 380), BASIC
  profile.

## 0.2.0.0

Embedded fonts and Unicode text. Needs the HPDF fork
https://github.com/lucasdicioccio/HPDF (branch `unicode-truetype`, commit
`a0635c5`), which the repository's `cabal.project` pins; a project depending
on tramaj-hpdf adds the same `source-repository-package` stanza.

- Text is set in Noto Sans and Noto Sans Mono, bundled in `fonts/` (SIL
  Open Font License 1.1, `fonts/OFL.txt`) and compiled into the library
  (`loadDefaultFonts`, `defaultFontFiles`): every EU language, Greek and
  Cyrillic render and copy out as Unicode, with no font needed on the
  system. A PDF embeds a subset of each face it uses.
- `renderPdfToFile` uses the bundled fonts by default (it used the standard
  14 fonts); `optFontDir` / `--fonts DIR` take Noto Sans from a directory
  instead, and `loadTrueTypeFonts` any TrueType files. `loadFonts` still
  gives the standard 14 fonts.
- Missing glyphs: a character the face lacks is drawn as U+FFFD (`?` in
  the standard 14 fonts), and `renderPdfToFile` lists the characters on
  stderr, or fails without writing with `optMissingGlyphs =
  FailOnMissingGlyphs` (`--missing-glyphs error`). `missingGlyphs`,
  `missingGlyphsIn` and `describeMissingGlyphs` give the list.
- The licence field is now `MIT AND OFL-1.1` (the code is MIT).

## 0.1.0.0

First version.

- Tables are laid out as a grid: columns sized to their content, wrapping
  cells, a bold header row repeated across page breaks, rules.
- `img` embeds a JPEG or PNG (and other JuicyPixels formats), scaled to
  its `width`/`height` or to the text width, keeping its proportions.
