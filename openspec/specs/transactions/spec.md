# transactions Specification

## Purpose
Gives Lean programs a composable, mode-checked unit of work over a TypeDB transaction, with guaranteed commit or rollback and a typed error model.

## Requirements

### Requirement: Mode-indexed transactions
Transactions SHALL carry their mode (read, write or schema) in their type, with read ≤ write ≤ schema. An operation that needs a stronger mode than the enclosing transaction SHALL be rejected at compile time.

#### Scenario: Write in read transaction does not compile
- **WHEN** a program uses a write operation inside a read-mode transaction
- **THEN** elaboration fails with a type error

#### Scenario: Read in write transaction compiles
- **WHEN** a program uses a read operation inside a write-mode or schema-mode transaction
- **THEN** it compiles and runs

### Requirement: Transactions compose monadically
Transaction bodies SHALL compose with `do` notation, SHALL support raising and catching typed errors, and SHALL be liftable into user monad stacks through a class.

#### Scenario: Composition
- **WHEN** two write-mode functions are sequenced in one transaction body
- **THEN** both take effect in a single commit

#### Scenario: Catch inside a transaction
- **WHEN** a body catches a decode error from one query and continues
- **THEN** the transaction can still commit the other writes

### Requirement: Commit on success
Running a write-mode or schema-mode transaction SHALL commit when the body returns normally. A read-mode transaction SHALL be closed without commit.

#### Scenario: Insert is visible after run
- **WHEN** a write transaction inserts an entity and returns
- **THEN** a later read transaction finds the entity

### Requirement: Rollback on failure
When the body raises an error or throws, the transaction SHALL be closed without committing, and the error SHALL be returned to the caller.

#### Scenario: Error discards writes
- **WHEN** a write transaction inserts an entity and then raises an error
- **THEN** the caller receives that error and a later read transaction does not find the entity

#### Scenario: Handle released on failure
- **WHEN** 1,000 transactions fail with errors
- **THEN** no transaction handles remain open on the client

### Requirement: Typed errors
Failures SHALL be reported as a structured error value that distinguishes connection errors, server errors (with the server's error code and message), commit conflicts, decode errors (with column, expected type and actual type), schema mismatches and migration errors.

#### Scenario: Server error code
- **WHEN** a query with a TypeQL syntax error runs
- **THEN** the error is a server error whose code is the TypeDB error code and whose message is the server's message

#### Scenario: Conflict is distinguishable
- **WHEN** two concurrent write transactions modify the same data and both try to commit
- **THEN** the losing one fails with a conflict error, not a generic server error

### Requirement: Opt-in conflict retry
Running a transaction SHALL accept an optional retry policy that re-runs the whole body on commit conflicts only, with a maximum attempt count and backoff. The default SHALL be no retry.

#### Scenario: Retry recovers from a conflict
- **WHEN** a transaction with a policy of 3 retries loses a conflict once
- **THEN** it is re-run and succeeds, and the caller receives the result of the successful attempt

#### Scenario: Non-conflict errors are not retried
- **WHEN** a transaction with a retry policy fails with a server error that is not a conflict
- **THEN** the body runs exactly once and the error is returned

#### Scenario: Retries are bounded
- **WHEN** every attempt conflicts
- **THEN** the body runs 1 + max-retries times and the last conflict error is returned
