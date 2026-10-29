---
name: tg-migrate
description: Migrate a lat.md project to an ontology-aware tg project - run tg migrate to type files, turn plain links into typed edges with metadata and upgrade @lat comments, then resolve the links it left plain by reading their sentences and choosing the right relation and properties from the project ontology. Use when moving a project from lat.md to tg, when a tg.md/ folder has untyped files or plain links, or when asked to make existing docs a typed graph.
---

# Migrating lat.md to a typed graph

`tg migrate` does the part of a migration that needs no judgement: it types files by their path, swaps the agent setup, upgrades `@lat:` comments whose target type decides the relation, and turns a plain link into a typed edge only when the sentence around it names the relation. Everything else it reports. Your job is the rest: read each reported sentence, decide what the link means, and write it down with the right name and metadata. A plain link you leave plain is better than a relation you cannot justify.

## 1. Prepare

```bash
git status            # start clean: the migration should be one reviewable diff
tg ontology           # the types and edge types you may use, with each edge's properties
tg check              # the project passes before you start
```

Read `tg ontology` carefully. The project may declare its own types and edges beyond the bundled code ontology; use them where they fit.

## 2. Run the deterministic pass

```bash
tg migrate --dry-run          # read the diff and the summary
tg migrate                    # apply it
tg migrate --dry-run --json   # the links left plain, with their sentences and candidates
```

Options: `--keep-lat` keeps each `@lat:` line next to its new `@tg:` line (for teams that still run `lat check`), `--no-setup` leaves the agent setup alone, `--no-since` skips the git dates, `--infer` also applies a relation that is the only candidate even without a cue word (review those edges afterwards).

## 3. Type the files it could not

Files the report never mentions as typed and that hold intent need a `type:`. Read each one and choose by what its sections are: a choice with reasons is a `Decision`, a SHALL statement a `Requirement`, a checkable example a `Scenario`, an external rule a `Constraint`, a term a `Concept`, a unit of work a `Change`, or a project type from `tg ontology`. A file that mixes kinds either gets a list (`type: [Decision, Constraint]`) or is split into one file per kind; splitting is better when the sections are clearly separate. Update the index files and every link to moved sections, then run `tg migrate --dry-run --json` again: newly typed files produce new edges and new candidates.

## 4. Resolve every unresolved link

For each entry in `unresolved` (`file`, `line`, `section`, `target`, `reason`, `candidates`, `text`), open the section and read the sentence:

| reason | what to do |
| --- | --- |
| `ambiguous` | pick the candidate the sentence means. "X is why we chose this" → `motivated_by`; "X is replaced by this" → `supersedes`. |
| `no cue` | the ontology allows exactly one relation; write it only if the sentence really means it. "See also X" is not a relation. |
| `no candidate` | the ontology has no relation between these types. Leave it plain, or, if the relation matters and recurs, add an edge type to `Types/` (with `from`, `to` and properties) and use it. |
| `untyped source` / `untyped target` | type the file first (step 3), then rerun. |

Write the relation as a typed edge line at the end of the section's own text, keeping the prose link:

```markdown
- motivated_by:: [[constraints#Session limit]] {weight: primary, since: "2026-03-01"}
```

Fill the properties the edge type declares from the text, not from guesses:

- `since`: a version or date the text gives, or the date the sentence was written (`git log -L <line>,<line>:<file>`).
- `reason`, `note`: the sentence's own words, shortened.
- `ticket`, `until`: only when the text names them.
- `strength`: `must` for MUST, SHALL or required, `should` for should or recommended.
- `weight`: `primary` when the sentence gives it as the main reason.
- `confidence`: `partial` when the code covers part of a requirement.

A known disagreement is `-contradicts::` with `{ticket, until}`, never a positive edge with a sad sentence.

## 5. Code links

`@lat:` comments left as they were point at sections whose type did not decide the relation (a Concept, a Constraint, an untyped file). For each, read the code: realizing a decision or requirement is `implements`; a test proving a scenario is `verifies`; code bound by a rule is better expressed from the docs side, as `- constrains:: [[src/file.ts#symbol]]` in the Constraint section. Keep `@lat:` where it is only a pointer.

## 6. Finish

```bash
tg check            # links, structure, coverage
tg ontology check   # every edge uses a declared name, direction and properties
tg trace --gaps     # if the project has a spec framework (OpenSpec, Spec Kit, Kiro, BMAD, GSD, ADRs)
```

Report what the migration did: files typed, edges added by type (deterministic and yours), comments upgraded, and the links you deliberately left plain with one line each on why. Commit the deterministic pass and your edits as separate commits so each can be reviewed.
