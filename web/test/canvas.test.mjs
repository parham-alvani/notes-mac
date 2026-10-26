import { test } from "node:test";
import assert from "node:assert/strict";
import { renderCanvas, canvasColor, edgeGeometry, bounds, fit } from "../src/canvas.js";

const node = (id, type, x, y, extra = {}) => ({ id, type, x, y, width: 200, height: 100, ...extra });

test("a colour is a preset in the palette's colour, a hex, or nothing", () => {
  assert.equal(canvasColor("red"), "var(--red)");
  assert.equal(canvasColor("green"), "var(--spring-green)");
  assert.equal(canvasColor("cyan"), "var(--aqua)");
  assert.equal(canvasColor("#a0b1c2"), "#a0b1c2");
  assert.equal(canvasColor("red; background: url(x)"), null);
  assert.equal(canvasColor(undefined), null);
});

test("an edge leaves the side that faces the other card, with an arrow at its end", () => {
  const a = node("a", "text", 0, 0), b = node("b", "text", 400, 0);
  const shape = edgeGeometry(a, b, { toEnd: "arrow", fromEnd: "none" });
  assert.match(shape.d, /^M 200 50 C .* 400 50$/);
  assert.equal(shape.arrows.length, 1);
  assert.deepEqual(shape.label, { x: 300, y: 50 });
  // A named side wins, and an arrow at both ends is two arrows.
  const down = edgeGeometry(a, b, { fromSide: "bottom", toSide: "top", fromEnd: "arrow", toEnd: "arrow" });
  assert.match(down.d, /^M 100 100 C .* 500 0$/);
  assert.equal(down.arrows.length, 2);
  assert.equal(edgeGeometry(a, b, { toEnd: "none" }).arrows.length, 0);
});

test("the board draws each kind of card, groups under them, and labels on top", () => {
  const html = renderCanvas(
    {
      nodes: [
        node("t", "text", 0, 0, { text: "**Hi** [[Inbox]]", color: "red" }),
        node("f", "file", 300, 0, { file: "Notes/Inbox.md", path: "Notes/Inbox.md", subpath: "#Part" }),
        node("i", "file", 600, 0, { file: "a b.png", path: "uploads/a b.png" }),
        node("m", "file", 900, 0, { file: "Gone.md" }),
        node("l", "link", 0, 300, { url: "https://example.com/x" }),
        node("g", "group", -50, -50, { label: "Week", color: "#ff0000" }),
      ],
      edges: [{ id: "e", fromNode: "t", toNode: "f", toEnd: "arrow", fromEnd: "none", label: "next", color: "cyan" }, { id: "x", fromNode: "t", toNode: "nowhere" }],
    },
    { path: "Board.canvas", links: { Inbox: "Notes/Inbox.md" } },
  );
  assert.match(html, /class="canvas-node canvas-text is-tinted" data-id="t" style="left: 0px; top: 0px; width: 200px; height: 100px; --node-color: var\(--red\)"/);
  assert.match(html, /<strong>Hi<\/strong> <a class="internal-link"[^>]*data-path="Notes\/Inbox.md"/);
  assert.match(html, /data-open="Notes\/Inbox.md"/);
  assert.match(html, /class="embed canvas-embed" data-path="Notes\/Inbox.md" data-anchor="Part"/);
  assert.match(html, /<img src="vault:\/\/\/uploads\/a%20b.png"/);
  assert.match(html, /Not in the vault/);
  assert.match(html, /<a class="canvas-link-card" href="https:\/\/example.com\/x"><span class="canvas-link-host">example.com<\/span>/);
  assert.match(html, /class="canvas-group is-tinted"[^>]*--node-color: #ff0000"><div class="canvas-group-label" dir="auto">Week<\/div>/);
  assert.match(html, /<g class="canvas-edge" style="--edge-color: var\(--aqua\)"><path d="M /);
  assert.match(html, /class="canvas-edge-label"[^>]*>next<\/div>/);
  // The group comes first, the edges' label last; an edge to a missing card is not drawn.
  assert.ok(html.indexOf("canvas-group") < html.indexOf("canvas-edges") && html.indexOf("canvas-edges") < html.indexOf('data-id="t"'));
  assert.equal(html.match(/<g class="canvas-edge"/g).length, 1);
});

test("a link card shows only a web address as a link", () => {
  assert.doesNotMatch(renderCanvas({ nodes: [node("l", "link", 0, 0, { url: "javascript:alert(1)" })] }), /href=/);
});

test("fit shows the whole board, never larger than life", () => {
  const box = bounds([node("a", "text", 0, 0), node("b", "text", 1800, 900)]);
  assert.deepEqual(box, { x: 0, y: 0, width: 2000, height: 1000 });
  const view = fit(box, 1080, 580);
  assert.equal(view.scale, 0.5);
  assert.equal(fit(bounds([node("a", "text", 0, 0)]), 2000, 2000).scale, 1);
  assert.match(renderCanvas({ nodes: [], edges: [] }), /The canvas is empty/);
});
