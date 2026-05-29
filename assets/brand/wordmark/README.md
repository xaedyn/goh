# goh vector wordmark

A vector reconstruction of the goh wordmark: letters traced from the source
raster's silhouette, with the arrow rebuilt as clean geometric SVG.

## Files

- `goh-wordmark.svg` — transparent production master (hardcoded fills)
- `goh-wordmark-dark.svg` — dark-ground variant (hardcoded fills)
- `goh-wordmark-themed.svg` — CSS-variable variant for web embedding
- `goh-wordmark-mask-debug.svg` — crop/debug reference
- `source/wordmark-source.png` — source raster the trace is derived from
- `tools/` — the regeneration script and its pinned dependencies
- `qa/` — rendered and difference artifacts for visual verification

## Colors

- Ground: `#030309`
- Type: `#F8F5EF`
- Accent: `#AADB35`

## Which file to use

Use `goh-wordmark.svg` everywhere by default — its fills are literal hex, so it
renders identically in every SVG consumer (browsers, README embeds, image
loaders, SVG-to-PDF, native macOS). Reach for `goh-wordmark-themed.svg` only in
web contexts where you want to recolor the mark via the `--goh-ground`,
`--goh-type`, and `--goh-accent` CSS custom properties; it falls back to the
same hex values when those properties are undefined, but some renderers do not
support `var()` in presentation attributes, which is why it is not the master.

## Regenerating

```sh
cd tools
npm install            # one-time; installs pinned pngjs + potrace
npm run build          # regenerates SVGs, README, and qa/ artifacts
```

The QA step shells out to `rsvg-convert` and `magick` (ImageMagick); both must
be on your PATH. On macOS: `brew install librsvg imagemagick`.

## Method

The letterforms are traced from the source crop's cream silhouette. The arrow is
redrawn as a seven-point geometric polygon using coordinates sampled from the
source arrow's visible pixels. The SVG keeps the arrow and letters in separate
named groups for future editing.

Construction notes:

- Source crop: `x=690`, `y=125`, `width=530`, `height=350`
- Arrow points inside the SVG viewBox: `154,172 243,172 238,161 282,178 238,195 243,184 153,184`

## Caveat

These are traced letterforms, not editable live text, and the package does not
include any font file. Treat the SVG as standalone logo artwork, not as a
substitute for a typeface.
