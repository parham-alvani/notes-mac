// The page runtime: takes a note from the app, renders it, and reports back
// what the person does with it. Every message to the app goes through
// `post`, and the app calls `daftar.show` and `daftar.scrollTo`.

import { render, renderInline, isClosed } from "./render.js";

const app = window.webkit?.messageHandlers;

function post(message) {
  app?.daftar?.postMessage(message);
}

let current = { path: "" };
let mermaidLoading = null;

function loadMermaid() {
  if (window.mermaid) return Promise.resolve(window.mermaid);
  mermaidLoading ??= new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = "mermaid.js";
    script.onload = () => resolve(window.mermaid);
    script.onerror = reject;
    document.head.appendChild(script);
  });
  return mermaidLoading;
}

async function drawDiagrams(root) {
  const nodes = [...root.querySelectorAll("pre.mermaid")];
  if (nodes.length === 0) return;
  const mermaid = await loadMermaid();
  // The diagram takes the reader's palette, naz or Daylight.
  const css = getComputedStyle(document.documentElement);
  const color = (name) => css.getPropertyValue(name).trim();
  const dark = matchMedia("(prefers-color-scheme: dark)").matches;
  mermaid.initialize({
    startOnLoad: false,
    theme: "base",
    securityLevel: "strict",
    fontFamily: "-apple-system, sans-serif",
    themeVariables: {
      darkMode: dark,
      background: color("--background"),
      primaryColor: color("--panel"),
      primaryTextColor: color("--text"),
      primaryBorderColor: color("--accent"),
      secondaryColor: color("--code-background"),
      tertiaryColor: color("--background"),
      lineColor: color("--accent"),
      textColor: color("--text"),
      noteBkgColor: color("--panel"),
      noteTextColor: color("--text"),
    },
  });
  for (const node of nodes) {
    try {
      await mermaid.run({ nodes: [node] });
    } catch (error) {
      node.classList.add("mermaid-error");
    }
  }
}

/** The part of a note an embed names: the section under a heading, or all of it. */
function section(root, anchor) {
  if (!anchor) return root;
  if (anchor.startsWith("^")) {
    const block = root.querySelector(`[id="${CSS.escape(anchor)}"]`);
    const wrap = document.createElement("div");
    if (block) wrap.appendChild(block.cloneNode(true));
    return wrap;
  }
  const wanted = anchor.trim().toLowerCase();
  const headings = [...root.querySelectorAll("[data-heading]")];
  const start = headings.find((h) => h.dataset.heading.toLowerCase() === wanted);
  const wrap = document.createElement("div");
  if (!start) return wrap;
  const level = Number(start.tagName.slice(1));
  for (let node = start.nextElementSibling; node; node = node.nextElementSibling) {
    if (/^H[1-6]$/.test(node.tagName) && Number(node.tagName.slice(1)) <= level) break;
    wrap.appendChild(node.cloneNode(true));
  }
  return wrap;
}

/** Fills each `![[note]]` embed, one level deep: an embed inside an embed stays a link. */
async function fillEmbeds(root) {
  const embeds = [...root.querySelectorAll(".embed")];
  for (const embed of embeds) {
    const body = embed.querySelector(".embed-body");
    try {
      const note = await app?.embed?.postMessage({ path: embed.dataset.path });
      if (!note) continue;
      const holder = document.createElement("div");
      holder.innerHTML = render(note.text, { path: embed.dataset.path, links: note.links });
      holder.querySelectorAll(".embed").forEach((inner) => inner.replaceWith(Object.assign(document.createElement("a"), {
        className: "internal-link",
        href: "#",
        textContent: inner.querySelector(".embed-title")?.textContent ?? "",
      })));
      // A checkbox in an embed belongs to another file; it is shown, not ticked.
      holder.querySelectorAll("input[type=checkbox]").forEach((box) => (box.disabled = true));
      body.replaceChildren(...section(holder, embed.dataset.anchor).childNodes);
      await drawDiagrams(body);
    } catch (error) {
      body.textContent = "";
    }
  }
}

/**
 * Each ` ```tasks ` block, answered by the app: groups as headings, then the
 * tasks, each ticked in its own file. Lines the app could not read are listed
 * above the result, so a filter that did nothing is never silent.
 */
