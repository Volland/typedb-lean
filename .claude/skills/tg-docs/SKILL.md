---
name: tg-docs
description: Write and maintain the tg.md/ documentation folder as a typed graph with the tg CLI - typed files (Decision, Requirement, Constraint, ...), named edges with properties between sections, requirements and code, checked against the project ontology in Types/. Use when creating, editing or reviewing files in tg.md/, recording a decision or constraint, or linking code to docs with @lat or @tg comments.
---

# Maintaining tg.md/ as a typed graph

`tg.md/` records what the project does and why. With `tg` it is not just linked Markdown: files have **types**, links have **names and properties**, and the project's **ontology** in `Types/` says which types and edges exist. Plain untyped sections and bare wiki links are what lat.md already gives you; use the graph.

## Workflow

1. **Learn the vocabulary.** `tg ontology` lists the types, the edge types with their endpoints, and the properties each edge takes. Read it once per session, and again whenever you need a relation you have not used yet. The project may have added its own types and edges to `Types/`: prefer a fitting domain type over a generic one.
2. **Find what exists.** `tg search "<topic>"`, then `tg section "<id>"`. Extend a section instead of duplicating it. For relations, ask the graph: `tg cypher "MATCH (s {title: '<title>'})-[r]-(x) RETURN type(r), x.title, r"`.
3. **Write typed.** Put new content in the file whose `type:` matches it (`decisions.md` for a Decision, `constraints.md` for a Constraint, ...); create the file with the right `type:` frontmatter if it does not exist, and list it in the index.
4. **Name every relation** as a typed edge line after the section's leading paragraph, with the facts about the relation as properties.
5. **Link the code**: `// @tg: implements:: [[...]]` above the declarations that realize the section or requirement.
6. **Check**: `tg check` (links, structure) and `tg ontology check` (edge names, endpoints, properties) until both pass.

## Typed files

```markdown
---
type: Decision            # or [Requirement, Scenario] for a mixed file
---
# Decisions
```

Every section below the title gets the label, so `MATCH (d:Decision)` finds it. Pick the type by what the text *is*:

| The text says | Type |
| --- | --- |
| we chose X over Y because Z | `Decision` (an ADR is one) |
| the system SHALL ... | `Requirement` |
| given / when / then, a checkable example | `Scenario` |
| a rule nobody here chose: law, SLA, platform limit | `Constraint` |
| what a domain term means exactly | `Concept` |
| a unit of work moving intent and code together | `Change` |

## Typed edges

After the leading paragraph, one edge per line. Each is an ordinary `[[wiki link]]` for `tg check` and a named edge in the graph:

```markdown
## Short-lived access tokens

Access tokens expire after 15 minutes and refresh tokens rotate on every use.

- motivated_by:: [[constraints#Session limit]] {weight: primary}
- supersedes:: [[decisions#Long-lived sessions]] {since: "2.3", reason: "audit finding"}
- -contradicts:: [[decisions#Stateless gateway]] {ticket: "PLAT-481", until: "2026-Q4"}
```

- The edge starts at the section the line is in and ends at a section, a spec requirement or scenario of any framework (`[[openspec:auth#Token expiry]]`, `[[speckit:001-auth#FR-001]]`, `[[kiro:auth#Requirement 1#1.2]]`, `[[adr:0003]]`), or code (`[[src/auth/token.ts#refresh]]`).
- Use only edge names `tg ontology` lists. The direction matters: `motivated_by` goes from the Decision to its reason.
- **Facts about the relation go in `{...}`**: dates and versions (`since`, `until`), tickets, `confidence`, `strength`, `weight`, `reason`. Use the properties the edge type declares; a sentence may explain more, but only a property can be queried.
- A leading `-` (`-contradicts::`) means a known conflict, and nothing else.
- **A relation with no name in the ontology** is a schema change: add an edge type to the schema note in `Types/` (`from`, `to`, `properties`) and use it. Do not invent a one-off synonym.

## Rules `tg check` enforces

- Every section starts with a leading paragraph of at most 250 characters (wiki-link text not counted), before any child heading or edge list.
- Every `[[link]]` resolves: to a section id, to a source file, or to a symbol (`file#Class#method`).
- Every folder has an index file named after it (`tg.md/tg.md`, `tests/tests.md`) listing its children as `- [[name]] — description`.
- Files with `require-code-mention: true` in frontmatter need an `@lat:` or `@tg:` comment in code for every leaf section.

`tg ontology check` adds: every typed edge (in docs and code) uses a declared edge type, its source and target types are allowed, and its properties are declared with allowed values.

## Section ids

`tg.md/dir/file#Heading#Sub` is the full id. `file#Heading#Sub` works when the file name is unique. Matching ignores case. A level-1 heading can be skipped: `file#Sub`.

## Typed edges in code

`// @tg: implements:: [[decisions#Short-lived access tokens]] {since: "2.3"}` makes a named edge from the next declaration. Use `-type::` for a negative edge. A bare `// @tg: [[x]]` or `// @lat: [[x]]` is a plain link; prefer a named one.

Spec requirements are targets too (see the `tg-trace` skill for each framework's ids): `// @tg: implements:: [[openspec:auth#Login]] {confidence: partial}` on code, `// @tg: verifies:: [[openspec:auth#Login#Expired token]] {level: integration}` above a test call (it attaches to the test, with its name). `tg check` rejects a target that does not resolve and suggests the nearest one; `tg trace [capability] --gaps` lists requirements with no implementation or unverified scenarios.

## Test specs

Describe tests as leaf sections in `tg.md/tests/*.md` typed `Scenario`, link each to what it proves with `- refines:: [[requirements#...]]` or an OpenSpec requirement, and put exactly one `@lat:` comment next to the test that covers each.

## Review checklist

When reviewing a change to `tg.md/`, ask:

- Is every new file typed, and is each section in the file its type says?
- Is every relation written as a typed edge with a declared name, not only as prose?
- Do the facts that belong on the relation (since, ticket, strength) appear as properties?
- Does `tg ontology check` pass?
