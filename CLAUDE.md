%% tg:begin %%
# Before starting work

- Run `tg search` to find sections relevant to your task. Read them with `tg section` to understand the design intent before writing code.
- Run `tg expand` on user prompts to expand any `[[refs]]` — this resolves section names to file locations and provides context.
- Run `tg ontology` once per session to learn this project's types and edge types. Use those names; never invent a synonym for a relation the ontology already has.

# Post-task checklist (REQUIRED — do not skip)

After EVERY task, before responding to the user:

- [ ] Update `tg.md/` if you added or changed any functionality, architecture, decisions, tests, or behavior — as typed sections with typed edges (see below), not only prose
- [ ] Run `tg check` — all wiki links, code refs and annotations must pass
- [ ] Run `tg ontology check` — every typed edge you wrote must use a declared edge type with allowed endpoints and properties
- [ ] Do not skip these steps. Do not consider your task done until all three pass.

---

# What is lat.md?

This project keeps its intent — architecture, decisions, constraints, requirements and test specs — in the `tg.md/` directory as a **typed graph**: cross-linked markdown sections whose files have types (`Decision`, `Requirement`, `Constraint`, ...) and whose links have names (`motivated_by`, `constrains`, `implements`, ...) and properties (`since`, `ticket`, `confidence`). The `tg` CLI (Typed Graph) reads, checks and queries it, and is compatible with the lat.md format. Use it to ground your work in the actual architecture rather than guessing, and to answer questions with a query instead of a grep.

# Commands

```bash
tg search "natural language"  # find sections (lexical; hybrid with embeddings)
tg section "file#Section"     # read a section with its links and code references
tg locate "Section Name"      # find a section by name (exact, fuzzy)
tg refs "file#Section"        # what references a section
tg expand "user prompt text"  # expand [[refs]] to resolved locations
tg ontology                   # the project's types, edge types, endpoints and edge properties (from Types/)
tg ontology check             # typed edges in docs and code that the ontology does not allow
tg cypher "MATCH (d:Decision)-[r:motivated_by]->(c) RETURN d.title, c.title, r.since"   # query docs and code
tg edges --type implements    # typed edges written from code
tg check                      # validate links, code refs, indexes and annotations
tg migrate --dry-run          # from plain lat.md: type files, turn links into typed edges (see the tg-migrate skill)
```

Run `tg --help` when in doubt about available commands or options.

# The ontology

`Types/` holds the project's ontology as schema notes; `tg ontology` prints it, `tg.md/code-ontology.md` explains how to use it. The bundled code ontology has six types — **Decision**, **Requirement**, **Scenario**, **Constraint**, **Concept**, **Change** — and edge types such as `implements`, `verifies`, `-contradicts`, `supersedes`, `motivated_by`, `constrains`, `refines`, `depends_on`, `defines`, `changed_by`. A project may add its own types and edges to `Types/`: check `tg ontology` rather than assuming the list above, and use a domain type wherever it fits better than a generic one.

- **Type every file of intent.** Put `type:` in the frontmatter: `type: Decision` for `decisions.md`, `type: [Requirement, Scenario]` for a mixed file. Every section below the title gets that label in queries.
- **Name every relation.** When a section relates to another section, a requirement or code, write the relation as a typed edge line, not only as prose.
- **Put facts about a relation on the edge**: `{since: "2.3"}`, `{ticket: "PLAT-481", until: "2026-Q4"}`, `{confidence: partial}`, `{strength: must}`. `tg ontology` lists the properties each edge type takes.
- **The minus sign means disagreement** and nothing else: `-contradicts::` marks something knowingly in conflict.
- **A relation the ontology lacks** is a schema change: add the edge type to `Types/` (with `from`, `to` and properties) instead of inventing a one-off name, then use it.

# Writing typed docs

A section keeps its leading paragraph first; typed edge lines follow as a list. Each line is an ordinary `[[wiki link]]` for `tg check`, and a named edge with properties in the graph:

