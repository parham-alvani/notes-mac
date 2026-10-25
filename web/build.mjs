// Bundles the reading view into Sources/Daftar/Reader/, which the app ships
// as a resource folder. The output is generated: edit web/src, then run
// `just web`.

import { build } from "esbuild";
import { cpSync, mkdirSync, rmSync } from "node:fs";

const out = "../Sources/Daftar/Reader";
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

cpSync("src/index.html", `${out}/index.html`);
cpSync("src/reader.css", `${out}/reader.css`);
cpSync("node_modules/katex/dist/katex.min.css", `${out}/katex.min.css`);
cpSync("node_modules/katex/dist/fonts", `${out}/fonts`, { recursive: true });
