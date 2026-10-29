# query Specification

## Purpose
Lets programs write TypeQL queries as text with Lean values safely spliced in, so that user data can never change a query's structure.

## Requirements

### Requirement: Typed interpolation
The library SHALL provide a query literal in which interpolated Lean values are rendered as TypeQL value literals according to their type: strings, integers, doubles, booleans, decimals, dates, datetimes, zoned datetimes and durations.

#### Scenario: Integer and string
- **WHEN** a query interpolates the string `Ann` and the integer `42`
- **THEN** the query text contains `"Ann"` and `42` in the interpolation positions

#### Scenario: Datetime literal
- **WHEN** a query interpolates a zoned datetime
- **THEN** it is rendered in TypeQL's datetime-tz literal syntax and the server accepts it

### Requirement: Injection-safe escaping
Interpolated strings SHALL be escaped so that any string, including quotes, backslashes, newlines, semicolons, braces and non-ASCII text, is stored and read back unchanged and cannot change the query's structure.

#### Scenario: Round-trip of hostile strings
- **WHEN** arbitrary strings, generated property-style including quote, backslash, `;`, `}` and Unicode, are inserted through interpolation and read back
- **THEN** every value read back equals the original string

#### Scenario: Injection attempt is inert
- **WHEN** a query interpolates the string `x"; delete $p; match $q isa person; "`
- **THEN** exactly one attribute with that exact value is inserted and no other data changes

### Requirement: Explicit raw splicing
Splicing unescaped text, such as a type label or a query fragment, SHALL require an explicit raw marker. A value of a type without a TypeQL rendering SHALL be rejected at compile time.

#### Scenario: Unmarked unsupported type
- **WHEN** a query interpolates a value of a type with no TypeQL rendering
- **THEN** elaboration fails with an error naming the type

#### Scenario: Raw label
- **WHEN** a query splices a type label through the raw marker
- **THEN** the label appears verbatim in the query text

### Requirement: Query answers
Running a query SHALL report whether the server answered with concept rows, with documents or with an acknowledgement of success, and SHALL let the caller consume each answer kind.

#### Scenario: Define returns ok
- **WHEN** a `define` query runs in a schema transaction
- **THEN** the answer is an acknowledgement of success

#### Scenario: Fetch returns documents
- **WHEN** a `fetch` query runs
- **THEN** the answer is a sequence of documents
