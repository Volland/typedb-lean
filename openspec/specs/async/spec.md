# async Specification

## Purpose
Lets programs run TypeDB transactions concurrently without blocking Lean's task pool, using the standard `Std.Async` abstractions.

## Requirements

### Requirement: Async transaction runs
Running a transaction SHALL produce a `Std.Async` computation whose error type is the library's error type. The blocking driver calls SHALL run on threads dedicated to them, not on the shared task pool.

#### Scenario: Concurrent transactions overlap
- **WHEN** two read transactions whose bodies each take at least 200 ms are combined with `concurrently`
- **THEN** both results are returned and the total wall time is less than the sum of the individual times

#### Scenario: Shared pool is not starved
- **WHEN** more blocking transactions are in flight than the task pool has worker threads
- **THEN** an unrelated pure `Task` spawned at default priority still completes

### Requirement: Blocking variant
The library SHALL offer a blocking way to run a transaction that returns the result in `EIO`, with the same commit, rollback and retry semantics as the async run.

#### Scenario: Same semantics
- **WHEN** the same failing transaction runs through the async and the blocking variant
- **THEN** both return the same error and neither commits

### Requirement: Errors propagate through combinators
Errors from transactions SHALL propagate through `Std.Async` combinators as typed errors.

#### Scenario: Race with failure
- **WHEN** one of two transactions combined with `concurrently` fails
- **THEN** the combined computation fails with that transaction's typed error
