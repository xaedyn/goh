// Regenerates the goh vector wordmark package from the source raster.
//
// Setup (once):   cd assets/brand/wordmark/tools && npm install
// Prerequisites:  rsvg-convert and magick (ImageMagick) on PATH for QA renders.
// Run:            npm run build   (or: node build-wordmark.mjs)
//
// Outputs (written to the package root, one level up from this script):
//   goh-wordmark.svg            transparent production master (hardcoded fills)
//   goh-wordmark-dark.svg       dark-ground variant (hardcoded fills)
//   goh-wordmark-themed.svg     optional CSS-variable variant for web embedding
//   goh-wordmark-mask-debug.svg crop/debug reference
//   README.md                   regenerated package documentation
//   qa/*.png                    rendered + difference QA artifacts

import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { PNG } = require("pngjs");
const potrace = require("potrace");

const __dirname = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(__dirname, "..");
const sourcePath = join(packageRoot, "source", "wordmark-source.png");
const qaDir = join(packageRoot, "qa");

const colors = {
  ground: "#030309",
  type: "#F8F5EF",
  accent: "#AADB35",
};

// Crop of the hero wordmark within the source raster.
const sourceCrop = {
  x: 690,
  y: 125,
  width: 530,
  height: 350,
};

// Pixel-derived from the green arrow in the source crop, relative to sourceCrop.
const arrowPoints = [
  [154, 172],
  [243, 172],
  [238, 161],
  [282, 178],
  [238, 195],
  [243, 184],
  [153, 184],
];

mkdirSync(qaDir, { recursive: true });

function run(command, args) {
  execFileSync(command, args, { stdio: "inherit" });
}

function rgbFromHex(hex) {
  return [
    Number.parseInt(hex.slice(1, 3), 16),
    Number.parseInt(hex.slice(3, 5), 16),
    Number.parseInt(hex.slice(5, 7), 16),
  ];
}

function luma(r, g, b) {
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function isAccentPixel(r, g, b) {
  return g > 120 && r > 70 && r < 220 && b < 120 && g > r + 10 && g > b + 50;
}

function readSource() {
  return PNG.sync.read(readFileSync(sourcePath));
}

function writeCrop(source) {
  const crop = new PNG({ width: sourceCrop.width, height: sourceCrop.height });
  for (let y = 0; y < sourceCrop.height; y += 1) {
    for (let x = 0; x < sourceCrop.width; x += 1) {
      const sourceIndex = ((sourceCrop.y + y) * source.width + sourceCrop.x + x) * 4;
      const cropIndex = (y * sourceCrop.width + x) * 4;
      crop.data[cropIndex] = source.data[sourceIndex];
      crop.data[cropIndex + 1] = source.data[sourceIndex + 1];
      crop.data[cropIndex + 2] = source.data[sourceIndex + 2];
      crop.data[cropIndex + 3] = 255;
    }
  }
  const cropPath = join(qaDir, "source-crop.png");
  writeFileSync(cropPath, PNG.sync.write(crop));
  return cropPath;
}

function writeLetterMask(source) {
  const [groundR, groundG, groundB] = rgbFromHex(colors.ground);
  const [typeR, typeG, typeB] = rgbFromHex(colors.type);
  const groundLuma = luma(groundR, groundG, groundB);
  const typeLuma = luma(typeR, typeG, typeB);
  const mask = new PNG({ width: sourceCrop.width, height: sourceCrop.height });

  for (let y = 0; y < sourceCrop.height; y += 1) {
    for (let x = 0; x < sourceCrop.width; x += 1) {
      const sourceIndex = ((sourceCrop.y + y) * source.width + sourceCrop.x + x) * 4;
      const r = source.data[sourceIndex];
      const g = source.data[sourceIndex + 1];
      const b = source.data[sourceIndex + 2];
      const maskIndex = (y * sourceCrop.width + x) * 4;
      const alpha = Math.max(0, Math.min(1, (luma(r, g, b) - groundLuma) / (typeLuma - groundLuma)));
      const isLetter = !isAccentPixel(r, g, b) && alpha > 0.32;
      const value = isLetter ? 0 : 255;
      mask.data[maskIndex] = value;
      mask.data[maskIndex + 1] = value;
      mask.data[maskIndex + 2] = value;
      mask.data[maskIndex + 3] = 255;
    }
  }

  const maskPath = join(qaDir, "letters-mask.png");
  writeFileSync(maskPath, PNG.sync.write(mask));
  return maskPath;
}

function traceBitmap(maskPath) {
  return new Promise((resolveTrace, reject) => {
    potrace.trace(
      maskPath,
      {
        turdSize: 6,
        turnPolicy: potrace.Potrace.TURNPOLICY_MINORITY,
        alphaMax: 0.9,
        optCurve: true,
        optTolerance: 0.08,
        threshold: 128,
        blackOnWhite: true,
        color: colors.type,
        background: "transparent",
      },
      (error, svg) => {
        if (error) {
          reject(error);
          return;
        }

        const match = svg.match(/<path[^>]*d="([^"]+)"/);
        if (!match) {
          reject(new Error(`No path returned for ${maskPath}`));
          return;
        }

        resolveTrace(match[1]);
      },
    );
  });
}

