## Purpose

Builds and links the official TypeDB 3.x C driver into the Lean package reproducibly, so that users get a working native client from `lake build` on every supported platform.

## ADDED Requirements

### Requirement: Pinned driver build
The package SHALL build the TypeDB C driver from a single pinned `typedb-driver` release tag as part of `lake build`. The same version SHALL be the one the integration tests run against.

#### Scenario: Clean build produces linked library
- **WHEN** a user runs `lake build` on a supported platform with a Rust toolchain and no prior build artifacts
- **THEN** the build fetches the pinned driver source, compiles the C driver, links it with the shim, and a test executable can open a driver against a running server

#### Scenario: Version is pinned in one place
- **WHEN** the pinned driver tag is changed in the build configuration
- **THEN** the driver source, the reported driver version and the test server image version all follow that single value

### Requirement: Prebuilt library override
The build SHALL use a prebuilt C driver library instead of building from source when the `TYPEDB_DRIVER_LIB` environment variable names one.

#### Scenario: Override skips cargo
- **WHEN** `TYPEDB_DRIVER_LIB` points at a valid prebuilt library and `lake build` runs
- **THEN** no cargo build is invoked and the package links against the given library

#### Scenario: Invalid override fails clearly
- **WHEN** `TYPEDB_DRIVER_LIB` points at a path that does not exist
- **THEN** the build fails with a message naming the variable and the missing path

### Requirement: Supported platforms
The package SHALL build and pass its unit tests on Linux x86_64, Linux arm64 and macOS arm64. It SHALL pass its integration tests on Linux x86_64 and Linux arm64.

#### Scenario: CI matrix is green
- **WHEN** the CI workflow runs on a commit
- **THEN** build and unit jobs pass on all three platforms, and integration jobs pass on both Linux platforms

### Requirement: Native resources are released
Every native handle the library obtains (driver, transaction, answer, iterator, concept) SHALL be released exactly once, either when its scope ends or when it is garbage collected. Memory the upstream driver itself retains per transaction is outside this requirement.

#### Scenario: No leaks across many queries
- **WHEN** 10,000 queries in one read transaction each decode their rows
- **THEN** the process's resident memory after the loop stays within 10% of its value after the first 100 queries
