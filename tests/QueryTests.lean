import Harness
import CoreTests

/-! Integration tests: queries, escaping and decoding. -/

namespace QueryTests

open TypeDB Harness

def schema : Query .schema :=
  typeql!"define attribute name, value string; attribute age, value integer;
    attribute price, value decimal; attribute at, value datetime-tz; attribute day, value date;
    attribute stamp, value datetime; attribute every, value duration; attribute ratio, value double;
    attribute flag, value boolean; attribute text, value string; attribute idx, value integer;
    entity person, owns name, owns age, owns friend-count;
    attribute friend-count, value integer;
    entity item, owns idx, owns price, owns at, owns day, owns stamp, owns every, owns ratio,
      owns flag, owns text @card(0..);
    relation knows, relates a, relates b; person plays knows:a, plays knows:b;"

def setup (c : Ctx) : EIO TypeDBError Unit := c.driver.runSync c.db .schema (exec schema)

def addPeople (c : Ctx) : EIO TypeDBError Unit := c.driver.runSync c.db .write do
  exec typeql!"insert $p isa person, has name \"Ann\", has age 42;"
  exec typeql!"insert $p isa person, has name \"Bob\";"

/-- 200 strings drawn from an alphabet of quotes, escapes, TypeQL punctuation and Unicode. -/
def hostileStrings : IO (Array String) := do
  let alphabet := "ab \"'\\;{}$#\n\t\r\x01é漢🎉()[],.:=".toList.toArray
  let mut out := #["", "\"", "\\", "\\\"", "x\"; delete $p; match $q isa person; \""]
  for _ in [0:195] do
    let len ← IO.rand 0 24
    let mut s := ""
    for _ in [0:len] do s := s.push alphabet[← IO.rand 0 (alphabet.size - 1)]!
    out := out.push s
  return out

/-! ## Query -/

