// Check the built site in _site/: links, anchors, assets and the design-system page contract.
import { existsSync, readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const site = "_site";
const pages = ["index.html", "docs.html"];
const docs = new Map(pages.map((name) => [name, new JSDOM(readFileSync(`${site}/${name}`, "utf8")).window.document]));
const version = readFileSync("Sources/AgentCore/AgentKitVersion.swift", "utf8").match(/current = "([^"]+)"/)[1];
const local = (href) => !/^(https?:|mailto:|data:)/.test(href);
let links = 0;

for (const [name, doc] of docs) {
  for (const a of doc.querySelectorAll("a[href]")) {
    const href = a.getAttribute("href");
    if (!local(href)) continue;
    links++;
    const [path, hash] = href.split("#");
    const target = !path || path === "./" ? (path ? "index.html" : name) : path;
    assert.ok(existsSync(`${site}/${target}`), `${name}: missing ${href}`);
    if (hash) assert.ok(docs.get(target)?.getElementById(hash), `${name}: missing anchor ${href}`);
  }
  for (const element of doc.querySelectorAll("[src], link[href]")) {
    const path = (element.getAttribute("src") || element.getAttribute("href")).split(/[?#]/)[0];
    if (local(path)) assert.ok(existsSync(`${site}/${path}`), `${name}: missing asset ${path}`);
  }
}

// Every page is a design-system page in the plain layout with the shared masthead and footer.
const linkList = (root) => [...root.querySelectorAll("a")].map((a) => `${a.textContent.trim()} ${a.getAttribute("href")}`);
const glyphs = /[←-⇿⌀-⏿■-➿⤀-⥿⬀-⯿\u{1f300}-\u{1faff}]/u;
for (const name of pages) {
  const doc = docs.get(name);
  const body = doc.body;
  assert.ok(body.classList.contains("p9"), `${name}: body.p9`);
  assert.equal(body.dataset.layout, "plain", `${name}: plain layout only`);
  assert.equal(doc.querySelectorAll('[data-layout="field"], .p9-field').length, 0, `${name}: no field`);
  assert.ok(doc.querySelector('head link[rel=stylesheet][href="system/p9.css"]'), `${name}: p9.css`);
  assert.ok(doc.querySelector('head script[src="system/theme.js"]:not([type])'), `${name}: theme.js`);
  assert.ok(doc.querySelector('head script[type=module][src="system/p9.js"]'), `${name}: p9.js`);
  assert.equal(body.firstElementChild.className, "p9-masthead", `${name}: masthead first`);
  assert.equal(body.lastElementChild.className, "p9-footer", `${name}: footer last`);
  assert.deepEqual(linkList(doc.querySelector(".p9-masthead")), [
    "AgentKit ./",
    "Docs docs.html",
    "Changelog https://github.com/hugocxl/agentkit/blob/main/CHANGELOG.md",
    "GitHub https://github.com/hugocxl/agentkit",
  ]);
  assert.ok(doc.querySelector('.p9-masthead > button.p9-theme[data-p9-theme][aria-label] > svg.p9-icon[data-icon="contrast"]'), `${name}: theme button`);
  assert.deepEqual(linkList(doc.querySelector(".p9-footer")), [
    "Tab https://hugocxl.github.io/tab/",
    "Quickshot https://hugocxl.github.io/quickshot/",
    "AgentKit https://hugocxl.github.io/agentkit/",
    "GitHub https://github.com/hugocxl/agentkit",
    "License https://github.com/hugocxl/agentkit/blob/main/LICENSE",
    "@hugocxl https://github.com/hugocxl",
  ]);
  assert.ok(doc.querySelectorAll(".p9-accent, .p9-dot").length <= 2, `${name}: accent budget`);
  assert.ok(doc.querySelectorAll(".p9-button").length <= 1, `${name}: one filled button`);
  assert.equal(doc.querySelectorAll("main article.p9-column.p9-opening").length, 1, `${name}: one column`);
  assert.doesNotMatch(body.textContent, glyphs, `${name}: symbol character used as an icon`);
  for (const svg of doc.querySelectorAll("svg")) {
    assert.ok(svg.matches(".p9-icon[data-icon][aria-hidden=true], .p9-vector[data-vector][role=img]"), `${name}: svg outside the icon and vector sets`);
    assert.ok(!svg.closest(".p9-accent"), `${name}: artwork in accent`);
    assert.ok(!svg.hasAttribute("xmlns") && !svg.hasAttribute("color"), `${name}: vector attributes`);
    if (svg.matches(".p9-vector")) assert.ok(svg.querySelector("title")?.textContent.trim(), `${name}: vector title`);
  }
  for (const icon of doc.querySelectorAll(".p9-icon")) {
    assert.ok(existsSync(`website/art/icons/${icon.dataset.icon}.svg`), `${name}: unknown icon ${icon.dataset.icon}`);
  }
  for (const img of doc.querySelectorAll("img")) assert.ok(img.getAttribute("alt"), `${name}: img alt`);
  for (const table of doc.querySelectorAll("table")) {
    assert.ok(table.classList.contains("p9-table") && table.parentElement.matches(".p9-table-scroll[tabindex]"), `${name}: table wrapper`);
  }
  for (const pre of doc.querySelectorAll("pre")) {
    assert.ok(pre.matches(".p9-code > pre[tabindex] + button") || pre.parentElement.matches(".p9-code"), `${name}: code block`);
  }
}

// Recipe order, read from the article's children.
const kind = (el) =>
  el.matches(".p9-statement") ? "statement"
  : el.matches(".p9-title") ? "title"
  : el.matches(".p9-meta") ? "meta"
  : el.matches(".p9-section") ? "section"
  : el.matches("figure.p9-wide") ? "figure-wide"
  : el.matches("ul.p9-grid.p9-wide") ? "figure-grid"
  : el.matches(".p9-button") ? "button"
  : el.matches(".p9-form") ? "form"
  : `?${el.tagName}`;
const sequence = (name) => [...docs.get(name).querySelector("main article").children].map(kind).join(" ");

// home: masthead statement meta? section (figure-wide | figure-grid) section* (button | form)? footer
const home = docs.get("index.html");
assert.match(sequence("index.html"), /^statement( meta)? section (figure-wide|figure-grid)( section)*( button| form)?$/, `home order: ${sequence("index.html")}`);
assert.equal(home.querySelectorAll(".p9-dot").length, 1);
assert.equal(home.querySelectorAll(".p9-accent").length, 1);
assert.match(home.querySelector(".p9-meta").textContent, new RegExp(`Version ${version.replaceAll(".", "\\.")}`));
const grid = home.querySelector(".p9-grid");
assert.equal(grid.children.length, Number(grid.dataset.columns), "grid columns");
assert.equal(home.querySelector(".p9-button").getAttribute("href"), "docs.html");

// docs: masthead title meta? section (section | figure-wide)* footer
const docsPage = docs.get("docs.html");
assert.match(sequence("docs.html"), /^title( meta)? section( section| figure-wide)*$/, `docs order: ${sequence("docs.html")}`);
assert.equal(docsPage.querySelectorAll(".p9-accent").length, 0);
assert.ok(docsPage.querySelectorAll(".p9-section > h2").length >= 10, "docs sections");
assert.ok(docsPage.querySelectorAll(".p9-code > pre[tabindex] + button").length >= 6, "docs code blocks");
for (const id of ["install", "build-an-ai-first-app", "connect-your-app", "own-the-lifecycle", "serve-multiple-projects"]) {
  assert.ok(docsPage.getElementById(id), `docs: #${id}`);
}
assert.match(docsPage.body.textContent, new RegExp(`from: "${version.replaceAll(".", "\\.")}"`), "docs install version");

// Site CSS stays inside the design system's tokens.
const css = readFileSync("website/site.css", "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
assert.doesNotMatch(css, /#[0-9a-f]{3,8}\b|rgba?\(|hsla?\(|oklch\(/i, "site.css: literal color");
assert.doesNotMatch(css, /box-shadow|text-shadow|gradient|font-family|font-weight|border-radius:\s*\d/i, "site.css: off-token style");
for (const [, property] of css.matchAll(/var\((--[\w-]+)/g)) assert.match(property, /^--p9-/, `site.css: ${property}`);

console.log(`Site verified: ${pages.length} pages, ${links} local links.`);
