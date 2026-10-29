# migrations Specification

## Purpose
Evolves a database's schema and data through ordered, versioned, reversible steps whose application history is stored in the database itself.

## Requirements

### Requirement: Versioned migrations
A migration SHALL have a version number, a name, an up step and a down step, each running as a schema-mode transaction body. Versions in a migration list SHALL be unique and strictly increasing, and an invalid list SHALL be rejected before anything runs.

#### Scenario: Duplicate versions rejected
- **WHEN** a migration list contains two steps with version 2
- **THEN** migrating fails with a migration error before any step runs

### Requirement: Migrate applies pending steps
Migrating a database SHALL apply, in version order, every step newer than the latest applied version, and SHALL report which steps it applied.

#### Scenario: Fresh database
- **WHEN** a list of 3 migrations is applied to an empty database
- **THEN** all 3 are applied in order and the history records versions 1, 2 and 3

#### Scenario: Already up to date
- **WHEN** migrating runs again with the same list
- **THEN** no step runs and the report is empty

### Requirement: Atomic steps
Each step SHALL run in its own schema transaction together with its history record, so that a failed step leaves neither its changes nor its history record, and earlier steps stay applied.

#### Scenario: Failing step
- **WHEN** step 2 of 3 fails
- **THEN** step 1 stays applied, nothing of step 2 is committed, step 3 does not run, and the error names version 2

### Requirement: Migration history
The applied history SHALL be stored in the target database and record each step's version, name, checksum and application time.

#### Scenario: History is queryable
- **WHEN** two steps have been applied
- **THEN** reading the history returns both, with versions, names, checksums and times

### Requirement: Checksum drift detection
Migrating SHALL fail before running anything when an already-applied step's checksum differs from the checksum of the step with the same version in the given list.

#### Scenario: Edited applied step
- **WHEN** the definition of applied step 1 changes and migrating runs
- **THEN** it fails with a migration error naming version 1, and no step runs

### Requirement: Rollback
Rolling back to a target version SHALL run the down steps of every applied step newer than the target, in reverse version order. Each down step SHALL run in its own schema transaction together with the removal of its history record. A step marked irreversible SHALL stop the rollback with a migration error before its down step runs.

#### Scenario: Roll back two steps
- **WHEN** versions 1 to 3 are applied and the database is rolled back to version 1
- **THEN** the down steps of 3 and then 2 run, and the history holds only version 1

#### Scenario: Irreversible step
- **WHEN** a rollback reaches a step marked irreversible
- **THEN** it stops with a migration error naming that step, and the steps rolled back before it stay rolled back

### Requirement: Schema helpers
The library SHALL provide steps that define the schema of a list of mapped types and that run a TypeQL schema file.

#### Scenario: Load schema file
- **WHEN** a step loads a `.tql` file with a valid define statement
- **THEN** the types in the file exist after migrating
