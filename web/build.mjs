// Bundles the reading view into Sources/DaftarUI/Reader/, which the app ships
// as a resource folder. The output is generated: edit web/src, then run
// `just web`.

import { build } from "esbuild";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";

const out = "../Sources/DaftarUI/Reader";
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

await build({
  entryPoints: ["src/reader.js"],
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari17",
  outfile: `${out}/reader.js`,
  legalComments: "eof",
});

// Mermaid is most of the weight, and most notes have no diagram: the page
// loads it the first time a note needs it.
await build({
  stdin: { contents: `import mermaid from "mermaid"; window.mermaid = mermaid;`, resolveDir: "." },
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari17",
  outfile: `${out}/mermaid.js`,
  legalComments: "eof",
});

// Task checkboxes as the phone draws them (`Blocks.kt`): a Lucide icon per
// status, in the colour of its role. The icons become CSS masks, so the
// colour is a CSS value and follows the theme.
const statuses = [
  [" ", "square", "--list-marker"],
  ["x", "square-check-big", "--done-color"],
  ["X", "square-check-big", "--done-color"],
  ["-", "square-x", "--done-color"],
  ["/", "square-dot", "--accent"],
  [">", "square-arrow-right", "--blue"],
  ["<", "calendar-clock", "--blue"],
  ["!", "circle-alert", "--red"],
  ["?", "circle-help", "--yellow"],
  ["*", "star", "--vivid-yellow"],
  ['"', "quote", "--warm-grey"],
  ["i", "info", "--blue"],
  ["b", "bookmark", "--orange"],
  ["l", "map-pin", "--red"],
  ["I", "lightbulb", "--vivid-yellow"],
  ["S", "piggy-bank", "--spring-green"],
  ["f", "flame", "--red"],
  ["k", "key", "--vivid-yellow"],
  ["w", "trophy", "--vivid-yellow"],
  ["u", "thumbs-up", "--spring-green"],
  ["p", "thumbs-up", "--spring-green"],
  ["d", "thumbs-down", "--red"],
  ["c", "thumbs-down", "--red"],
];
const icon = (name) => {
  const svg = readFileSync(`node_modules/lucide-static/icons/${name}.svg`, "utf8").replace(/<!--.*?-->/s, "").replace(/\s+/g, " ").trim();
  return `url("data:image/svg+xml,${encodeURIComponent(svg)}")`;
};
const selector = (status) => `input.task-list-item-checkbox[data-status='${status === "'" ? "\\'" : status}']`;
const css = [
  `input.task-list-item-checkbox { --task-icon: ${icon("square-dashed")}; --task-color: var(--list-marker); }`,
  ...statuses.map(([status, name, color]) => `${selector(status)} { --task-icon: ${icon(name)}; --task-color: var(${color}); }`),
];
writeFileSync(`${out}/tasks.css`, css.join("\n") + "\n");

cpSync("src/index.html", `${out}/index.html`);
cpSync("src/reader.css", `${out}/reader.css`);
cpSync("node_modules/katex/dist/katex.min.css", `${out}/katex.min.css`);
cpSync("node_modules/katex/dist/fonts", `${out}/fonts`, { recursive: true });