function arrowPolygon() {
  return arrowPoints.map(([x, y]) => `${x},${y}`).join(" ");
}

// Hardcoded fills keep the master portable across every SVG consumer.
// The themed variant swaps in CSS custom properties for web embedding.
function wordmarkBody(letterPath, { themed = false } = {}) {
  const accentFill = themed ? `var(--goh-accent, ${colors.accent})` : colors.accent;
  const typeFill = themed ? `var(--goh-type, ${colors.type})` : colors.type;
  return `  <g id="goh-wordmark" fill-rule="evenodd">
    <g id="arrow" fill="${accentFill}">
      <polygon points="${arrowPolygon()}"/>
    </g>
    <g id="letters" fill="${typeFill}">
      <path d="${letterPath}"/>
    </g>
  </g>`;
}

function svgDocument(letterPath, { dark = false, debug = false, themed = false } = {}) {
  const groundFill = themed ? `var(--goh-ground, ${colors.ground})` : colors.ground;
  const accentStroke = themed ? `var(--goh-accent, ${colors.accent})` : colors.accent;
  const background = dark
    ? `  <rect id="ground" width="${sourceCrop.width}" height="${sourceCrop.height}" fill="${groundFill}"/>\n`
    : "";
  const debugFrame = debug
    ? `  <rect id="crop-frame" x="0.5" y="0.5" width="${sourceCrop.width - 1}" height="${sourceCrop.height - 1}" fill="none" stroke="${accentStroke}" stroke-width="1" stroke-dasharray="8 8" opacity="0.65"/>\n`
    : "";
  const defs = themed
    ? `  <defs>
    <style>
      :root {
        --goh-ground: ${colors.ground};
        --goh-type: ${colors.type};
        --goh-accent: ${colors.accent};
      }
    </style>
  </defs>\n`
    : "";

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${sourceCrop.width} ${sourceCrop.height}" role="img" aria-labelledby="title desc">
  <title id="title">goh wordmark</title>
  <desc id="desc">Lowercase serif goh wordmark with a green arrow through the o counter.</desc>
  <metadata>{
    "source": "source/wordmark-source.png",
    "sourceCrop": ${JSON.stringify(sourceCrop)},
    "method": "letters traced from the cream silhouette of the source crop; arrow redrawn as a geometric polygon",
    "colors": ${JSON.stringify(colors)}
  }</metadata>
${defs}${background}${debugFrame}${wordmarkBody(letterPath, { themed })}
</svg>
`;
}

function writeReadme() {
  writeFileSync(
    join(packageRoot, "README.md"),
    `# goh vector wordmark

A vector reconstruction of the goh wordmark: letters traced from the source
raster's silhouette, with the arrow rebuilt as clean geometric SVG.

## Files

- \`goh-wordmark.svg\` — transparent production master (hardcoded fills)
- \`goh-wordmark-dark.svg\` — dark-ground variant (hardcoded fills)
- \`goh-wordmark-themed.svg\` — CSS-variable variant for web embedding
- \`goh-wordmark-mask-debug.svg\` — crop/debug reference
- \`source/wordmark-source.png\` — source raster the trace is derived from
- \`tools/\` — the regeneration script and its pinned dependencies
- \`qa/\` — rendered and difference artifacts for visual verification

## Colors

- Ground: \`${colors.ground}\`
- Type: \`${colors.type}\`
- Accent: \`${colors.accent}\`

## Which file to use

Use \`goh-wordmark.svg\` everywhere by default — its fills are literal hex, so it
renders identically in every SVG consumer (browsers, README embeds, image
loaders, SVG-to-PDF, native macOS). Reach for \`goh-wordmark-themed.svg\` only in
web contexts where you want to recolor the mark via the \`--goh-ground\`,
\`--goh-type\`, and \`--goh-accent\` CSS custom properties; it falls back to the
same hex values when those properties are undefined, but some renderers do not
support \`var()\` in presentation attributes, which is why it is not the master.

## Regenerating

\`\`\`sh
cd tools
npm install            # one-time; installs pinned pngjs + potrace
npm run build          # regenerates SVGs, README, and qa/ artifacts
\`\`\`

The QA step shells out to \`rsvg-convert\` and \`magick\` (ImageMagick); both must
be on your PATH. On macOS: \`brew install librsvg imagemagick\`.

## Method

The letterforms are traced from the source crop's cream silhouette. The arrow is
redrawn as a seven-point geometric polygon using coordinates sampled from the
source arrow's visible pixels. The SVG keeps the arrow and letters in separate
named groups for future editing.

Construction notes:

- Source crop: \`x=${sourceCrop.x}\`, \`y=${sourceCrop.y}\`, \`width=${sourceCrop.width}\`, \`height=${sourceCrop.height}\`
- Arrow points inside the SVG viewBox: \`${arrowPolygon()}\`

## Caveat

These are traced letterforms, not editable live text, and the package does not
include any font file. Treat the SVG as standalone logo artwork, not as a
substitute for a typeface.
`,
  );
}

