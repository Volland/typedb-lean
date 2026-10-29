import Harness
import Model

/-! Tests that need no server. -/

namespace UnitTests

open TypeDB Harness

-- @tg: verifies:: [[openspec:query#Typed interpolation#Integer and string]] {level: unit}
def interpolation : UnitTest := ⟨"query: integer and string interpolation", do
  let name := "Ann"
  let q := typeql!"match $p isa person, has name {name}, has age {(42 : Int64)};"
  unitEq q.text "match $p isa person, has name \"Ann\", has age 42;" "query text"⟩

-- @tg: verifies:: [[openspec:query#Explicit raw splicing#Raw label]] {level: unit}
def rawLabel : UnitTest := ⟨"query: raw label splices verbatim", do
  let label := Raw.mk "person"
  unitEq (typeql!"match $p isa {label};").text "match $p isa person;" "query text"⟩

def escaping : UnitTest := ⟨"query: string escaping", do
  unitEq (render "a\"b\\c\nd\te") "\"a\\\"b\\\\c\\nd\\te\"" "escaped"
  unitEq (render "\x01") "\"\\u0001\"" "control character"
  unitEq (render "ünï ✓") "\"ünï ✓\"" "unicode kept"⟩

def modeInference : UnitTest := ⟨"query: transaction mode inference", do
  unitEq (TypeQL.inferMode "match $x isa person;") .read "match"
  unitEq (TypeQL.inferMode "match $x isa person; insert $x has name \"a\";") .write "insert"
  unitEq (TypeQL.inferMode "define entity person;") .schema "define"
  unitEq (TypeQL.inferMode "match $x has name \"insert\";") .read "keyword inside a string"
  unitEq (TypeQL.inferMode "match $delete isa person;") .read "keyword as a variable"⟩

def literals : UnitTest := ⟨"query: value literals", do
  unitEq (render (Decimal.ofString? "-1.5").get!) "-1.5dec" "decimal"
  unitEq (render (0.1 : Float)) "0.1000000000000000055511151231257827021181583404541015625" "exact double"
  unitEq (render (2.0 : Float)) "2.0" "integral double"
  unitEq (render ({ months := 14, days := 3, nanos := 3_723_500_000_000 } : Duration)) "P1Y2M3DT1H2M3.5S" "duration"
  unitEq (render (Duration.mk 0 0 0)) "PT0S" "zero duration"
  unitEq (render (Std.Time.PlainDate.ofYearMonthDayClip 2024 2 29)) "2024-02-29" "date"
  let dt : DatetimeTZ := { seconds := 1700000000, nanos := 5, zone := .fixed (-3600), offsetSeconds := -3600 }
  unitEq (render dt) "2023-11-14T21:13:20.000000005-01:00" "datetime-tz"⟩

def decimals : UnitTest := ⟨"values: decimal arithmetic and parsing", do
  let a := (Decimal.ofString? "0.1234567890123456789").get!
  unitEq a.toString "0.1234567890123456789" "19 digits"
  unitEq ((Decimal.ofString? "-1.5").get!) ⟨-2, 5000000000000000000⟩ "negative representation"
  unitEq ((1 : Decimal) + (Decimal.ofString? "0.5").get!).toString "1.5" "addition"
  unitEq ((Decimal.ofString? "2.5").get! * (Decimal.ofString? "-2").get!).toString "-5.0" "multiplication"
  unitCheck (Decimal.ofString? "1.2.3").isNone "invalid input"⟩

-- @tg: verifies:: [[openspec:orm#Schema generation#Golden define]] {level: unit}
def goldenSchema : UnitTest := ⟨"orm: generated define matches the golden file", do
  let expected ← IO.FS.readFile "tests/golden/model.tql"
  match Schema.defineText Model.schema with
  | .ok text => unitEq text expected "define text"
  | .error e => throw (IO.userError e)⟩

def plan : UnitTest := ⟨"decoding: plans list columns and flags in order", do
  let d : RowDecoder (String × Option IID × Concept) := (·, ·, ·) <$> col "n" <*> colOpt "x" <*> col "c"
  let (cols, flags) := d.plan
  unitEq cols #["n", "x", "c"] "columns"
  unitEq flags.toList [0, Native.wantIID, Native.wantLabel ||| Native.wantIID] "flags"⟩

def insertText : UnitTest := ⟨"orm: insert text", do
  let p : Model.Person := { email := "a@x", name := "A", tags := #["t1", "t2"] }
  unitEq (ORM.insertText p) "insert $x isa person, has email \"a@x\", has name \"A\", has tags \"t1\", has tags \"t2\";" "insert"
  let f : Model.Friendship := { a := Ref.key "a@x", b := Ref.iid ⟨"0x1e00"⟩, since := 2020 }
  unitEq (ORM.insertText f)
    "match $p0 isa person, has email \"a@x\"; $p1 iid 0x1e00; $p1 isa person;\ninsert $x isa friendship, links (friend: $p0, friend: $p1), has since 2020;"
    "relation insert"⟩

-- @tg: verifies:: [[openspec:native-driver#Pinned driver build#Version is pinned in one place]] {level: unit}
def versionPin : UnitTest := ⟨"native: one version pin", do
  let lakefile ← IO.FS.readFile "lakefile.lean"
  unitCheck (Str.contains lakefile "include_str \"TYPEDB_VERSION\"") "lakefile reads TYPEDB_VERSION"
  unitCheck (Harness.typedbVersion.length ≥ 5) "TYPEDB_VERSION is set"
  let ci ← IO.FS.readFile ".github/workflows/ci.yaml"
  unitCheck (Str.contains ci "lake run typedb-version") "CI reads the pin through lake"
  let bench ← IO.FS.readFile "bench/rust/Cargo.toml"
  unitCheck (Str.contains bench s!"\"={Harness.typedbVersion}\"") "the Rust benchmark uses the pinned driver"⟩

-- @tg: verifies:: [[openspec:native-driver#Supported platforms#CI matrix is green]] {level: unit}
def ciMatrix : UnitTest := ⟨"native: CI matrix covers every platform", do
  let ci ← IO.FS.readFile ".github/workflows/ci.yaml"
  for os in ["ubuntu-latest", "ubuntu-24.04-arm", "macos-14"] do
    unitCheck (Str.contains ci s!"os: {os}") s!"{os} in the matrix"
  let blocks := (ci.splitOn "- os: ").drop 1
  let integration := blocks.filter (Str.contains · "integration: true")
  unitEq (integration.map fun b => String.ofList (b.toList.takeWhile (· != '\n'))) ["ubuntu-latest", "ubuntu-24.04-arm"] "integration runners"
  unitCheck (Str.contains ci "run: lake test -- --unit") "macOS runs the unit tests"⟩

def migrationValidation : UnitTest := ⟨"migrations: list validation", do
  let ok := [Migration.tql 1 "a" "define entity a;", Migration.tql 2 "b" "define entity b;"]
  unitCheck (Migrations.validate ok matches .ok ()) "valid list"
  let dup := [Migration.tql 1 "a" "define entity a;", Migration.tql 1 "b" "define entity b;"]
  unitCheck (Migrations.validate dup matches .error (.migration 1 _)) "duplicate version"⟩

def all : Array UnitTest :=
  #[interpolation, rawLabel, escaping, modeInference, literals, decimals, goldenSchema, plan,
    insertText, versionPin, ciMatrix, migrationValidation]

end UnitTests
