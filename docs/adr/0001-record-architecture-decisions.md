---
status: accepted
date: 2026-10-29
---
# Record architecture decisions

## Context and Problem Statement

We need to record the architectural decisions made on this project, with their reasons, so people and coding agents can find out why the code is the way it is.

## Decision Outcome

Chosen option: "Markdown architecture decision records (MADR) in `docs/adr/`", because they live next to the code, review like code and `tg` reads them as `Decision` nodes (`adr:0001`) that code can point at with `@tg: implements::`.

### Consequences

* Good, because every significant decision has one numbered, linkable record.
* Bad, because records must be written while the decision is fresh.

## More Information

Copy `template.md` to the next number for a new decision.
