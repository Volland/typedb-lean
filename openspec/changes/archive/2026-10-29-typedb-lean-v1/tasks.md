## 1. Spike and project setup

- [x] 1.1 Spike: clone `typedb-driver` at the latest 3.x tag compatible with server 3.7.x and confirm that `c/` builds with plain `cargo build --release` on macOS arm64 (if not, vendor a minimal `Cargo.toml` and cbindgen config). Call one function through a Lean `@[extern]` from a Lake-built executable, and run one query against a `typedb/typedb` container. Record the pinned tag in design.md, resolving the open question.
- [x] 1.2 Create `lakefile.lean` (package `typedb-lean`, Apache-2.0, `autoImplicit false`), `lean-toolchain` (`v4.35.0`), `LICENSE`, `README.md` and the `TypeDB/` module skeleton.
- [x] 1.3 Add the Lake target that fetches the pinned driver source, runs cargo and links the static library with `ffi/typedb_lean.c`; add the `TYPEDB_DRIVER_LIB` override with a clear error for a missing path. Annotate it `@tg: implements:: [[openspec:native-driver#Pinned driver build]]` and `[[openspec:native-driver#Prebuilt library override]]`.
- [x] 1.4 Record decisions D1–D15 as an ADR in `docs/adr/0002-typedb-lean-architecture.md`.

## 2. Native shim and thin bindings

- [x] 2.1 Write external classes and finalizers for driver, transaction, answer promise, query answer, row iterator, document iterator, row and concept handles in `ffi/typedb_lean.c`. Annotate `@tg: implements:: [[openspec:native-driver#Native resources are released]]`.
- [x] 2.2 Write the shim's error conversion: `check_error` and `get_last_error` read on the same thread right after each call, then mapped to `TypeDBError` with the error code parsed out.
- [x] 2.3 Add thin `@[extern]` bindings in `TypeDB/Native.lean` for driver open and close, database operations, transaction open, commit, rollback and close, query, promise resolve, answer kind, row and document iteration, and the concept getters (IID, label, every value type).
- [x] 2.4 Write the batched `tdb_iter_next_batch(iter, plan, k)` hot path for every value kind, including empty optionals. Annotate `@tg: implements:: [[openspec:decoding#Batched row decoding]]`.

## 3. Connection

