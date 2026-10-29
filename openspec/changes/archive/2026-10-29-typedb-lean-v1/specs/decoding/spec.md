## Purpose

Turns TypeDB query answers into typed Lean values quickly and safely, with precise value types and with constant memory for large result sets.

## ADDED Requirements

### Requirement: Row decoder
The library SHALL decode concept rows into Lean values through a composable decoder that reads columns by variable name. A missing column, a column whose value does not match, or an unexpected empty optional SHALL produce a decode error naming the column, the expected type and the actual type.

#### Scenario: Decode two columns
- **WHEN** a query returns rows with `$name` (string) and `$age` (integer), decoded as a pair
- **THEN** each row yields a pair of the string and the integer

#### Scenario: Type mismatch
- **WHEN** a decoder expects an integer in `$name`, which holds a string
- **THEN** decoding fails with a decode error naming `name`, the integer type and the string type

#### Scenario: Optional column
- **WHEN** a row has no value for an optional column, from a `try` block
- **THEN** that field decodes as `none`

### Requirement: Derived row decoders
Deriving a row decoder for a structure SHALL map each field to the query variable with the same name and SHALL treat `Option` fields as optional columns.

#### Scenario: Structure from rows
- **WHEN** a structure with fields `name : String` and `age : Option Int64` derives a row decoder and decodes rows of `$name` and `$age`
- **THEN** each row yields a structure value with the matching fields

### Requirement: Value type mapping
TypeDB values SHALL map without loss of precision: integer to Int64 (or to Int or Nat with range checks), double to Float, boolean to Bool, string to String, decimal to an exact decimal type, date to a plain date, datetime to a plain datetime, datetime-tz to an exact zoned datetime (instant, UTC offset, and IANA zone or fixed offset) convertible to a `Std.Time` datetime, and duration to a duration of months, days and nanoseconds. Concepts SHALL also expose their IID and type label.

#### Scenario: Decimal is exact
- **WHEN** the decimal `0.1234567890123456789dec` is stored and read back
- **THEN** the decoded value equals the original exactly

#### Scenario: Datetime-tz round trip
- **WHEN** a zoned datetime with nanosecond precision and a non-UTC zone is stored and read back
- **THEN** the decoded value equals the original

#### Scenario: Nat range check
- **WHEN** a negative integer is decoded as Nat
- **THEN** decoding fails with a decode error

### Requirement: Batched row decoding
Decoding concept rows SHALL fetch the values of all requested columns for a batch of rows in one call across the native boundary, without creating an intermediate concept object per value.

#### Scenario: Batched and per-value paths agree
- **WHEN** the same query is decoded through the batched path and through the per-value path
- **THEN** both produce identical results for every supported value type, including empty optionals

### Requirement: Document decoding
Fetch answers SHALL be decodable into any type with a JSON decoder. A document that does not match SHALL produce a decode error.

#### Scenario: Nested fetch
- **WHEN** a fetch query returns `{ "name": ..., "friends": [ ... ] }` documents decoded into a structure with a list field
- **THEN** each document yields a structure with all nested elements

### Requirement: Strict results
The library SHALL return all decoded rows of a query as an array, in answer order.

#### Scenario: Array of all rows
- **WHEN** a query matching 1,000 entities is decoded strictly
- **THEN** an array of 1,000 values is returned

### Requirement: Scoped streaming
The library SHALL let a transaction body fold over or iterate the decoded rows of a query one batch at a time, with memory that does not grow with the result size. A result iterator SHALL NOT be obtainable outside the transaction that produced it.

#### Scenario: Fold in constant memory
- **WHEN** a body folds over 1,000,000 rows to compute a sum
- **THEN** the correct sum is returned and peak memory does not grow with the row count

#### Scenario: Early exit
- **WHEN** a `for` loop over a streamed query breaks after 10 rows
- **THEN** the loop ends, the iterator is released and the transaction can run further queries
