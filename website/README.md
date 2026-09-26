# Your new Kitchen-Sink site

This directory was bootstrapped by `kitchen-sink init`.

[Kitchen-Sink](https://kitchensink-tech.github.io/) is a static-site
generator and dev/serve daemon for blogs. A page is a `.cmark`/`.md` file
split into *sections* (content, metadata, CSS, …); Kitchen-Sink assembles
those sections into a full site.

- `src/` — your site's source: `kitchen-sink.json` (site config),
  `index.cmark`, `first-article.cmark`, and the other `.cmark` pages, plus
  the CSS/JS assets they reference.
- `www/` — the output directory skeleton. Kitchen-Sink writes generated
  pages here; you don't need to touch it by hand.

## Next steps

Before producing or serving the site, regenerate the two mechanical bits of
content that live outside this directory (both write into `src/` and are
gitignored there — see `scripts/`):

```
./scripts/sync-reference.sh    # mirrors specs/*.md into reference-*.cmark
./scripts/sync-playground.sh   # bundles playground/ into a static tramaj-playground.* page
```

## Diagrams need graphviz

The illustrations are `website/src/*.dot` sources, versioned next to the
pages that use them. `kitchen-sink produce`/`serve` renders each one with
graphviz `dot` to `/gen/images/<name>.dot.png`, and pages reference that with
`![caption](/gen/images/<name>.dot.png)`. **graphviz (`dot`) must be
installed wherever the site is produced**; the rendered PNGs are produce
output, only the `.dot` files are source. The output directory needs its
skeleton (`gen/images`, `images`, `css`, ...) to exist before `produce`.

## Serving

Run the dev server, which rebuilds on file changes:

```
kitchen-sink serve --srcDir src --outputDir www --servMode DEV --httpPort 7655
```

Then open http://localhost:7655/ and start editing the `.cmark` files in
`src/`.

## Learn more

- [Features](https://kitchensink-tech.github.io/features.html) — what
  Kitchen-Sink can do.
- [Sections](https://kitchensink-tech.github.io/sections.html) — the
  section format used inside each `.cmark` file.
