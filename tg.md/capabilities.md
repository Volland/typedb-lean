---
type: Capability
openspec: [native-driver, connection, transactions, async, query, decoding, orm, migrations, performance]
---
# Capabilities

The nine capabilities of typedb-lean, one per OpenSpec spec in `openspec/specs/`. Decisions and architecture sections are `part_of` them.

## native-driver

Building and linking the pinned TypeDB C driver, the prebuilt-library override, the supported platforms and the release of native handles.

See `openspec:native-driver#Pinned driver build` and `openspec:native-driver#Native resources are released`.

## connection

Connecting with credentials and optional TLS, driver options, database management, and one driver shared by many transactions.

See `openspec:connection#Connect with credentials` and `openspec:connection#Database management`.

## transactions

The mode-indexed transaction monad, commit and rollback semantics, typed errors and opt-in conflict retry.

See `openspec:transactions#Mode-indexed transactions` and `openspec:transactions#Opt-in conflict retry`.

## async

Running transactions concurrently as `Std.Async` computations on dedicated threads, and the blocking variant.

See `openspec:async#Async transaction runs` and `openspec:async#Blocking variant`.

## query

The `typeql!` interpolation macro, injection-safe escaping, raw splicing and query answers.

See `openspec:query#Typed interpolation` and `openspec:query#Injection-safe escaping`.

## decoding

Row decoders, derived decoders, value types, batched decoding, documents, and strict or streamed results.

See `openspec:decoding#Row decoder` and `openspec:decoding#Batched row decoding`.

## orm

Mapping structures to entity and relation types: CRUD, references, subtypes, relations as players, polymorphism, schema generation and verification.

See `openspec:orm#Entity mapping` and `openspec:orm#Schema verification`.

## migrations

Versioned up and down migrations with history and checksum checks stored in the database.

See `openspec:migrations#Versioned migrations` and `openspec:migrations#Rollback`.

## performance

Benchmarks against the official Rust driver with throughput and latency targets.

See `openspec:performance#Scan throughput target` and `openspec:performance#Query latency target`.
