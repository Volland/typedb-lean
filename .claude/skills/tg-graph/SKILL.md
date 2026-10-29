---
name: tg-graph
description: Query the typed graph of docs, requirements and code with openCypher through tg - typed sections (Decision, Requirement, Constraint, ...), named edges with properties, spec requirements and annotated code - using the project ontology from tg ontology. Use when you need relationships, such as why a decision exists, what constrains a piece of code, what is unimplemented, or which sections nothing references.
---

# Querying the typed graph

`tg cypher "<query>"` runs read-only openCypher over the documentation graph. The same query is available to MCP clients as the `tg_cypher` tool. Before writing a query, run `tg ontology` (MCP: `tg_ontology`): it lists the node types and edge types that exist in this project and the properties each edge carries, so you query real labels and real property names.

## Model

- Nodes: label `Section` (plus the file's `type:` frontmatter, e.g. `Decision` or `Requirement`, on sections below the title), properties `section` (the lat id), `title`, `file`, `depth`, `startLine`, `endLine`, `summary`.
- Edges: `contains` (parent section to child section), `references` (a plain wiki link that resolves to a section), and **typed edges written in docs**: a line `- motivated_by:: [[constraints#Session limit]] {weight: primary}` in a section is an edge of type `motivated_by` from that section, carrying its properties (`r.weight`). Its target may be a section, a `Requirement` or `Scenario`, or a code node.
- Edge properties: `r.sign` (+1 or -1), `r.id`, and every property written in the edge's `{...}` block (`r.since`, `r.ticket`, `r.confidence`, ...). `type(r)` gives the edge name.
- With a spec framework (OpenSpec, ADRs): `Requirement` nodes (`requirement` id, `framework`, `capability` group, `name`, `text`, `file`, `line`, `status` active, pending or retired, `change`) and `Scenario` nodes (`scenario` id, `requirement`, `name`), joined by `contains`; decision records are `Decision` nodes. Each also carries its framework's label and properties — `UserStory {priority}`, `FunctionalRequirement`, `SuccessCriterion` (Spec Kit), `AcceptanceCriterion {ears}` (Kiro, BMAD), `Story`, `ADR {adrStatus, date}` — declared in `Types/spec-types.md`; ADRs that supersede or amend each other are joined by `supersedes` and `amends`. A lat.md file's `openspec:` or `specs:` frontmatter adds `references` from its root section to each requirement it names. Example: `MATCH (u:UserStory {priority: 'P1'})-[:contains]->(s:Scenario) OPTIONAL MATCH (t)-[:verifies]->(s) RETURN u.requirement, s.name, count(t)`.
- With `--code annotated` or `all`: `CodeFile` and `CodeSymbol` nodes (`path`, `symbol`, `kind`, `lang`, `startLine`), and `@tg:` annotations as edges of their own type (`implements`, `verifies`, ...) to sections, requirements or scenarios; a test's annotation starts at its file and carries `test`.

## Examples

```cypher
// Sections nothing links to
MATCH (s:Section) OPTIONAL MATCH (a)-[r:references]->(s) WITH s, count(r) AS n WHERE n = 0 RETURN s.section LIMIT 20

// Who references the Packaging section
MATCH (a:Section)-[:references]->(b:Section {title: "Packaging"}) RETURN a.section, b.file

// Biggest hubs
MATCH (s:Section)<-[r:references]-() RETURN s.section, count(r) AS n ORDER BY n DESC LIMIT 10
```

## Ontology queries

Use the names `tg ontology` prints (the bundled ones are below; a project may add its own) with `tg cypher --code annotated`:

```cypher
// Requirements nothing implements
MATCH (s:Requirement) OPTIONAL MATCH (c)-[r:implements]->(s) WITH s, count(r) AS n WHERE n = 0 RETURN s.section

// Knowing contradictions, with their expiry
MATCH (c)-[r:contradicts]->(d) RETURN c.symbol, d.section, r.until, r.ticket

// Why a decision exists, and what it replaced
MATCH (d:Decision {title: "Short-lived access tokens"})-[r:motivated_by|supersedes]->(x) RETURN type(r), x.title, r.weight, r.reason

// Hard constraints and everything they bind, down to code
MATCH (c:Constraint)-[r:constrains]->(x) WHERE r.strength = "must" RETURN c.title, x.title, x.symbol

// Everything around one section, in both directions
MATCH (s:Section {title: "Session limit"})-[r]-(x) RETURN type(r), r.sign, x.title, x.symbol

// Decisions with no recorded reason
MATCH (d:Decision) OPTIONAL MATCH (d)-[r:motivated_by]->() WITH d, count(r) AS n WHERE n = 0 RETURN d.section

// Edge names in use, to compare with tg ontology
MATCH ()-[r]->() RETURN type(r) AS edge, count(*) AS n ORDER BY n DESC
```

## Requirement queries

```cypher
// Requirements of one capability with how many symbols implement each
MATCH (r:Requirement {capability: "auth"}) OPTIONAL MATCH (c)-[i:implements]->(r) RETURN r.name, count(i) AS impl

// Scenarios nothing verifies
MATCH (s:Scenario) OPTIONAL MATCH (t)-[v:verifies]->(s) WITH s, count(v) AS n WHERE n = 0 RETURN s.scenario

// Requirements pending in an open change
MATCH (r:Requirement {status: "pending"}) RETURN r.change, r.requirement
```

`tg trace` gives the same picture as a report; the `tg-impact` skill has queries for a planned code change.

## Typed code edges

`tg edges --type implements` lists `@tg:` annotation edges (code to section) with their properties, signs and sources.

## Checking edges against the ontology

`tg ontology check` (MCP: `tg_ontology` with `check: true`) lists typed edges in docs and code whose name the ontology does not declare (with the closest declared name), whose source or target type the edge type does not allow, or whose properties are undeclared or out of range. Run it after writing edges.

## Limits

Supported: MATCH, OPTIONAL MATCH, WITH, RETURN, ORDER BY, SKIP, LIMIT, aggregation and variable-length paths. Write clauses are rejected. Pattern predicates such as `WHERE NOT ()-[:x]->(s)`, list comprehensions, map projections and `EXISTS {}` or `COUNT {}` subqueries are reported as unsupported by name: use OPTIONAL MATCH with a count instead.
