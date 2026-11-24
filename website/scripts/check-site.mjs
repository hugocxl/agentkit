// Check the built site in _site/: links, anchors, assets and the design-system page contract.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const site = "_site";
const pages = ["index.html", "docs.html", "commands.html", "validation.html", "changelog.html"];
const docs = new Map(pages.map((name) => [name, new JSDOM(readFileSync(`${site}/${name}`, "utf8")).window.document]));
const version = readFileSync("../Sources/AgentCore/AgentKitVersion.swift", "utf8").match(/current = "([^"]+)"/)[1];
const local = (href) => !/^(https?:|mailto:|data:)/.test(href);
let links = 0;

// _site/system is the published @hugocxl/design-system system/ folder, byte for byte.
const system = join(dirname(createRequire(import.meta.url).resolve("@hugocxl/design-system/package.json")), "system");
const files = (root) =>
  readdirSync(root, { recursive: true })
    .map(String)
    .filter((path) => statSync(join(root, path)).isFile() && !path.endsWith(".DS_Store"))
    .sort();
assert.deepEqual(files(`${site}/system`), files(system), "system: files differ from @hugocxl/design-system");
for (const path of files(system)) {
  assert.ok(readFileSync(join(system, path)).equals(readFileSync(join(`${site}/system`, path))), `system: ${path} differs from @hugocxl/design-system`);
}

// Inline artwork matches the packages: same viewBox and drawing as the Stroke icon or vector of that name.
const parse = (markup) => JSDOM.fragment(markup.trim()).firstElementChild;
const artwork = async (specifier) => parse(String(Object.values(await import(specifier))[0]));
const packaged = new Map();
const original = (svg) => {
  const key = svg.matches(".ds-icon") ? `@hugocxl/icons/js/stroke/${svg.dataset.icon}` : `@hugocxl/vectors/js/${svg.dataset.vector}`;
  if (!packaged.has(key)) packaged.set(key, artwork(key).catch(() => null));
  return packaged.get(key);
};
const drawing = (svg) => svg.innerHTML.replace(/\s*\n\s*/g, "");

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
  assert.ok(body.classList.contains("ds"), `${name}: body.ds`);
  assert.equal(body.dataset.layout, "plain", `${name}: plain layout only`);
  assert.equal(doc.querySelectorAll('[data-layout="field"], .ds-field').length, 0, `${name}: no field`);
  assert.ok(doc.querySelector('head link[rel=stylesheet][href="system/ds.css"]'), `${name}: ds.css`);
  assert.ok(doc.querySelector('head script[src="system/theme.js"]:not([type])'), `${name}: theme.js`);
  assert.ok(doc.querySelector('head script[type=module][src="system/ds.js"]'), `${name}: ds.js`);
  assert.equal(body.firstElementChild.className, "ds-masthead", `${name}: masthead first`);
  assert.equal(body.lastElementChild.className, "ds-footer", `${name}: footer last`);
  assert.deepEqual(linkList(doc.querySelector(".ds-masthead")), [
    "AgentKit ./",
    "Docs docs.html",
    "Changelog changelog.html",
    "GitHub https://github.com/hugocxl/agentkit",
  ]);
  assert.ok(doc.querySelector('.ds-masthead > button.ds-theme[data-ds-theme][aria-label] > svg.ds-icon[data-icon="contrast"]'), `${name}: theme button`);
  assert.deepEqual(linkList(doc.querySelector(".ds-footer")), [
    "Tab https://hugocxl.github.io/tab/",
    "Quickshot https://hugocxl.github.io/quickshot/",
    "AgentKit https://hugocxl.github.io/agentkit/",
    "GitHub https://github.com/hugocxl/agentkit",
    "License https://github.com/hugocxl/agentkit/blob/main/LICENSE",
    "@hugocxl https://github.com/hugocxl",
  ]);
  assert.ok(doc.querySelectorAll(".ds-accent, .ds-dot").length <= 2, `${name}: accent budget`);
  assert.ok(doc.querySelectorAll(".ds-button").length <= 1, `${name}: one filled button`);
  assert.equal(doc.querySelectorAll("main article.ds-column.ds-opening").length, 1, `${name}: one column`);
  assert.doesNotMatch(body.textContent, glyphs, `${name}: symbol character used as an icon`);
  for (const svg of doc.querySelectorAll("svg")) {
    assert.ok(svg.matches(".ds-icon[data-icon][aria-hidden=true], .ds-vector[data-vector][role=img]"), `${name}: svg outside the icon and vector sets`);
    assert.ok(!svg.closest(".ds-accent"), `${name}: artwork in accent`);
    assert.ok(!svg.hasAttribute("xmlns") && !svg.hasAttribute("color"), `${name}: vector attributes`);
    if (svg.matches(".ds-vector")) assert.ok(svg.querySelector("title")?.textContent.trim(), `${name}: vector title`);
  }
  for (const svg of doc.querySelectorAll(".ds-icon, .ds-vector")) {
    const label = svg.dataset.icon ?? svg.dataset.vector;
    const source = await original(svg);
    assert.ok(source, `${name}: ${label} is not in the package`);
    assert.equal(svg.getAttribute("viewBox"), source.getAttribute("viewBox"), `${name}: ${label} viewBox`);
    assert.equal(drawing(svg), drawing(source), `${name}: ${label} differs from the package`);
  }
  for (const img of doc.querySelectorAll("img")) assert.ok(img.getAttribute("alt"), `${name}: img alt`);
  for (const table of doc.querySelectorAll("table")) {
    assert.ok(table.classList.contains("ds-table") && table.parentElement.matches(".ds-table-scroll[tabindex]"), `${name}: table wrapper`);
  }
  for (const pre of doc.querySelectorAll("pre")) {
    assert.ok(pre.matches(".ds-code > pre[tabindex] + button") || pre.parentElement.matches(".ds-code"), `${name}: code block`);
  }
}