-- @tg: verifies:: [[openspec:query#Injection-safe escaping#Round-trip of hostile strings]] {level: integration}
def hostileRoundTrip : Test := ⟨"query: hostile strings round trip", fun c => do
  setup c
  let strings ← hostileStrings
  c.driver.runSync c.db .write do
    for (s, i) in strings.zipIdx do
      exec typeql!"insert $i isa item, has idx {i}, has text {s};"
  let rows ← c.driver.runSync c.db .read
    (query (α := Col "i" Int64 × Col "t" String) typeql!"match $x isa item, has idx $i, has text $t;")
  checkEq rows.size strings.size "rows"
  for (i, t) in rows do
    checkEq t.val strings[i.val.toInt.toNat]! s!"string {i.val.toInt}"⟩

-- @tg: verifies:: [[openspec:query#Injection-safe escaping#Injection attempt is inert]] {level: integration}
def injectionInert : Test := ⟨"query: injection attempt is inert", fun c => do
  setup c
  addPeople c
  let evil := "x\"; delete $p; match $q isa person; \""
  c.driver.runSync c.db .write (exec typeql!"insert $i isa item, has text {evil};")
  let texts ← c.driver.runSync c.db .read (query (α := Col "t" String) typeql!"match $i isa item, has text $t;")
  checkEq (texts.map (·.val)) #[evil] "one attribute with the exact value"
  let names ← c.driver.runSync c.db .read (query (α := Col "n" String) typeql!"match $p isa person, has name $n;")
  checkEq names.size 2 "people untouched"⟩

-- @tg: verifies:: [[openspec:query#Typed interpolation#Datetime literal]] {level: integration}
def datetimeLiteral : Test := ⟨"query: datetime-tz interpolation is accepted", fun c => do
  setup c
  let dt : DatetimeTZ := { seconds := 1700000000, nanos := 123, zone := .fixed 19800, offsetSeconds := 19800 }
  c.driver.runSync c.db .write (exec typeql!"insert $i isa item, has at {dt};")
  let back ← c.driver.runSync c.db .read (queryOne (α := Col "a" DatetimeTZ) typeql!"match $i isa item, has at $a;")
  checkEq back.val dt "datetime-tz"⟩

-- @tg: verifies:: [[openspec:query#Query answers#Define returns ok]] {level: integration}
def defineOk : Test := ⟨"query: define answers ok", fun c => do
  let a ← c.driver.runSync c.db .schema (do
    match ← Tx.answer typeql!"define entity thing;" with
    | .ok => pure true
    | _ => pure false)
  check a "ok answer"⟩

-- @tg: verifies:: [[openspec:query#Query answers#Fetch returns documents]] {level: integration}
def fetchDocs : Test := ⟨"query: fetch answers documents", fun c => do
  setup c
  addPeople c
  let docs ← c.driver.runSync c.db .read
    (fetchJson typeql!"match $p isa person, has name $n; fetch \{ \"name\": $n };")
  checkEq docs.size 2 "documents"⟩

/-! ## Decoding -/

-- @tg: verifies:: [[openspec:decoding#Row decoder#Decode two columns]] {level: integration}
def twoColumns : Test := ⟨"decoding: two columns", fun c => do
  setup c
  addPeople c
  let rows ← c.driver.runSync c.db .read (queryWith (Prod.mk <$> col (α := String) "n" <*> col (α := Int64) "a")
    typeql!"match $p isa person, has name $n, has age $a;")
  checkEq (rows.map fun (n, a) => (n, a.toInt)) #[("Ann", 42)] "rows"⟩

-- @tg: verifies:: [[openspec:decoding#Row decoder#Type mismatch]] {level: integration}
def typeMismatch : Test := ⟨"decoding: type mismatch names the column", fun c => do
  setup c
  addPeople c
  let e ← expectError (c.driver.runSync c.db .read
      (query (α := Col "name" Int64) typeql!"match $p isa person, has name $name;"))
    (fun | .decode .. => true | _ => false) "decoding a string as an integer"
  match e with
  | .decode col expected got =>
    checkEq col "name" "column"
    checkEq expected "integer" "expected"
    check (Str.contains got "string") s!"got '{got}'"
  | _ => pure ()⟩

-- @tg: verifies:: [[openspec:decoding#Row decoder#Optional column]] {level: integration}
def optionalColumn : Test := ⟨"decoding: optional column", fun c => do
  setup c
  addPeople c
  let rows ← c.driver.runSync c.db .read (queryWith (Prod.mk <$> col (α := String) "n" <*> colOpt (α := Int64) "a")
    typeql!"match $p isa person, has name $n; try \{ $p has age $a; };")
  let sorted := rows.qsort (·.1 < ·.1)
  checkEq (sorted.map fun (n, a) => (n, a.map (·.toInt))) #[("Ann", some 42), ("Bob", none)] "rows"⟩

structure PersonRow where
  name : String
  age : Option Int64
  deriving FromRow

-- @tg: verifies:: [[openspec:decoding#Derived row decoders#Structure from rows]] {level: integration}
def derivedRows : Test := ⟨"decoding: derived structure decoder", fun c => do
  setup c
  addPeople c
  let rows ← c.driver.runSync c.db .read
    (query (α := PersonRow) typeql!"match $p isa person, has name $name; try \{ $p has age $age; };")
  let sorted := rows.qsort (·.name < ·.name)
  checkEq (sorted.map fun r => (r.name, r.age.map (·.toInt))) #[("Ann", some 42), ("Bob", none)] "rows"⟩

-- @tg: verifies:: [[openspec:decoding#Value type mapping#Decimal is exact]] {level: integration}
def decimalExact : Test := ⟨"decoding: decimal is exact", fun c => do
  setup c
  let d := (Decimal.ofString? "0.1234567890123456789").get!
  c.driver.runSync c.db .write (exec typeql!"insert $i isa item, has price {d};")
  let back ← c.driver.runSync c.db .read (queryOne (α := Col "p" Decimal) typeql!"match $i isa item, has price $p;")
  checkEq back.val d "decimal"⟩

-- @tg: verifies:: [[openspec:decoding#Value type mapping#Datetime-tz round trip]] {level: integration}
def datetimeTzRoundTrip : Test := ⟨"decoding: datetime-tz with an IANA zone round trips", fun c => do
  setup c
  let wall := Time.plainDateTimeOf 1720000000 987654321
  let dt ← DatetimeTZ.ofLocal wall "Europe/Kyiv"
  c.driver.runSync c.db .write (exec typeql!"insert $i isa item, has at {dt};")
  let back ← c.driver.runSync c.db .read (queryOne (α := Col "a" DatetimeTZ) typeql!"match $i isa item, has at $a;")
  checkEq back.val dt "datetime-tz"
  checkEq back.val.offsetSeconds 10800 "summer offset of Kyiv"⟩

def otherValues : Test := ⟨"decoding: every value type round trips", fun c => do
  setup c
  let day := Std.Time.PlainDate.ofYearMonthDayClip 1999 12 31
  let stamp := Time.plainDateTimeOf (-86399) 1
  let every : Duration := { months := 13, days := 2, nanos := 5_000_000_001 }
  c.driver.runSync c.db .write (exec typeql!"insert $i isa item, has day {day}, has stamp {stamp},
    has every {every}, has ratio {(0.1 : Float)}, has flag {true};")
  let (d, s, e, r, f) ← c.driver.runSync c.db .read (queryOne
    (α := Col "d" Std.Time.PlainDate × Col "s" Std.Time.PlainDateTime × Col "e" Duration × Col "r" Float × Col "f" Bool)
    typeql!"match $i isa item, has day $d, has stamp $s, has every $e, has ratio $r, has flag $f;")
  check (d.val == day) "date"
  check (Time.splitPlainDateTime s.val == Time.splitPlainDateTime stamp) "datetime"
  checkEq e.val every "duration"
  check (r.val == 0.1) "double"
  checkEq f.val true "boolean"⟩

-- @tg: verifies:: [[openspec:decoding#Value type mapping#Nat range check]] {level: integration}
def natRange : Test := ⟨"decoding: negative integer as Nat fails", fun c => do
  setup c
  c.driver.runSync c.db .write (exec typeql!"insert $p isa person, has age {(-3 : Int64)};")
  discard <| expectError (c.driver.runSync c.db .read (query (α := Col "a" Nat) typeql!"match $p isa person, has age $a;"))
    (fun | .decode .. => true | _ => false) "negative as Nat"⟩

-- @tg: verifies:: [[openspec:decoding#Batched row decoding#Batched and per-value paths agree]] {level: integration}
def pathsAgree : Test := ⟨"decoding: batched and per-value paths agree", fun c => do
  setup c
  let at_ ← DatetimeTZ.ofLocal (Time.plainDateTimeOf 1600000000 0) "America/New_York"
  c.driver.runSync c.db .write do
    for i in [0:50] do
      exec typeql!"insert $i isa item, has idx {i}, has price {Decimal.ofInt i}, has ratio {i.toFloat / 3},
        has flag {i % 2 == 0}, has every {Duration.ofSeconds i}, has at {at_};"
      if i % 3 == 0 then exec typeql!"match $i isa item, has idx {i}; insert $i has text {s!"t{i}"};"
  let d : RowDecoder (Concept × Option Concept × Concept × Concept × Option String) :=
    (·, ·, ·, ·, ·) <$> col "x" <*> colOpt "p" <*> col "r" <*> col "a" <*> colOpt "t"
  let q := typeql!"match $x isa item, has idx $i, has price $p, has ratio $r, has at $a; try \{ $x has text $t; }; sort $i;"
  let batched ← c.driver.runSync c.db .read (opts := { batchSize := 7 }) (queryWith d q)
  let perValue ← c.driver.runSync c.db .read (Tx.queryPerValue d q)
  checkEq batched.size 50 "rows"
  check (batched == perValue) "identical results"⟩

structure FriendDoc where
  n : String
  deriving Lean.FromJson, Inhabited

structure Doc where
  name : String
  friends : List FriendDoc
  deriving Lean.FromJson, Inhabited

-- @tg: verifies:: [[openspec:decoding#Document decoding#Nested fetch]] {level: integration}
def nestedFetch : Test := ⟨"decoding: nested fetch documents", fun c => do
  setup c
  c.driver.runSync c.db .write do
    exec typeql!"insert $a isa person, has name \"Ann\"; $b isa person, has name \"Bob\"; $c isa person, has name \"Cy\";
      $k1 isa knows, links (a: $a, b: $b); $k2 isa knows, links (a: $a, b: $c);"
  let docs ← c.driver.runSync c.db .read (fetch (α := Doc) typeql!"match $p isa person, has name \"Ann\";
    fetch \{ \"name\": $p.name, \"friends\": [ match $k isa knows, links (a: $p, b: $f); fetch \{ \"n\": $f.name }; ] };")
  checkEq docs.size 1 "documents"
  checkEq docs[0]!.name "Ann" "name"
  checkEq ((docs[0]!.friends.map (·.n)).toArray.qsort (· < ·)) #["Bob", "Cy"] "nested list"⟩

-- @tg: verifies:: [[openspec:decoding#Strict results#Array of all rows]] {level: integration}
def strictAll : Test := ⟨"decoding: strict results of 1000 rows", fun c => do
  setup c
  c.driver.runSync c.db .write do
    for i in [0:1000] do exec typeql!"insert $i isa item, has idx {i};"
  let rows ← c.driver.runSync c.db .read (query (α := Col "i" Int64) typeql!"match $x isa item, has idx $i; sort $i;")
  checkEq (rows.map (·.val.toInt)) ((Array.range 1000).map Int.ofNat) "rows in answer order"⟩

-- @tg: verifies:: [[openspec:decoding#Scoped streaming#Fold in constant memory]] {level: integration}
def foldConstant : Test := ⟨"decoding: fold over a million rows", fun c => do
  setup c
  c.driver.runSync c.db .write do
    for i in [0:1000] do exec typeql!"insert $i isa item, has idx {i};"
  let before ← CoreTests.rssKb
  let (sum, n) ← c.driver.runSync c.db .read (opts := { batchSize := 512 })
    (queryFold (α := Col "a" Int64 × Col "b" Int64)
      typeql!"match $x isa item, has idx $a; $y isa item, has idx $b;" ((0 : Int), 0)
      fun (s, n) (a, b) => (s + a.val.toInt + b.val.toInt, n + 1))
  checkEq n 1000000 "rows"
  checkEq sum (2 * 1000 * (999 * 1000 / 2)) "sum"
  let after ← CoreTests.rssKb
  check (after < before + 200 * 1024) s!"RSS grew from {before} KB to {after} KB"⟩

-- @tg: verifies:: [[openspec:decoding#Scoped streaming#Early exit]] {level: integration}
def earlyExit : Test := ⟨"decoding: break out of a stream", fun c => do
  setup c
  c.driver.runSync c.db .write do
    for i in [0:100] do exec typeql!"insert $i isa item, has idx {i};"
  let (seen, after) ← c.driver.runSync c.db .read do
    let mut seen := 0
    for _ in stream (α := Col "i" Int64) typeql!"match $x isa item, has idx $i;" do
      seen := seen + 1
      if seen == 10 then break
    let after ← query (α := Col "i" Int64) typeql!"match $x isa item, has idx $i;"
    return (seen, after.size)
  checkEq seen 10 "rows seen"
  checkEq after 100 "the transaction still runs queries"⟩

def all : Array Test :=
  #[hostileRoundTrip, injectionInert, datetimeLiteral, defineOk, fetchDocs, twoColumns, typeMismatch,
    optionalColumn, derivedRows, decimalExact, datetimeTzRoundTrip, otherValues, natRange, pathsAgree,
    nestedFetch, strictAll, foldConstant, earlyExit]

end QueryTests
