---
name: tg-audit
description: Audit spec requirements (OpenSpec, Spec Kit, Kiro, BMAD, GSD) and decision records against the code that is supposed to implement them, classify every mismatch as a stale spec, a code bug or an open decision, and turn the findings into a spec change plus tg annotations. Use when asked to review, audit, align or clean up specs, when tg trace shows large gaps, or before adopting traceability in an existing project.
---

# Auditing specs against code

Specs drift. An audit reads every requirement next to the code and records what is really true, so the trace you build afterwards encodes the truth and not the drift. Never generate `implements` lines from names alone: a function called `validate` may implement half a requirement, or one the spec no longer states.

## 1. Scope

- `tg trace --json` gives every requirement with its current links. Start with capabilities that have the most gaps or the most important behavior.
- For a large project, split the capabilities into groups and audit them in parallel (one sub-agent per group), each writing structured results.

## 2. Per requirement, read the code

For each requirement (`### Requirement:` in OpenSpec, `FR-001` or a user story in Spec Kit, `### Requirement N` in Kiro, `FR-1` or a story in BMAD, an ADR) record:

| field | meaning |
|---|---|
| `status` | `implemented`, `partial`, `missing`, or `drifted` (the code does something else) |
| `code` | the implementing symbols as `path#Symbol` or `path#Class#method`, most specific first, 1 to 3 |
| `scenarios` | for each `#### Scenario:`, the test that really exercises it (`file:test name`), or none |
| `doc` | the lat.md section that explains it, if any |
| `issues` | untestable wording ("shortly", "fast"), stale names or versions, duplicates in other capabilities, missing error cases |

Verify claims by reading code and tests, not file names. Note behavior the code has that no requirement states.

## 3. Classify every mismatch

- **Stale spec**: the code is the intended behavior (tested, documented, released). Rewrite the requirement text in a MODIFIED delta.
- **Code bug**: the spec states the right behavior and the code is wrong. Keep the spec; add a task to fix the code with a test.
- **Both**: fix the wording and the code.
- **Open decision**: neither side is clearly right. Write both options down and ask; do not guess.
- **Known debt**: the code is knowingly wrong and will stay so for now. Keep the spec, and mark the code with `// @tg: -contradicts:: [[<requirement id>]] {ticket: "...", until: "...", reason: "..."}` so the debt is queryable instead of forgotten.

Record what the audit learns in the typed graph, using the names `tg ontology` lists: a decision taken to resolve a mismatch becomes a `Decision` section in `tg.md/` with `- motivated_by::` edges to its reasons, an external rule that explains odd code becomes a `Constraint` section with `- constrains::` edges to what it binds (`{strength: must}` or `should`), and a superseded rule gets `- supersedes::` from its replacement.

## 4. Write the change

Write the fixes the way the project's spec framework changes specs, keeping every existing requirement id and scenario name (they are ids annotations point at; add, never rename or renumber):

- **OpenSpec**: one change (for example `align-specs-with-code`). MODIFIED requirements carry the complete requirement, header, text and every scenario; ADDED ones cover important unspecified behavior, with scenarios from tests that already exist; REMOVED only for requirements nothing annotates (`tg edges --to "openspec:<cap>#<name>"` is empty). `design.md` holds the classification table, `tasks.md` the fixes and open decisions, and `openspec validate <change> --strict` must pass.
- **Spec Kit, Kiro, BMAD, GSD**: edit the spec file in place on a branch: append new `FR-`/criterion numbers after the last one, rewrite stale sentences without changing their id, and list fixes and open decisions in the feature's `tasks.md` (or a story).
- **ADRs**: a decision the code no longer follows gets a new record that supersedes it (`Supersedes [...](NNNN-....md)`), never an edit of the accepted one.

The frameworks this project uses:

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

## 5. Annotate from the audit

From the recorded `code` and `scenarios`, add `// @tg: implements::` above each implementing symbol and `// @tg: verifies::` above each test (see the `tg-trace` skill). A script can insert them from structured results; insert directly above the declaration or test call, and never duplicate a line that is already there. Then:

```bash
tg check            # every new link resolves
tg ontology check   # every typed edge fits the ontology
tg trace --gaps     # what is left, honestly
```

## 6. Report

Counts by status and verdict, each code bug in one line with its location, the open decisions with both options, the known debt as `contradicts` edges with tickets, and the remaining gaps from `tg trace`. Gaps are information, not failure.
