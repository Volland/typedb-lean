# Queries

## `typeql!`

```lean
let name := "Ann \"the\" coder"
let q := typeql!"match $p isa person, has name {name}, has age {(42 : Int64)};"
-- match $p isa person, has name "Ann \"the\" coder", has age 42;
```

Each `{e}` is rendered by `ToTypeQL` as a TypeQL value literal:

| Lean type | TypeQL literal |
|---|---|
| `String` | quoted, with `"`, `\`, newlines, tabs and control characters escaped |
| `Int64`, `Int`, `Nat`, `Int32`, `UInt64`, `UInt32` | integer |
| `Float` | the exact decimal expansion of the double |
| `Bool` | `true` / `false` |
| `Decimal` | `1.5dec` |
| `Std.Time.PlainDate`, `PlainDateTime` | `2024-02-29`, `2024-02-29T10:00:00.5` |
| `DatetimeTZ`, `Std.Time.DateTime` | `2024-02-29T10:00:00 Europe/London`, `…+01:00` |
| `Duration` | `P1Y2M3DT4H5M6.5S` |
| `IID` | `0x1e00…` |

A value whose type has no `ToTypeQL` instance is a compile error. There is no way for a value to change a query's structure. To splice text verbatim (a type label, a query fragment), wrap it in `Raw`:

```lean
let label := Raw.mk "person"
typeql!"match $x isa {label};"
```

TypeQL braces must be written `\{` and `\}`, because `{…}` is interpolation:

```lean
typeql!"match $p isa person, has name $n; fetch \{ \"name\": $n };"
```

## Modes

The query's mode is read off its literal text, ignoring string literals and variables: `define`, `undefine` or `redefine` need a schema transaction, `insert`, `delete`, `update` or `put` a write transaction, and anything else runs in a read transaction. Text you build at run time can be wrapped with an explicit mode: `Query.raw .write text`. `q.withMode .write` raises a query's requirement.

## Running

| Function | Answer |
|---|---|
| `exec q` | runs for the effect, draining any rows |
| `query (α := T) q` | every row as an `Array T` |
| `query1? q` / `queryOne q` | the first row |
| `queryFold q init f`, `queryFoldM` | a fold over the rows, in constant memory |
| `for x in stream (α := T) q do …` | a loop over the rows, in constant memory |
| `fetch (α := T) q` / `fetchJson q` | the documents of a `fetch` query |
| `Tx.answer q` | the raw answer (`ok`, `rows` or `docs`) |