```markdown
---
type: Decision
---
# Decisions

Choices we made, with their reasons and the alternatives we rejected.

## Short-lived access tokens

Access tokens expire after 15 minutes and refresh tokens rotate on every use.

- motivated_by:: [[constraints#Session limit]] {weight: primary, since: "2.3"}
- supersedes:: [[decisions#Long-lived sessions]] {reason: "audit finding"}
- -contradicts:: [[decisions#Stateless gateway]] {ticket: "PLAT-481", until: "2026-Q4"}

The refresh endpoint keeps a small revocation list, which is why the gateway is no longer fully stateless.
```

Edges can point at sections (`[[file#Section]]`), at spec requirements and scenarios (OpenSpec, ADRs, e.g. `[[openspec:<capability>#<Requirement>]]`) and at code (`[[src/auth/token.ts#refresh]]`).

# Syntax primer

- **Section ids**: `tg.md/path/to/file#Heading#SubHeading` — full form uses the project-root-relative path. Short form uses the bare file name when unique (e.g. `search#RAG Replay Tests`).
- **Wiki links**: `[[target]]` or `[[target|alias]]` — cross-references between sections. Can also reference source code: `[[src/foo.ts#myFunction]]`, `[[src/server.ts#App#listen]]` (class method).
- **Typed doc edges**: `- type:: [[target]] {key: value}` on its own line in a section — a named edge from that section; `-type::` makes it negative.
- **Typed code edges**: `// @tg: implements:: [[decisions#Short-lived access tokens]] {since: "2.3"}` — a named edge from the next declaration; a bare `// @tg: [[x]]` or `// @lat: [[x]]` is a plain link.
- **Spec requirements** — `tg trace --gaps` shows what is unimplemented or unverified across every spec framework the project uses:
- **OpenSpec** (`openspec/specs/<capability>/spec.md`): point code at the requirement it realizes with `// @tg: implements:: [[openspec:<capability>#<Requirement>]]` and tests at the scenario they prove with `// @tg: verifies:: [[openspec:<capability>#<Requirement>#<Scenario>]]` directly above the `it(`. List what a lat.md file explains as `openspec: [<capability>]` in its frontmatter.
- **ADRs** (`docs/adr/0003-<title>.md`): point code at the decision it realizes with `// @tg: implements:: [[adr:0003]]`. List what a lat.md file explains as `specs: ["adr:0003"]` in its frontmatter.

# Questions to ask the graph

Use `tg cypher` (or the `tg_cypher` MCP tool) before reading files one by one; add `--code annotated` to include code:

```cypher
// Why does this decision exist?
MATCH (d:Decision {title: "Short-lived access tokens"})-[r]->(x) RETURN type(r), x.title, r
// Requirements nothing implements
MATCH (q:Requirement) OPTIONAL MATCH (c)-[i:implements]->(q) WITH q, count(i) AS n WHERE n = 0 RETURN q.title
// Known debt, with its ticket and deadline
MATCH (a)-[r:contradicts]->(b) RETURN a.title, b.title, r.ticket, r.until
```

# Test specs

Key tests can be described as sections in `tg.md/` files (e.g. `tests.md`, typed `Scenario`). Add frontmatter to require that every leaf section is referenced by an `@lat:` or `@tg:` comment in test code:

```markdown
---
type: Scenario
lat:
  require-code-mention: true
---
# Tests

## User login

Verify credential validation and error handling for the login endpoint.

### Rejects expired tokens
Tokens past their expiry timestamp are rejected with 401, even if otherwise valid.

- refines:: [[requirements#Token expiry]]
```

Each test references its spec with exactly one comment next to the test:

```python
# @lat: [[tests#User login#Rejects expired tokens]]
def test_rejects_expired_tokens():
    ...
```

`tg check` flags any spec section not covered by a code reference, and any reference to a nonexistent section.

# Section structure

Every section in `tg.md/` **must** have a leading paragraph — at least one sentence right after the heading, before any child heading or edge list. The first paragraph must be ≤250 characters (excluding `[[wiki link]]` content). It is the section's overview and is used in search results and command output.
%% tg:end %%
