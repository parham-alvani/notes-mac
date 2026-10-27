// The Quick Look preview of a note: Finder's space bar. Quick Look shows an
// HTML page without running its scripts, so the extension runs this in
// JavaScriptCore and hands Quick Look the finished HTML. No DOM here: what
// reader.js does to the page after `render` is done on the string.

import { render, hue, languageColor } from "./render.js";

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

/** Text whose first letter is right to left, as a Persian note's title (reader.js has the same). */
const RTL_FIRST = /^[^\p{L}]*[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]/u;

function unescapeHtml(text) {
  return text.replace(/&(amp|lt|gt|quot|#39);/g, (_, name) => ({ amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'" })[name]);
}

/**
 * `{ title, text, path, links, properties }` to the note as the reader
 * draws it: the title, the properties, the body, the tags in their colours
 * and each code block under its language. Links stay links; nothing follows
 * them.
 */
export function preview({ title = "", text = "", path = "", links = {}, properties = [] }) {
  let body = render(text, { path, links });
  body = body.replace(
    /<a class="tag" href="#" data-tag="([^"]*)">/g,
    (_, tag) => `<a class="tag" href="#" data-tag="${tag}" style="--tag-color: var(${hue(unescapeHtml(tag))})">`,
  );
  body = body.replace(/<pre((?![^>]*class="mermaid")[^>]*)><code([^>]*)>([\s\S]*?)<\/code><\/pre>/g, (_, pre, code, inner) => {
    const lang = /language-([\w+#-]+)/.exec(code)?.[1] ?? "";
    return (
      `<div class="code-block" style="--lang-color: var(${languageColor(lang)})">` +
      `<div class="code-head"><span class="code-lang">${escapeHtml(lang || "code")}</span></div>` +
      `<pre${pre}><code${code}>${inner}</code></pre></div>`
    );
  });
  const rows = properties.map(([key, value]) => `<tr><th>${escapeHtml(key)}</th><td dir="auto">${escapeHtml(value)}</td></tr>`).join("");
  return `<h1 class="inline-title" dir="${RTL_FIRST.test(title) ? "rtl" : "auto"}">${escapeHtml(title)}</h1>` + (rows ? `<table class="properties">${rows}</table>` : "") + body;
}

// What the extension calls, with the note as JSON.
globalThis.daftarPreview = (json) => preview(JSON.parse(json));
