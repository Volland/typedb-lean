# Decoding

## Row decoders

A `RowDecoder α` reads named columns of a concept row. Build one with `col` and `colOpt` and combine them applicatively:

```lean
let d : RowDecoder (String × Option Int64) := Prod.mk <$> col "name" <*> colOpt "age"
let rows ← queryWith d typeql!"match $p isa person, has name $name; try \{ $p has age $age; };"
```

`colOpt` reads a column that may be empty (from a `try` block) as `none`. A missing column, or a value of the wrong type, fails with `TypeDBError.decode column expected got`.

## `deriving FromRow`

For structures, derive the decoder. Each field reads the variable of the same name, and `Option` fields are optional columns:

```lean
structure PersonRow where
  name : String
  age : Option Int64
  deriving FromRow

let people ← query (α := PersonRow) typeql!"match $p isa person, has name $name; try \{ $p has age $age; };"
```

`Col "v" T` decodes a single column, and pairs of `FromRow` types decode side by side: `query (α := Col "n" String × Col "a" Int64) q`.

## Value types

| TypeDB | Lean |
|---|---|
| `integer` | `Int64` (also `Int`, and `Nat` with a range check) |
| `double` | `Float` |
| `boolean` | `Bool` |
| `string` | `String` |
| `decimal` | `TypeDB.Decimal`: exact, 19 fractional digits |
| `date` | `Std.Time.PlainDate` |
| `datetime` | `Std.Time.PlainDateTime` |
| `datetime-tz` | `TypeDB.DatetimeTZ` (instant, offset, IANA zone or fixed offset), or `Std.Time.DateTime` |
| `duration` | `TypeDB.Duration`: months, days and nanoseconds, kept apart |

`IID`, `Label` (the type label of a concept) and `Concept` (everything) decode from instance columns. For an IANA-zoned datetime the library resolves the zone's UTC offset when it decodes the value. `DatetimeTZ.toDateTimeWithRules` gives a `Std.Time.DateTime` carrying the zone's full rules.

## Streaming

`query` builds an array. For large answers, fold or loop instead; rows are decoded one batch at a time and memory stays constant:

```lean
let total ← queryFold (α := Col "a" Int64) typeql!"match $p has age $a;" 0 fun s a => s + a.val.toInt
for p in stream (α := PersonRow) typeql!"match $p isa person, has name $name;" do
  if p.name == "Ann" then break
```

A stream belongs to its transaction: it is released when the loop finishes, breaks or throws, and it cannot be returned out of the body.

## Documents

`fetch` decodes the JSON documents of a `fetch` query with `Lean.FromJson`:

```lean
structure Doc where
  name : String
  deriving Lean.FromJson

let docs ← fetch (α := Doc) typeql!"match $p isa person; fetch \{ \"name\": $p.name };"
```
