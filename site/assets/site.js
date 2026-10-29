// typedb-lean website: shared header and footer, theme toggle, and a small highlighter for
// Lean, TypeQL and shell. Every page sets <body data-root="." data-page="home">; data-root is
// the relative path back to the site root, so the site works under any GitHub Pages prefix.

(function () {
  const REPO = "https://github.com/Volland/typedb-lean";
  const BOOK = "https://leanpub.com/typedbforedgeaiagents";

  const body = document.body;
  const root = body.dataset.root || ".";
  const page = body.dataset.page || "";
  const r = (p) => root + "/" + p;

  // Theme: remembered per viewer; storage may be unavailable.
  const stored = (() => { try { return localStorage.getItem("theme"); } catch (_) { return null; } })();
  if (stored) document.documentElement.dataset.theme = stored;
  function toggleTheme() {
    const cur = document.documentElement.dataset.theme ||
      (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    const next = cur === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem("theme", next); } catch (_) {}
  }

  const links = [
    ["home", "index.html", "Home"],
    ["guide", "guide.html", "Guide"],
    ["examples", "examples.html", "Examples"],
    ["benchmarks", "benchmarks.html", "Benchmarks"],
    ["book", "book/index.html", "Book"],
    ["api", "api/TypeDB.html", "API"],
  ];

  const header = document.createElement("header");
  header.className = "site-header";
  header.innerHTML = `
    <div class="inner">
      <a class="brand" href="${r("index.html")}"><span class="logo">λ</span>typedb-lean</a>
      <button class="menu-toggle" aria-label="Menu" aria-expanded="false">☰</button>
      <nav class="nav">
        ${links.map(([id, href, label]) =>
          `<a href="${r(href)}"${id === page ? ' aria-current="page"' : ""}>${label}</a>`).join("")}
        <a href="${REPO}">GitHub</a>
        <button class="theme-toggle" aria-label="Toggle dark mode" title="Toggle dark mode">◐</button>
      </nav>
    </div>`;
  body.prepend(header);
  header.querySelector(".theme-toggle").addEventListener("click", toggleTheme);
  const menu = header.querySelector(".menu-toggle");
  menu.addEventListener("click", () => {
    const nav = header.querySelector(".nav");
    nav.classList.toggle("open");
    menu.setAttribute("aria-expanded", nav.classList.contains("open"));
  });

  const footer = document.createElement("footer");
  footer.className = "site-footer";
  footer.innerHTML = `
    <div class="container cols">
      <div>
        <a class="brand" href="${r("index.html")}"><span class="logo">λ</span>typedb-lean</a>
        <p style="margin-top:.8rem">A TypeDB 3 client for Lean 4, built on the official C driver. Apache-2.0.</p>
      </div>
      <div><h4>Learn</h4><ul>
        <li><a href="${r("guide.html")}">Guide</a></li>
        <li><a href="${r("examples.html")}">Examples</a></li>
        <li><a href="${r("book/index.html")}">The mini book</a></li>
        <li><a href="${r("api/TypeDB.html")}">API reference</a></li>
      </ul></div>
      <div><h4>Project</h4><ul>
        <li><a href="${REPO}">Source</a></li>
        <li><a href="${REPO}/blob/main/CHANGELOG.md">Changelog</a></li>
        <li><a href="${r("benchmarks.html")}">Benchmarks</a></li>
        <li><a href="${REPO}/issues">Issues</a></li>
      </ul></div>
      <div><h4>Go deeper</h4><ul>
        <li><a href="${BOOK}">TypeDB for Edge AI Agents</a></li>
        <li><a href="https://typedb.com/docs">TypeDB docs</a></li>
        <li><a href="https://lean-lang.org/documentation/">Lean docs</a></li>
      </ul></div>
    </div>`;
  body.append(footer);

  // ---- Highlighter -------------------------------------------------------------------------

  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const set = (words) => new Set(words.split(/\s+/));

  const LEAN_KW = set(`def theorem example structure inductive class instance where deriving import open
    namespace end section variable let mut fun do return match with if then else for in try catch
    throw finally unless break continue by have show from at abbrev private protected partial
    extends noncomputable universe macro syntax macro_rules typeql! s! discard pure`);
  const TQL_KW = set(`define undefine redefine insert delete update put match fetch reduce select sort
    limit offset entity relation attribute owns plays relates sub isa has links value fun return
    try not or of from count sum max min mean let in first check distinct true false asc desc`);
  const TQL_TYPES = set(`string integer double decimal boolean date datetime datetime-tz duration`);

  const rules = {
    lean: [
      [/\/-[\s\S]*?-\//y, "com"],
      [/--.*/y, "com"],
      [/"(?:\\.|[^"\\])*"/y, "str"],
      [/@\[[^\]]*\]/y, "attr"],
      [/(?<![\p{L}\p{N}_])\.[a-z][\w]*/uy, "num"],
      [/\b\d+(?:\.\d+)?\b/y, "num"],
      [/[\p{L}_][\p{L}\p{N}_'!?.]*/uy, (w) => LEAN_KW.has(w) ? "kw" : /^[A-Z]/.test(w) ? "type" : null],
    ],
    typeql: [
      [/#.*/y, "com"],
      [/"(?:\\.|[^"\\])*"/y, "str"],
      [/\$[\w-]+/y, "var"],
      [/@[\w]+/y, "attr"],
      [/\b\d+(?:\.\d+)?(?:dec)?\b/y, "num"],
      [/[A-Za-z_][\w-]*/y, (w) => TQL_KW.has(w) ? "kw" : TQL_TYPES.has(w) ? "type" : null],
    ],
    sh: [
      [/(?:^|(?<=\s))#.*/my, "com"],
      [/"(?:\\.|[^"\\])*"|'[^']*'/y, "str"],
      [/\$\{?\w+\}?/y, "var"],
      [/--?[\w-]+/y, "attr"],
      [/\b(?:lake|docker|cargo|git|cd|curl|export)\b/y, "kw"],
    ],
    text: [
      [/\berror\b:?/y, "err"],
    ],
  };

  function highlight(src, lang) {
    const rs = rules[lang];
    if (!rs) return esc(src);
    let out = "", plain = "", i = 0;
    const flush = () => { out += esc(plain); plain = ""; };
    outer: while (i < src.length) {
      for (const [re, cls] of rs) {
        re.lastIndex = i;
        const m = re.exec(src);
        if (m && m.index === i && m[0].length) {
          const c = typeof cls === "function" ? cls(m[0]) : cls;
          if (c) { flush(); out += `<span class="tok-${c}">${esc(m[0])}</span>`; }
          else plain += m[0];
          i += m[0].length;
          continue outer;
        }
      }
      plain += src[i++];
    }
    flush();
    return out;
  }

  const names = { lean: "Lean", typeql: "TypeQL", sh: "shell", text: "output" };
  document.querySelectorAll("pre > code[class*='lang-']").forEach((code) => {
    const lang = (code.className.match(/lang-(\w+)/) || [])[1];
    code.innerHTML = highlight(code.textContent.replace(/^\n/, ""), lang);
    code.parentElement.dataset.lang = names[lang] || lang;
  });
})();