async function main() {
  const source = readSource();
  const cropPath = writeCrop(source);
  const maskPath = writeLetterMask(source);
  const letterPath = await traceBitmap(maskPath);

  writeFileSync(join(packageRoot, "goh-wordmark.svg"), svgDocument(letterPath));
  writeFileSync(join(packageRoot, "goh-wordmark-dark.svg"), svgDocument(letterPath, { dark: true }));
  writeFileSync(join(packageRoot, "goh-wordmark-themed.svg"), svgDocument(letterPath, { themed: true }));
  writeFileSync(
    join(packageRoot, "goh-wordmark-mask-debug.svg"),
    svgDocument(letterPath, { dark: true, debug: true }),
  );
  writeReadme();

  run("rsvg-convert", [
    "-w",
    `${sourceCrop.width}`,
    "-h",
    `${sourceCrop.height}`,
    join(packageRoot, "goh-wordmark-dark.svg"),
    "-o",
    join(qaDir, "rendered.png"),
  ]);
  run("rsvg-convert", [
    "-w",
    `${sourceCrop.width * 2}`,
    "-h",
    `${sourceCrop.height * 2}`,
    join(packageRoot, "goh-wordmark-dark.svg"),
    "-o",
    join(qaDir, "rendered-2x.png"),
  ]);
  run("rsvg-convert", [
    "-w",
    `${sourceCrop.width * 2}`,
    "-h",
    `${sourceCrop.height * 2}`,
    join(packageRoot, "goh-wordmark.svg"),
    "-o",
    join(qaDir, "transparent-2x.png"),
  ]);
  run("magick", [
    cropPath,
    join(qaDir, "rendered.png"),
    "-compose",
    "difference",
    "-composite",
    join(qaDir, "overlay.png"),
  ]);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
