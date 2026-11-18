// Build the GitHub Pages site from website/ into _site/.
// Pages follow the design system vendored in website/system (see scripts/sync-design-system.mjs).
// The docs page is docs/INTEGRATION.md rendered into design-system sections.
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { marked } from "marked";

const out = "_site";
const read = (path) => readFileSync(path, "utf8");
const escape = (text) =>
  String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// ─── Facts from the package ─────────────────────────────────────────────
const version = read("Sources/AgentCore/AgentKitVersion.swift").match(/current = "([^"]+)"/)?.[1];
if (!version) throw new Error("No version in AgentKitVersion.swift");
const release = read("CHANGELOG.md").match(/^## (\S+) - (\d{4}-\d{2}-\d{2})$/m);
if (!release || release[1] !== version) throw new Error(`CHANGELOG.md does not start with ${version}`);
const date = new Date(`${release[2]}T00:00:00Z`);
const facts = {
  version,
  "release-datetime": release[2],
  "release-date": date.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }),
};

// ─── Artwork: Stroke icons from @hugocxl/icons, figures from @hugocxl/vectors ─
const icon = (name) =>
  read(`website/art/icons/${name}.svg`)
    .trim()
    .replace(/^<svg[^>]*>/, `<svg class="ds-icon" data-icon="${name}" viewBox="0 0 16 16" fill="none" aria-hidden="true">`)
    .replace(/\s*\n\s*/g, "");
const vector = (name) =>
  read(`website/art/vectors/${name}.svg`)
    .trim()
    .replace(/^<svg([^>]*)>/, (_, attributes) =>
      `<svg class="ds-vector" data-vector="${name}"${attributes.replace(/\s+xmlns="[^"]*"/, "").replace(/\s+color="[^"]*"/, "")}>`,
    )
    .replace(/\s*\n\s*/g, "");

// ─── Docs: docs/INTEGRATION.md rendered into sections ───────────────────
const slug = (text) => text.toLowerCase().replace(/[^\w\s-]/g, "").trim().replace(/\s+/g, "-");
const github = "https://github.com/hugocxl/agentkit/blob/main/";
const renderer = new marked.Renderer();
renderer.code = ({ text }) =>
  `<div class="ds-code"><pre tabindex="0"><code>${escape(text)}</code></pre><button type="button">Copy</button></div>\n`;
const baseTable = renderer.table.bind(renderer);
renderer.table = (token) =>
  `<div class="ds-table-scroll" tabindex="0">${baseTable(token).replace("<table>", '<table class="ds-table">')}</div>\n`;
const baseTableHeader = renderer.tablecell.bind(renderer);
renderer.tablecell = (token) => baseTableHeader(token).replace(/^<th>/, '<th scope="col">');
renderer.link = function ({ href, title, tokens }) {
  const target = href
    .replace(/^https:\/\/hugocxl\.github\.io\/agentkit\/docs\.html$/, "docs.html")
    .replace(/^\.\.\/(.+)$/, `${github}$1`)
    .replace(/^([\w-]+\.md)$/, `${github}docs/$1`);
  return `<a href="${escape(target)}"${title ? ` title="${escape(title)}"` : ""}>${this.parser.parseInline(tokens)}</a>`;
};

const tokens = marked.lexer(read("docs/INTEGRATION.md"));
let docsTitle = "Docs";
const groups = [{ id: null, heading: null, tokens: [] }];
for (const token of tokens) {
  if (token.type === "heading" && token.depth === 1) docsTitle = token.text;
  else if (token.type === "heading" && token.depth === 2) groups.push({ id: slug(token.text), heading: token, tokens: [] });
  else if (token.type === "heading") throw new Error(`docs/INTEGRATION.md: use only # and ## headings (${token.raw.trim()})`);
  else groups.at(-1).tokens.push(token);
}
// The lead paragraph drops the sentence pointing readers of the Markdown file to this page.
const lead = groups[0].tokens.find((token) => token.type === "paragraph");
if (lead) lead.tokens = marked.lexer(lead.text.replace(/\s*This guide is also published at .*$/, ""))[0].tokens;
const docs = groups
  .filter((group) => group.heading || group.tokens.some((token) => token.type !== "space"))
  .map((group) => {
    const body = marked.parser(Object.assign(group.tokens, { links: tokens.links }), { renderer });
    const heading = group.heading ? `        <h2>${marked.parseInline(group.heading.text)}</h2>\n` : "";
    return `      <section class="ds-section"${group.id ? ` id="${group.id}"` : ""}>\n${heading}${body}      </section>`;
  })
  .join("\n");

// ─── Templates ──────────────────────────────────────────────────────────
const partial = (name) => read(`website/partials/${name}.html`).replace(/\n$/, "");
function render(template, values) {
  const html = template
    .replace(/\{\{head ([^}]*)\}\}/, (_, args) => {
      const attributes = Object.fromEntries([...args.matchAll(/(\w+)="([^"]*)"/g)].map((m) => [m[1], m[2]]));
      return partial("head").replace(/\{\{(\w+)\}\}/g, (__, key) => attributes[key] ?? "");
    })
    .replace("{{masthead}}", partial("masthead"))
    .replace("{{footer}}", partial("footer"))
    .replace(/\{\{icon ([\w-]+)\}\}/g, (_, name) => icon(name))
    .replace(/\{\{vector ([\w-]+)\}\}/g, (_, name) => vector(name))
    .replace(/\{\{([\w-]+)\}\}/g, (match, key) => (key in values ? values[key] : match));
  const unknown = html.match(/\{\{[^}]*\}\}/);
  if (unknown) throw new Error(`Unknown template value ${unknown[0]}`);
  return html;
}

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
cpSync("website/system", `${out}/system`, { recursive: true, filter: (path) => !path.endsWith(".DS_Store") });
cpSync("website/site.css", `${out}/site.css`);

const values = { ...facts, docs, "docs-title": escape(docsTitle) };
for (const page of ["index.html", "docs.html"]) {
  writeFileSync(`${out}/${page}`, render(read(`website/${page}`), values));
}
writeFileSync(`${out}/.nojekyll`, "");
console.log(`Built the AgentKit ${version} site.`);
