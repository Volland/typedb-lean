## Purpose

Lets a Lean program connect to a TypeDB 3.x server with credentials and optional TLS, and manage the databases on it.

## ADDED Requirements

### Requirement: Connect with credentials
The library SHALL open a driver connection given an address, a username and a password, and SHALL fail with a connection error when the server is unreachable or rejects the credentials.

#### Scenario: Successful connection
- **WHEN** a program connects to a running server with valid credentials
- **THEN** it obtains a driver that can list databases

#### Scenario: Wrong password
- **WHEN** a program connects with an invalid password
- **THEN** the connection fails with a connection error carrying the server's error code and message

#### Scenario: Unreachable server
- **WHEN** a program connects to an address where no server listens
- **THEN** the connection fails with a connection error, without hanging longer than the configured timeout

### Requirement: Optional TLS
The library SHALL support TLS connections with an optional custom root CA certificate path, and plain connections when TLS is disabled.

#### Scenario: TLS disabled by default
- **WHEN** a program connects without TLS options
- **THEN** a plain connection is used

#### Scenario: Missing CA file
- **WHEN** TLS is enabled with a root CA path that does not exist
- **THEN** the connection fails with a connection error naming the path

### Requirement: Driver options
The library SHALL let callers set driver and query options supported by the C driver, including the result prefetch size and transaction timeout.

#### Scenario: Prefetch size applies
- **WHEN** a query runs with a prefetch size of 1
- **THEN** all rows are still returned correctly

### Requirement: Database management
The library SHALL create, delete, check the existence of and list databases, and SHALL return a database's schema as TypeQL text.

#### Scenario: Create and list
- **WHEN** a program creates database `d1` and lists databases
- **THEN** the list contains `d1` and `exists d1` is true

#### Scenario: Delete
- **WHEN** a program deletes an existing database
- **THEN** `exists` returns false for it afterwards

#### Scenario: Create duplicate
- **WHEN** a program creates a database that already exists
- **THEN** it fails with a server error and the existing database is unchanged

### Requirement: Driver is shareable
A single driver SHALL be safe to use from multiple concurrent transactions running on different threads.

#### Scenario: Concurrent use
- **WHEN** 16 transactions run concurrently on one driver
- **THEN** all of them complete with correct results