- [x] 3.1 Implement `Driver.connect` with credentials, TLS and root CA, and `DriverOptions` (prefetch size, transaction timeout). Annotate it `implements` [[openspec:connection#Connect with credentials]], [[openspec:connection#Optional TLS]] and [[openspec:connection#Driver options]].
- [x] 3.2 Implement database create, delete, exists, list and schema. Annotate it `implements` [[openspec:connection#Database management]].
- [x] 3.3 Document and test that one driver is shareable across threads. Annotate it `implements` [[openspec:connection#Driver is shareable]].

## 4. Errors, transactions and async

- [x] 4.1 Define `TypeDBError` and classify conflicts in `TypeDB/Error.lean`. Annotate it `implements` [[openspec:transactions#Typed errors]].
- [x] 4.2 Implement `TxMode` with `LE` and `Allows`, the `Tx` monad, and the `MonadTypeDB` class in `TypeDB/Tx.lean`. Annotate it `implements` [[openspec:transactions#Mode-indexed transactions]] and [[openspec:transactions#Transactions compose monadically]].
- [x] 4.3 Implement the Transactor `Driver.runSync`: open, body, commit or close, using `tryFinally`. Annotate it `implements` [[openspec:transactions#Commit on success]], [[openspec:transactions#Rollback on failure]] and [[openspec:async#Blocking variant]].
- [x] 4.4 Implement `RetryPolicy` with exponential backoff, applied to conflicts only. Annotate it `implements` [[openspec:transactions#Opt-in conflict retry]].
- [x] 4.5 Implement `Driver.run` as `EAsync TypeDBError` on dedicated threads in `TypeDB/Async.lean`. Annotate it `implements` [[openspec:async#Async transaction runs]] and [[openspec:async#Errors propagate through combinators]].

## 5. Values and queries

- [x] 5.1 Implement `Decimal` (parse, render, arithmetic, `Ord`) and `Duration` in `TypeDB/Value.lean`, plus the conversions between C datetimes and Std.Time.
- [x] 5.2 Implement the `ToTypeQL` class and its instances (string escaping, numbers, Std.Time, Decimal, Duration, IID, `Raw`).
- [x] 5.3 Implement the `typeql!` elaborator with an error message for a missing instance. Annotate it `implements` [[openspec:query#Typed interpolation]], [[openspec:query#Injection-safe escaping]] and [[openspec:query#Explicit raw splicing]].
- [x] 5.4 Implement `exec` and the answer kinds (`ok`, `rows`, `documents`). Annotate it `implements` [[openspec:query#Query answers]].

## 6. Decoding

- [x] 6.1 Implement `Plan`, `RowDecoder` (Functor and Applicative), `col` and `colOpt`, and `FromConcept` instances with range checks. Annotate it `implements` [[openspec:decoding#Row decoder]] and [[openspec:decoding#Value type mapping]].
- [x] 6.2 Implement the `deriving FromRow` handler. Annotate it `implements` [[openspec:decoding#Derived row decoders]].
- [x] 6.3 Implement `fetch` decoding through `Lean.FromJson`. Annotate it `implements` [[openspec:decoding#Document decoding]].
- [x] 6.4 Implement `query` (strict), `queryFold`, and `stream` with a `ForIn` instance that releases the iterator on break and on exceptions. Annotate it `implements` [[openspec:decoding#Strict results]] and [[openspec:decoding#Scoped streaming]].

## 7. ORM

- [x] 7.1 Add the attributes `@[typedb]`, `@[key]`, `@[role]` and `@[attr]`, and the `Entity`, `Relation`, `KeyOf` and `Ref` definitions in `TypeDB/ORM/Basic.lean`. Annotate them `implements` [[openspec:orm#References by key or IID]].
- [x] 7.2 Implement the `deriving Entity` handler (labels, attributes, `Option` and `Array` fields, key, CRUD queries). Annotate it `implements` [[openspec:orm#Entity mapping]], [[openspec:orm#Multi-valued attributes]] and [[openspec:orm#Update and delete]].
- [x] 7.3 Implement `extends`-based subtyping in both deriving handlers. Annotate them `implements` [[openspec:orm#Subtyping]].
- [x] 7.4 Implement the `deriving Relation` handler with role fields, entity and relation players, and shared roles. Annotate it `implements` [[openspec:orm#Relation mapping]] and [[openspec:orm#Relations as role players]].
- [x] 7.5 Implement `deriving Polymorphic` with label dispatch. Annotate it `implements` [[openspec:orm#Polymorphic decoding]].
- [x] 7.6 Implement `schemaOf` and `Schema.define`. Annotate them `implements` [[openspec:orm#Schema generation]].
- [x] 7.7 Implement `verifySchema` against the live schema. Annotate it `implements` [[openspec:orm#Schema verification]].

## 8. Migrations

- [x] 8.1 Implement `Migration`, `Down`, validation of the migration list, and the definition of the history type in `TypeDB/Migrate.lean`. Annotate it `implements` [[openspec:migrations#Versioned migrations]] and [[openspec:migrations#Migration history]].
- [x] 8.2 Implement `migrate`: drift check, pending steps, and one schema transaction per step together with its history record. Annotate it `implements` [[openspec:migrations#Migrate applies pending steps]], [[openspec:migrations#Atomic steps]] and [[openspec:migrations#Checksum drift detection]].
- [x] 8.3 Implement `rollback (to := n)` with the `.irreversible` stop. Annotate it `implements` [[openspec:migrations#Rollback]].
- [x] 8.4 Implement `Migration.tql`, `Schema.load` and the `defineTx` step, plus a warning when a code step has no fingerprint. Annotate them `implements` [[openspec:migrations#Schema helpers]].

## 9. Test harness and tests

- [x] 9.1 Write the `lake test` driver: a testcontainer for the pinned image on a random port, a readiness wait, a fresh database per test, cleanup in `finally` and on signals, and the `TYPEDB_ADDRESS` bypass.
- [x] 9.2 Write the unit tests that need no server: escaping, ToTypeQL rendering, Decimal and Duration, golden `define` output for the social schema, plan compilation, and compile-failure tests (`#guard_msgs`) for mode violations and missing ToTypeQL instances.
- [x] 9.3 Write an integration test for every scenario in `connection`, `transactions` and `async`, each annotated `@tg: verifies:: [[openspec:<capability>#<Requirement>#<Scenario>]] {level: integration}` directly above it.
- [x] 9.4 Write an integration test for every scenario in `query` and `decoding`, including the property-style round trip of hostile strings and the agreement between the batched and per-value paths, with `verifies` annotations.
- [x] 9.5 Write an integration test for every scenario in `orm` and `migrations`, with `verifies` annotations.
- [x] 9.6 Write the native-driver scenarios: the leak test for [[openspec:native-driver#Native resources are released]], the override tests, and the version pin check, with `verifies` annotations.

## 10. Benchmarks

- [x] 10.1 Write the Lean `lake exe bench` with the four workloads and a JSON report. Annotate it `implements` [[openspec:performance#Benchmark suite]].
- [x] 10.2 Write the companion Rust program in `bench/rust`, using the `typedb-driver` crate at the same pin, with the same workloads and the same JSON report.
- [x] 10.3 Write the comparison script that enforces [[openspec:performance#Scan throughput target]] and [[openspec:performance#Query latency target]], and a `--ci` margin mode for [[openspec:performance#CI benchmark smoke]], with `verifies` annotations.

## 11. CI

- [x] 11.1 Write the GitHub Actions matrix: `ubuntu-latest` (build, unit tests, integration tests, bench smoke), `ubuntu-24.04-arm` (build, unit tests, integration tests) and `macos-14` (build and unit tests), with caching for cargo and `.lake`. Annotate it `verifies:: [[openspec:native-driver#Supported platforms#CI matrix is green]] {level: e2e}`.

## 12. Example and docs

- [x] 12.1 Write `examples/social`: person, employee sub person, friendship, endorsement of a friendship, and posts with tags; migrations; CRUD; polymorphic listing; concurrent reports through `concurrently`. Run it with `lake exe social`.
- [x] 12.2 Write `docs/guide/`: getting started, transactions and errors, async, queries and escaping, decoding and streaming, ORM, migrations, and performance notes with benchmark results.
- [x] 12.3 Set up doc-gen4 API docs with docstrings on every public declaration.
- [x] 12.4 Write `tg.md/architecture.md` (`type: Concept`), covering the layers (native, Tx, async, query, decoding, ORM, migrations), with all nine capabilities in its `openspec:` frontmatter and `part_of` edges.
- [x] 12.5 Write `tg.md/constraints.md` (`type: Constraint`), with C1–C8 as sections that each carry `source` and `- constrains:: [[...]] {strength: must}` edges to the requirements and decisions they bind.
- [x] 12.6 Write `tg.md/decisions.md` (`type: Decision`, `status: accepted`, `date: 2026-10-29`), with D1–D15 as sections that each carry `- motivated_by:: [[constraints#...]]` edges and their rejected alternatives in prose.
- [x] 12.7 Link the new files from `tg.md/tg.md`.

## 13. Traceability gate

- [x] 13.1 Run `tg check`, `tg ontology check` and `tg trace native-driver connection transactions async query decoding orm migrations performance --gaps` and confirm they show no new gaps. Close every gap they report.
