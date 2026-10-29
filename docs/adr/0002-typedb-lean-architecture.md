---
status: accepted
date: 2026-10-29
decision-makers: [Volodymyr Pavlyshyn]
---
# typedb-lean architecture

## Context and Problem Statement

Lean 4 has no TypeDB client. We need a fast, functional, typed client for TypeDB 3 over the official C driver, with transactions that cannot be misused, typed results and a lightweight mapping of Lean types to TypeDB types.

## Considered Options

* A layered library over the C driver: a C shim, a mode-indexed transaction monad, typed TypeQL interpolation, batched row decoding, a Lean-first ORM and migrations.
* A pure-Lean gRPC client of the TypeDB protocol.
* Thin bindings only, leaving monads and mapping to users.

## Decision Outcome

Chosen option: "a layered library over the C driver", because the C driver already implements the protocol, routing and TLS, and the layers above it are where Lean's types pay off. The individual choices and their reasons are the `Decision` sections of `tg.md/decisions.md`; the external facts that bind them are in `tg.md/constraints.md`.

### Consequences

* Good, because transactions are checked by mode at compile time, values cannot change a query's structure, and the hot read path is one native call per batch of rows.
* Good, because benchmarks against the Rust driver show the same scan throughput and lookup latency.
* Bad, because building needs a Rust toolchain, and on macOS the frameworks are linked through vendored stubs.
* Bad, because the upstream driver keeps about 600 bytes per transaction, which this library cannot release.

## More Information

The OpenSpec capabilities are `native-driver`, `connection`, `transactions`, `async`, `query`, `decoding`, `orm`, `migrations` and `performance`.