// Recipe order, read from the article's children.
const kind = (el) =>
  el.matches(".ds-statement") ? "statement"
  : el.matches(".ds-title") ? "title"
  : el.matches(".ds-meta") ? "meta"
  : el.matches(".ds-section") ? "section"
  : el.matches("figure.ds-wide") ? "figure-wide"
  : el.matches("ul.ds-grid.ds-wide") ? "figure-grid"
  : el.matches(".ds-button") ? "button"
  : el.matches(".ds-form") ? "form"
  : `?${el.tagName}`;
const sequence = (name) => [...docs.get(name).querySelector("main article").children].map(kind).join(" ");

// home: masthead statement meta? section (figure-wide | figure-grid) section* (button | form)? footer
const home = docs.get("index.html");
assert.match(sequence("index.html"), /^statement( meta)? section (figure-wide|figure-grid)( section)*( button| form)?$/, `home order: ${sequence("index.html")}`);
assert.equal(home.querySelectorAll(".ds-dot").length, 1);
assert.equal(home.querySelectorAll(".ds-accent").length, 1);
assert.match(home.querySelector(".ds-meta").textContent, new RegExp(`Version ${version.replaceAll(".", "\\.")}`));
const grid = home.querySelector(".ds-grid");
assert.equal(grid.children.length, Number(grid.dataset.columns), "grid columns");
assert.equal(home.querySelector(".ds-button").getAttribute("href"), "docs.html");

// docs: masthead title meta? section (section | figure-wide)* footer
const docsPage = docs.get("docs.html");
assert.match(sequence("docs.html"), /^title( meta)? section( section| figure-wide)*$/, `docs order: ${sequence("docs.html")}`);
assert.equal(docsPage.querySelectorAll(".ds-accent").length, 0);
assert.ok(docsPage.querySelectorAll(".ds-section > h2").length >= 10, "docs sections");
assert.ok(docsPage.querySelectorAll(".ds-code > pre[tabindex] + button").length >= 6, "docs code blocks");
for (const id of ["install", "build-an-ai-first-app", "connect-your-app", "own-the-lifecycle", "serve-multiple-projects"]) {
  assert.ok(docsPage.getElementById(id), `docs: #${id}`);
}
assert.match(docsPage.body.textContent, new RegExp(`from: "${version.replaceAll(".", "\\.")}"`), "docs install version");
assert.ok(docsPage.getElementById("choose-providers"), "docs: #choose-providers");

// commands, validation, changelog: masthead title meta? section+ footer
for (const name of ["commands.html", "validation.html", "changelog.html"]) {
  assert.match(sequence(name), /^title( meta)? section( section)*$/, `${name} order: ${sequence(name)}`);
  assert.equal(docs.get(name).querySelectorAll(".ds-accent").length, 0, `${name}: no accent`);
}
assert.ok(docs.get("commands.html").querySelectorAll(".ds-section > h2").length >= 4, "commands sections");
// The changelog starts with the package's version, and every release has its own anchor.
const releases = [...docs.get("changelog.html").querySelectorAll(".ds-section[id]")];
assert.equal(releases[0]?.id, `v${version.replaceAll(".", "-")}`, "changelog starts with the current version");
assert.equal(releases.length, (readFileSync("../CHANGELOG.md", "utf8").match(/^## /gm) ?? []).length, "changelog releases");
// Docs links to the other Markdown files stay on the site.
for (const a of docsPage.querySelectorAll("a[href]")) {
  assert.doesNotMatch(a.getAttribute("href"), /\/(commands|VALIDATION|CHANGELOG)\.md/, `docs: ${a.getAttribute("href")} should link to its page`);
}

// Site CSS stays inside the design system's tokens.
const css = readFileSync("site.css", "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
assert.doesNotMatch(css, /#[0-9a-f]{3,8}\b|rgba?\(|hsla?\(|oklch\(/i, "site.css: literal color");
assert.doesNotMatch(css, /box-shadow|text-shadow|gradient|font-family|font-weight|border-radius:\s*\d/i, "site.css: off-token style");
for (const [, property] of css.matchAll(/var\((--[\w-]+)/g)) assert.match(property, /^--ds-/, `site.css: ${property}`);

console.log(`Site verified: ${pages.length} pages, ${links} local links.`);
