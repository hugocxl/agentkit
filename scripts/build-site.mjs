// Build the GitHub Pages site from website/ into _site/.
// Pages follow @hugocxl/design-system, with icons from @hugocxl/icons and figures from @hugocxl/vectors (npm dev dependencies).
// The docs, commands, validation and changelog pages are their Markdown files rendered into design-system sections.
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
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
const designSystem = dirname(createRequire(import.meta.url).resolve("@hugocxl/design-system/package.json"));
const svg = async (specifier) => String(Object.values(await import(specifier))[0]);
const icon = async (name) =>
  (await svg(`@hugocxl/icons/js/stroke/${name}`))
    .trim()
    .replace(/^<svg[^>]*>/, `<svg class="ds-icon" data-icon="${name}" viewBox="0 0 16 16" fill="none" aria-hidden="true">`)
    .replace(/\s*\n\s*/g, "");
const vector = async (name) =>
  (await svg(`@hugocxl/vectors/js/${name}`))
    .trim()
    .replace(/^<svg([^>]*)>/, (_, attributes) =>
      `<svg class="ds-vector" data-vector="${name}"${attributes.replace(/\s+xmlns="[^"]*"/, "").replace(/\s+color="[^"]*"/, "")}>`,
    )
    .replace(/\s*\n\s*/g, "");

// ─── Docs: Markdown files rendered into sections ────────────────────────
const slug = (text) => text.toLowerCase().replace(/[^\w\s-]/g, "").trim().replace(/\s+/g, "-");
const github = "https://github.com/hugocxl/agentkit/blob/main/";
// Markdown files with a page of their own; links to them stay on the site.
const pages = {
  "docs/INTEGRATION.md": "docs.html",
  "docs/commands.md": "commands.html",
  "docs/VALIDATION.md": "validation.html",
  "CHANGELOG.md": "changelog.html",
};
// A link from a file in docs/: `../X.md` is at the root, `X.md` beside it.
const pageFor = (href) => (href.startsWith("../") ? pages[href.slice(3)] : pages[`docs/${href}`]);
const renderer = new marked.Renderer();
renderer.code = ({ text }) =>
  `<div class="ds-code"><pre tabindex="0"><code>${escape(text)}</code></pre><button type="button">Copy</button></div>\n`;
const baseTable = renderer.table.bind(renderer);
renderer.table = (token) =>
  `<div class="ds-table-scroll" tabindex="0">${baseTable(token).replace("<table>", '<table class="ds-table">')}</div>\n`;
const baseTableHeader = renderer.tablecell.bind(renderer);
renderer.tablecell = (token) => baseTableHeader(token).replace(/^<th>/, '<th scope="col">');
renderer.link = function ({ href, title, tokens }) {
  const [path, hash] = href.split("#");
  const target = href.startsWith("https://hugocxl.github.io/agentkit/docs.html")
    ? "docs.html"
    : pageFor(path) ? pageFor(path) + (hash ? `#${hash}` : "")
    : href.replace(/^\.\.\/(.+)$/, `${github}$1`).replace(/^([\w-]+\.md)$/, `${github}docs/$1`);
  return `<a href="${escape(target)}"${title ? ` title="${escape(title)}"` : ""}>${this.parser.parseInline(tokens)}</a>`;
};

// One page's sections: each ## heading opens one. `subheadings` allows ### inside them,
// and `id` names a section from its heading text.
function renderMarkdown(path, { subheadings = false, id = slug } = {}) {
  const tokens = marked.lexer(read(path));
  let title = "Docs";
  const groups = [{ id: null, heading: null, tokens: [] }];
  for (const token of tokens) {
    if (token.type === "heading" && token.depth === 1) title = token.text;
    else if (token.type === "heading" && token.depth === 2) groups.push({ id: id(token.text), heading: token, tokens: [] });
    else if (token.type === "heading" && !(subheadings && token.depth === 3)) throw new Error(`${path}: use only # and ## headings (${token.raw.trim()})`);
    else groups.at(-1).tokens.push(token);
  }
  // The lead paragraph drops the sentence pointing readers of the Markdown file to this site.
  const lead = groups[0].tokens.find((token) => token.type === "paragraph");
  if (lead) lead.tokens = marked.lexer(lead.text.replace(/\s*This guide is also published at .*$/, ""))[0].tokens;
  const html = groups
    .filter((group) => group.heading || group.tokens.some((token) => token.type !== "space"))
    .map((group) => {
      const body = marked.parser(Object.assign(group.tokens, { links: tokens.links }), { renderer });
      const heading = group.heading ? `        <h2>${marked.parseInline(group.heading.text)}</h2>\n` : "";
      return `      <section class="ds-section"${group.id ? ` id="${group.id}"` : ""}>\n${heading}${body}      </section>`;
    })
    .join("\n");
  return { title, html };
}

const integration = renderMarkdown("docs/INTEGRATION.md");
const commands = renderMarkdown("docs/commands.md");
const validation = renderMarkdown("docs/VALIDATION.md");
// Each release is a section named for its version, such as #v1-5-0.
const changelog = renderMarkdown("CHANGELOG.md", { subheadings: true, id: (text) => `v${text.split(" ")[0].replaceAll(".", "-")}` });

// ─── Templates ──────────────────────────────────────────────────────────
const partial = (name) => read(`website/partials/${name}.html`).replace(/\n$/, "");
// Inline artwork after the partials go in, since the masthead carries an icon.
const replaceAsync = async (text, pattern, replace) => {
  const parts = await Promise.all([...text.matchAll(pattern)].map((match) => replace(...match)));
  return text.replace(pattern, () => parts.shift());
};
async function render(template, values) {
  let html = template
    .replace(/\{\{head ([^}]*)\}\}/, (_, args) => {
      const attributes = Object.fromEntries([...args.matchAll(/(\w+)="([^"]*)"/g)].map((m) => [m[1], m[2]]));
      return partial("head").replace(/\{\{(\w+)\}\}/g, (__, key) => attributes[key] ?? "");
    })
    .replace("{{masthead}}", partial("masthead"))
    .replace("{{footer}}", partial("footer"));
  html = await replaceAsync(html, /\{\{icon ([\w-]+)\}\}/g, (_, name) => icon(name));
  html = await replaceAsync(html, /\{\{vector ([\w-]+)\}\}/g, (_, name) => vector(name));
  html = html.replace(/\{\{([\w-]+)\}\}/g, (match, key) => (key in values ? values[key] : match));
  const unknown = html.match(/\{\{[^}]*\}\}/);
  if (unknown) throw new Error(`Unknown template value ${unknown[0]}`);
  return html;
}

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
cpSync(join(designSystem, "system"), `${out}/system`, { recursive: true, filter: (path) => !path.endsWith(".DS_Store") });
cpSync("website/site.css", `${out}/site.css`);

const values = {
  ...facts,
  docs: integration.html,
  "docs-title": escape(integration.title),
  commands: commands.html,
  "commands-title": escape(commands.title),
  validation: validation.html,
  "validation-title": escape(validation.title),
  changelog: changelog.html,
};
for (const page of ["index.html", ...Object.values(pages)]) {
  writeFileSync(`${out}/${page}`, await render(read(`website/${page}`), values));
}
writeFileSync(`${out}/.nojekyll`, "");
console.log(`Built the AgentKit ${version} site.`);
