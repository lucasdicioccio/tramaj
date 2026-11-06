# Changelog

## 0.1.0.0 (unreleased)

First version.

- Tables are laid out as a grid: columns sized to their content, wrapping
  cells, a bold header row repeated across page breaks, rules.
- `img` embeds a JPEG or PNG (and other JuicyPixels formats), scaled to
  its `width`/`height` or to the text width, keeping its proportions.
- Factur-X (on the HPDF fork): `optArchive` / `facturX` write PDF/A-3b
  with the invoice's XML attached; `renderPdfE` reports a PDF/A document
  that uses a non-embedded font. CLI flags `--factur-x`, `--factur-x-xml`,
  `--factur-x-level`, `--icc`, `--xml-out`, `--title`, `--author`.
- `Tramaj.Hpdf.Xml`: an evaluated node written as XML (`ram-ID` is
  `ram:ID` under an `xmlns:ram`); CLI `--xml`.
