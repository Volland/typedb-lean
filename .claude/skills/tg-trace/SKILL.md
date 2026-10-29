---
name: tg-trace
description: Trace spec requirements (OpenSpec, Spec Kit, Kiro, BMAD, GSD) and architecture decision records to the code that implements them, the tests that verify their scenarios and the lat.md docs that explain them, with tg. Use when implementing or testing a requirement, when a project has openspec/, specs/, .kiro/specs/, a BMAD PRD, .planning/REQUIREMENTS.md or docs/adr/, before archiving a change, or when asked what is implemented, tested or covered.
---

# Requirement traceability with tg

`tg` reads the requirement files of the spec frameworks a project uses (OpenSpec, ADRs). Every requirement and scenario has an id in its framework's scheme, code and tests point at those ids in comments, and `tg trace` reports what is implemented, verified and documented.

## Ids

Each framework has its own scheme, so ids never collide with lat.md sections or each other. Matching ignores case and collapses whitespace, aliases resolve (a user story's title, an ADR number without zeros), and a typo fails `tg check` with a did-you-mean suggestion. Never renumber or rename an id that code points at.

### OpenSpec

`tg` reads `openspec/specs/<capability>/spec.md` and the spec deltas of open changes.

```
openspec:<capability>#<Requirement>
openspec:<capability>#<Requirement>#<Scenario>
```

- `<capability>` is the folder under `openspec/specs/`, `<Requirement>` the text after `### Requirement:`, `<Scenario>` the text after `#### Scenario:`.
- Requirements ADDED or MODIFIED in an open change resolve at once, shown as `pending in <change>`; REMOVED ones show `removed by <change>`. Archiving keeps the id.
- Docs name what they explain as `openspec: [auth, "billing#Refunds"]` in frontmatter.

### Architecture decision records

`tg` reads numbered records in `docs/adr/`, `doc/adr/`, `docs/decisions/` and the other usual folders, or the folder `.adr-dir` names. MADR, Nygard (adr-tools) and log4brains formats all work.

```
adr:0003       a record by its number (also adr:3, adr:ADR-0003, its file slug or title)
```

- A record is a `Decision` node with the label `ADR` and its `adrStatus`, `date` and `title`. Code realizing it gets `// @tg: implements:: [[adr:0003]]`; code that knowingly departs from it gets `-contradicts::` with `{ticket, until}`.
- `Supersedes [...](0002-....md)` and `Amends [...]` lines in a record become `supersedes` and `amends` edges between records.
- Decisions need no test. Proposed records are pending; superseded, deprecated and rejected ones are retired and never reported as gaps.
- To record a new decision, copy `docs/adr/template.md` to the next number, fill it in and link it from the lat.md section it explains with `- motivated_by::` or `- supersedes::` edges.
- Docs name the records they explain as `specs: ["adr:0003"]` in frontmatter.

## Link code, tests and docs

Put one comment line directly above the declaration that realizes a requirement. Annotate the entry points (one to three symbols), not every helper. The examples use OpenSpec ids; an id of any framework above works the same way:
```ts
// @tg: implements:: [[openspec:auth#Token expiry]]
export function checkToken(token: Token): Result {
```

Put one line per scenario directly above the test call that proves it. It attaches to the test and records its name; keep any `@lat:` line for the test spec next to it:

```ts
// @lat: [[tests/auth#Expired token]]
// @tg: verifies:: [[openspec:auth#Token expiry#Expired token]]
it('rejects an expired token with 401', () => {
```

Put what you know about the link on the link: `{confidence: partial}` when the symbol covers only part of the requirement, `{since: "2.3"}` for the version that introduced it, `{level: integration}` on a `verifies` for the kind of test. `tg ontology` lists the properties each edge takes.

Several edges fit on one line: `// @tg: verifies:: [[openspec:a#X#S1]], verifies:: [[openspec:a#X#S2]]`. Python and shell use `#` comments, SQL `--`.

Docs relate to requirements with typed edge lines too, after a section's leading paragraph: a `Constraint` section that binds a requirement writes `- constrains:: [[openspec:auth#Token expiry]] {strength: must}`, a `Decision` that knowingly departs from one writes `- -contradicts:: [[openspec:auth#Token expiry]] {ticket: "AUTH-12"}`. Use only edge names `tg ontology` lists.

Name what a lat.md file explains in its frontmatter (lat.md ignores both keys): `openspec:` takes bare OpenSpec capabilities, `specs:` takes ids of any framework with their scheme:

```yaml
---
openspec: [auth, "billing#Refunds"]
specs: ["speckit:001-user-auth", "adr:0003"]
---
```

## Check and report

```bash
tg check                       # broken spec targets and frontmatter entries fail here
tg trace                       # every capability: implements, verifies, docs per requirement
tg trace auth billing --gaps   # only requirements still unimplemented or unverified
tg trace speckit:001-user-auth adr   # one Spec Kit feature, every ADR
tg trace --json                # for scripts
tg trace --strict              # exit 1 while any gap remains (CI, once coverage is complete)
tg edges --type verifies --to "openspec:auth#Token expiry"
tg ontology check              # typed edges with undeclared names, wrong endpoints or properties
```

A requirement is **implemented** when an `implements` edge reaches it or one of its scenarios, **verified** when every scenario has a `verifies` edge (or, with no scenarios, the requirement has one), and **documented** when a lat.md file names it. Decision records need no test; retired ones (superseded, deprecated, rejected, out of scope) are listed but never a gap. Missing links never fail `tg check`; only `tg trace --strict` enforces coverage.

## Rules that keep links working

- **Never rename a requirement or scenario that code points at.** Rewrite its sentence instead. If a rename is unavoidable, update every annotation in the same change: `tg edges --to "<old id>"` lists them, and `tg check` catches the rest.
- **Write the annotation with the code**, in the same edit, not afterwards.
- **A requirement with no test is a finding, not a failure.** Report it; do not invent a test name to silence it.
- **Negative edges** (`-implements::`) are ignored by the trace. Use `-contradicts::` for code that knowingly breaks a requirement, with `{until, ticket}`.

## Graph

The same links are graph data: `Requirement`, `Scenario` and (for ADRs) `Decision` nodes joined by `contains`, with their framework's own label (`UserStory`, `AcceptanceCriterion`, `ADR`, ...), reached by `implements`, `verifies` and `references` and by typed doc edges such as `constrains`, with their properties (`r.confidence`, `r.level`).
Partly implemented requirements: `MATCH (c)-[i:implements {confidence: "partial"}]->(q:Requirement) RETURN q.title, c.symbol`. See the `tg-graph` and `tg-impact` skills for queries.
