# performance Specification

## Purpose
Makes performance a checked property: a benchmark suite measures the Lean client against the official Rust driver on the same server and enforces throughput and latency targets.

## Requirements

### Requirement: Benchmark suite
The project SHALL include a benchmark runner that measures, against a server it starts or one it is given: point lookup latency (p50 and p99), a 100,000-row scan decoded into structures (rows per second), a bulk insert of 10,000 entities in one transaction, and 16 concurrent read transactions. The same workloads SHALL be implemented with the official Rust driver against the same server.

#### Scenario: Report produced
- **WHEN** the benchmark runner completes
- **THEN** it writes a machine-readable report with every metric for both the Lean and the Rust implementation

### Requirement: Scan throughput target
Decoding a 100,000-row scan into structures SHALL reach at least 80% of the Rust driver's rows per second on the same machine and server.

#### Scenario: Scan meets target
- **WHEN** the scan benchmark runs in release mode
- **THEN** the Lean rows per second are at least 0.8 times the Rust rows per second

### Requirement: Query latency target
The p50 latency of a point lookup SHALL be at most 1.1 times the Rust driver's p50 on the same machine and server.

#### Scenario: Lookup meets target
- **WHEN** the point lookup benchmark runs in release mode
- **THEN** the Lean p50 is at most 1.1 times the Rust p50

### Requirement: CI benchmark smoke
CI SHALL run a reduced benchmark on Linux x86_64 that fails the build when a target is missed by more than an extra 10% margin, to tolerate shared-runner noise.

#### Scenario: Regression fails CI
- **WHEN** a change makes the scan reach less than 70% of Rust's throughput
- **THEN** the CI benchmark job fails