async function fillQueries(root) {
  for (const block of root.querySelectorAll(".tasks-query")) {
    let result;
    try {
      result = await app?.tasks?.postMessage({ source: block.dataset.source, path: current.path });
    } catch (error) {
      result = null;
    }
    if (!result) continue;
    const parts = [];
    if (result.notUnderstood.length > 0) {
      const lines = result.notUnderstood.map((line) => `<li><code>${escape(line)}</code></li>`).join("");
      parts.push(`<div class="callout query-warning" data-callout="warning"><div class="callout-title">Not understood, so not applied</div><ul>${lines}</ul></div>`);
    }
    let open = [];
    for (const task of result.tasks) {
      task.groups.forEach((name, level) => {
        if (open[level] === name) return;
        open = open.slice(0, level);
        open[level] = name;
        if (name) parts.push(`<div class="query-group level-${level}" dir="auto">${escape(name)}</div>`);
      });
      const checked = isClosed(task.status) ? " checked" : "";
      const dates = [task.due && `📅 ${task.due}`, task.scheduled && `⏳ ${task.scheduled}`, task.done && `✅ ${task.done}`].filter(Boolean).join(" ");
      parts.push(
        `<li class="task-list-item${checked ? " is-checked" : ""}" data-task="${escape(task.status)}" dir="auto">` +
          `<input type="checkbox" class="task-list-item-checkbox" data-path="${escape(task.path)}" data-line="${task.line}" data-status="${escape(task.status)}"${checked}>` +
          `<span class="query-text">${renderInline(task.text, { path: task.path, links: result.links })}</span>` +
          (dates ? ` <span class="query-dates">${escape(dates)}</span>` : "") +
          ` <a class="internal-link query-source" href="#" data-path="${escape(task.path)}">${escape(task.title)}</a></li>`,
      );
    }
    if (result.tasks.length === 0) parts.push(`<div class="query-empty">No tasks match.</div>`);
    parts.push(`<div class="query-count">${result.tasks.length} ${result.tasks.length === 1 ? "task" : "tasks"}</div>`);
    block.innerHTML = `<ul class="query-list">${parts.join("")}</ul>`;
  }
}


function renderProperties(properties) {
  if (!properties || properties.length === 0) return "";
  const rows = properties
    .map(([key, value]) => `<tr><th>${escape(key)}</th><td dir="auto">${escape(value)}</td></tr>`)
    .join("");
  return `<table class="properties">${rows}</table>`;
}

function escape(text) {
  const div = document.createElement("div");
  div.textContent = String(text);
  return div.innerHTML;
}

window.daftar = {
  /**
   * Shows a note: `{ path, title, text, links, properties }`, then scrolls
   * to `heading` or `line` when given, or stays where it was with
   * `keepScroll` -- a note shown again after it changed on disk.
   */
  async show(note) {
    const keep = note.keepScroll ? window.scrollY : null;
    current = note;
    const root = document.documentElement.style;
    if (note.textSize) root.setProperty("--text-size", `${note.textSize}px`);
    if (note.fontText) root.setProperty("--font-text", note.fontText);
    // SF Pro's alternates mean other things in other fonts.
    root.setProperty("--font-features", note.fontText?.startsWith("-apple-system") === false ? "normal" : '"ss01" 1, "ss07" 1, "cv07" 1');
    if (note.fontCode) root.setProperty("--font-mono", note.fontCode);
    const main = document.getElementById("note");
    main.innerHTML =
      `<h1 class="inline-title" dir="auto">${escape(note.title)}</h1>` +
      renderProperties(note.properties) +
      render(note.text, { path: note.path, links: note.links });
    if (keep !== null) window.scrollTo(0, keep);
    else if (note.heading) this.scrollTo(note.heading);
    else if (note.line != null) this.scrollToLine(note.line);
    else window.scrollTo(0, 0);
    await Promise.all([drawDiagrams(main), fillEmbeds(main), fillQueries(main)]);
  },

  /** Scrolls to a heading by its text, or to a `^block` id. */
  scrollTo(anchor) {
    const main = document.getElementById("note");
    let target;
    if (anchor.startsWith("^")) target = main.querySelector(`[id="${CSS.escape(anchor)}"]`);
    else {
      const wanted = anchor.trim().replace(/\s+/g, " ").toLowerCase();
      target = [...main.querySelectorAll("[data-heading]")].find((h) => h.dataset.heading.replace(/\s+/g, " ").toLowerCase() === wanted);
    }
    target?.scrollIntoView({ block: "start" });
  },

  /** Scrolls to the block that holds a file line. */
  scrollToLine(line) {
    const blocks = [...document.querySelectorAll("#note [data-line]")];
    const target = blocks.filter((b) => Number(b.dataset.line) <= line).pop();
    target?.scrollIntoView({ block: "start" });
  },

  /** Selects the first place [text] is in the note. */
  find(text) {
    window.getSelection()?.removeAllRanges();
    window.find?.(text, false, false, true);
  },
};

document.addEventListener("click", (event) => {
  const box = event.target.closest("input.task-list-item-checkbox");
  if (box && !box.disabled) {
    event.preventDefault();
    post({ kind: "toggleTask", line: Number(box.dataset.line), status: box.dataset.status, path: box.dataset.path ?? "" });
    return;
  }
  const link = event.target.closest("a");
  if (!link) return;
  if (link.classList.contains("tag")) {
    event.preventDefault();
    post({ kind: "tag", tag: link.dataset.tag });
    return;
  }
  if (link.classList.contains("internal-link")) {
    event.preventDefault();
    const path = link.dataset.path;
    if (path === current.path && link.dataset.anchor) {
      window.daftar.scrollTo(link.dataset.anchor);
      return;
    }
    post({ kind: "open", path, target: link.dataset.target ?? "", anchor: link.dataset.anchor ?? "", newTab: event.metaKey });
    return;
  }
  const href = link.getAttribute("href") ?? "";
  if (href.startsWith("#")) {
    // A footnote, or a link to a heading in this note.
    const target = document.getElementById(decodeURIComponent(href.slice(1)));
    if (target) {
      event.preventDefault();
      target.scrollIntoView({ block: "center" });
    }
    return;
  }
  event.preventDefault();
  post({ kind: "external", url: link.href });
});

post({ kind: "ready" });
