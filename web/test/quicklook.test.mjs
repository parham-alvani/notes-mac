import { test } from "node:test";
import assert from "node:assert/strict";
import { preview } from "../src/quicklook.js";

test("the preview has the title, the properties and the body", () => {
  const html = preview({ title: "Plan <a>", text: "Body", properties: [["status", "open & done"]] });
  assert.match(html, /^<h1 class="inline-title" dir="auto">Plan &lt;a&gt;<\/h1>/);
  assert.match(html, /<tr><th>status<\/th><td dir="auto">open &amp; done<\/td><\/tr>/);
  assert.match(html, /<p dir="auto"[^>]*>Body<\/p>/);
});

test("tags get their colour, as in the reader", () => {
  assert.match(preview({ text: "a #tag" }), /data-tag="tag" style="--tag-color: var\(--vivid-yellow\)">#tag</);
});

test("a code block is drawn under its language, a diagram is not", () => {
  const html = preview({ text: "```go\nx := 1\n```\n\n```mermaid\ngraph TD\n```" });
  assert.match(html, /<div class="code-block" style="--lang-color: var\(--aqua\)"><div class="code-head"><span class="code-lang">go<\/span><\/div><pre>/);
  assert.equal(html.match(/class="code-block"/g).length, 1);
});

test("Persian paragraphs and callouts take their own direction", () => {
  const html = preview({ text: "> [!tip] سلام\n> متن\n\nدنیا" });
  assert.match(html, /<div class="callout" data-callout="tip" dir="auto" role="note">/);
  assert.match(html, /<p dir="auto"[^>]*>دنیا<\/p>/);
});

test("the extension's entry point takes JSON", async () => {
  assert.match(globalThis.daftarPreview(JSON.stringify({ text: "![[a.png]]", links: { "a.png": "uploads/a.png" } })), /<img src="vault:\/\/\/uploads\/a.png"/);
});
