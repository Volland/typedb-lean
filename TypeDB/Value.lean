import Std.Time
import TypeDB.Util

/-!
# TypeDB values

Lean representations of TypeDB 3 value types that keep every value exact: `Decimal` (TypeDB's
19-digit fixed point), `Duration` (months, days and nanoseconds, which do not normalise into each
other), `DatetimeTZ` (an instant plus the zone it was written in) and `IID`.

`Value` and `Concept` are the raw shapes the native layer produces. Their constructor order and
field order are mirrored by `ffi/typedb_lean.c`; change both together.
-/

namespace TypeDB

/-- An exact decimal `integer + fractional · 10⁻¹⁹` with `fractional < 10¹⁹`, TypeDB's
representation. Negative values have a negative `integer` and a non-negative `fractional`, so
`-1.5` is `⟨-2, 5 · 10¹⁸⟩`. -/
structure Decimal where
  integer : Int64
  fractional : UInt64
  deriving DecidableEq, Repr, Inhabited, Hashable

namespace Decimal

/-- `10¹⁹`, the number of fractional units in one. -/
def scale : Nat := 10 ^ 19

/-- The value multiplied by `10¹⁹`, as an integer. -/
def toScaled (d : Decimal) : Int := d.integer.toInt * scale + d.fractional.toNat

/-- The decimal `n · 10⁻¹⁹`; the integer part wraps around if it does not fit in `Int64`. -/
def ofScaled (n : Int) : Decimal :=
  ⟨Int64.ofInt (n.fdiv scale), UInt64.ofNat (n.fmod scale).toNat⟩

def ofInt (n : Int) : Decimal := ofScaled (n * scale)

instance (n : Nat) : OfNat Decimal n := ⟨ofInt n⟩
instance : Add Decimal := ⟨fun a b => ofScaled (a.toScaled + b.toScaled)⟩
instance : Sub Decimal := ⟨fun a b => ofScaled (a.toScaled - b.toScaled)⟩
instance : Neg Decimal := ⟨fun a => ofScaled (-a.toScaled)⟩
instance : Mul Decimal := ⟨fun a b => ofScaled ((a.toScaled * b.toScaled).tdiv scale)⟩
instance : Ord Decimal := ⟨fun a b => compare a.toScaled b.toScaled⟩
instance : LT Decimal := ⟨fun a b => a.toScaled < b.toScaled⟩
instance : LE Decimal := ⟨fun a b => a.toScaled ≤ b.toScaled⟩
instance (a b : Decimal) : Decidable (a < b) := inferInstanceAs (Decidable (_ < _))
instance (a b : Decimal) : Decidable (a ≤ b) := inferInstanceAs (Decidable (_ ≤ _))

/-- Plain decimal notation with no trailing zeros, e.g. `-1.5`, `3.0`. -/
protected def toString (d : Decimal) : String :=
  let n := d.toScaled
  let m := n.natAbs
  let digits := toString (m % scale)
  let frac := Str.dropRightWhile (Str.padLeft digits 19 '0') (· == '0')
  let frac := if frac.isEmpty then "0" else frac
  (if n < 0 then "-" else "") ++ toString (m / scale) ++ "." ++ frac

instance : ToString Decimal := ⟨Decimal.toString⟩

/-- Parses `[-]digits[.digits][dec]` with at most 19 fractional digits. -/
def ofString? (s : String) : Option Decimal := do
  let s := if s.endsWith "dec" then Str.dropRight s 3 else s
  let (neg, s) := if s.startsWith "-" then (true, Str.dropLeft s 1) else (false, s)
  let (whole, frac) := match s.splitOn "." with
    | [w] => (w, "")
    | [w, f] => (w, f)
    | _ => ("", "x")
  guard (!whole.isEmpty && whole.all Char.isDigit && frac.all Char.isDigit && frac.length ≤ 19)
  let w := whole.toNat!
  let f := (frac ++ "".pushn '0' (19 - frac.length)).toNat!
  let n : Int := w * scale + f
  return ofScaled (if neg then -n else n)

end Decimal

/-- A TypeDB duration. Months, days and nanoseconds are kept apart because their lengths vary:
a month is not a fixed number of days and a day is not always 24 hours. -/
structure Duration where
  months : UInt32 := 0
  days : UInt32 := 0
  nanos : UInt64 := 0
  deriving DecidableEq, Repr, Inhabited, Hashable

namespace Duration

def nanosPerSecond : Nat := 1000000000

/-- ISO 8601 notation, as TypeQL writes duration literals: `P1Y2M3DT4H5M6.5S`. -/
def toISO (d : Duration) : String := Id.run do
  let y := d.months.toNat / 12
  let mo := d.months.toNat % 12
  let mut s := "P"
  if y > 0 then s := s ++ s!"{y}Y"
  if mo > 0 then s := s ++ s!"{mo}M"
  if d.days > 0 then s := s ++ s!"{d.days}D"
  let n := d.nanos.toNat
  if n > 0 then
    s := s ++ "T"
    let h := n / (3600 * nanosPerSecond)
    let mi := n / (60 * nanosPerSecond) % 60
    let sec := n / nanosPerSecond % 60
    let ns := n % nanosPerSecond
    if h > 0 then s := s ++ s!"{h}H"
    if mi > 0 then s := s ++ s!"{mi}M"
    if sec > 0 || ns > 0 then
      let frac := if ns == 0 then "" else
        let digits := toString ns
        "." ++ Str.dropRightWhile (Str.padLeft digits 9 '0') (· == '0')
      s := s ++ s!"{sec}{frac}S"
  if s == "P" then "PT0S" else s

instance : ToString Duration := ⟨toISO⟩

def ofSeconds (s : Nat) : Duration := { nanos := UInt64.ofNat (s * nanosPerSecond) }

end Duration

/-- How a datetime-tz names its zone. -/
inductive Zone where
  /-- An IANA zone such as `Europe/London`. -/
  | iana (name : String)
  /-- A fixed offset from UTC, in seconds. -/
  | fixed (offsetSeconds : Int32)
  deriving DecidableEq, Repr, Inhabited

/-- A TypeDB `datetime-tz`: the instant (UTC seconds and nanoseconds since the Unix epoch), the
zone it is expressed in, and the zone's UTC offset at that instant. The offset is what lets the
value be printed back as local time without loading zone rules. -/
structure DatetimeTZ where
  seconds : Int64
  nanos : UInt32 := 0
  zone : Zone
  offsetSeconds : Int32
  deriving DecidableEq, Repr, Inhabited

/-- An instance identifier, as TypeDB prints it (`0x1e00…`). -/
structure IID where
  hex : String
  deriving DecidableEq, Hashable, Repr, Inhabited, Ord

instance : ToString IID := ⟨IID.hex⟩

/-- A value as the native layer reports it. Constructor and field order are mirrored by
`ffi/typedb_lean.c`. -/
inductive Value where
  | bool (b : Bool)
  | integer (i : Int64)
  | double (d : Float)
  | decimal (integer : Int64) (fractional : UInt64)
  | string (s : String)
  /-- A date, as the seconds since the Unix epoch of its midnight. -/
  | date (seconds : Int64)
  /-- A datetime without zone, as UTC seconds and nanoseconds since the Unix epoch. -/
  | datetime (seconds : Int64) (nanos : UInt32)
  /-- `offset` is only meaningful when `fixed`; IANA zones report their name and offset 0. -/
  | datetimeTz (seconds : Int64) (nanos : UInt32) (zone : String) (offset : Int32) (fixed : Bool)
  | duration (months : UInt32) (days : UInt32) (nanos : UInt64)
  deriving Repr, Inhabited, BEq

namespace Value

/-- The TypeDB name of the value's type, used in decode errors. -/
def typeName : Value → String
  | bool .. => "boolean" | integer .. => "integer" | double .. => "double"
  | decimal .. => "decimal" | string .. => "string" | date .. => "date"
  | datetime .. => "datetime" | datetimeTz .. => "datetime-tz" | duration .. => "duration"

end Value

/-- A concept in an answer row. Constructor and field order are mirrored by `ffi/typedb_lean.c`.
Fields the decoder did not ask for (see `Plan`) are left as empty strings. -/
inductive Concept where
  | entity (iid : String) (label : String)
  | relation (iid : String) (label : String)
  | attribute (label : String) (value : Value)
  | value (v : Value)
  | entityType (label : String)
  | relationType (label : String)
  | attributeType (label : String)
  | roleType (label : String)
  deriving Repr, Inhabited, BEq

namespace Concept

/-- The value of an attribute or value concept. -/
def value? : Concept → Option Value
  | .attribute _ v => some v
  | .value v => some v
  | _ => none

/-- The IID of an entity or relation. -/
def iid? : Concept → Option IID
  | .entity i _ | .relation i _ => some ⟨i⟩
  | _ => none

/-- The type label of an instance, or the label of a type. -/
def label? : Concept → Option String
  | .entity _ l | .relation _ l | .attribute l _ => some l
  | .entityType l | .relationType l | .attributeType l | .roleType l => some l
  | .value _ => none

/-- A short description used in decode errors. -/
def describe : Concept → String
  | .entity .. => "entity" | .relation .. => "relation"
  | .attribute _ v => s!"{v.typeName} attribute" | .value v => s!"{v.typeName} value"
  | .entityType .. => "entity type" | .relationType .. => "relation type"
  | .attributeType .. => "attribute type" | .roleType .. => "role type"

end Concept

/-! ## Conversions to and from Std.Time -/

namespace Time
open Std.Time

def secondsPerDay : Int := 86400

def timestampOf (seconds : Int64) (nanos : UInt32) : Timestamp :=
  Timestamp.ofNanosecondsSinceUnixEpoch
    (Nanosecond.Offset.ofInt (seconds.toInt * 1000000000 + nanos.toNat))

/-- UTC seconds and sub-second nanoseconds of a timestamp. -/
def splitTimestamp (t : Timestamp) : Int64 × UInt32 :=
  let n := t.toNanosecondsSinceUnixEpoch.val
  (Int64.ofInt (n.fdiv 1000000000), UInt32.ofNat (n.fmod 1000000000).toNat)

def plainDateOfSeconds (seconds : Int64) : PlainDate :=
  PlainDate.ofEpochDay (Day.Offset.ofInt (seconds.toInt.fdiv secondsPerDay))

def secondsOfPlainDate (d : PlainDate) : Int64 :=
  Int64.ofInt (d.toEpochDay.val * secondsPerDay)

def plainDateTimeOf (seconds : Int64) (nanos : UInt32) : PlainDateTime :=
  (DateTime.ofTimestamp (timestampOf seconds nanos) TimeZone.ZoneRules.UTC).toPlainDateTime

def splitPlainDateTime (pdt : PlainDateTime) : Int64 × UInt32 :=
  splitTimestamp (pdt.toTimestamp TimeZone.ZoneRules.UTC)

end Time

namespace DatetimeTZ
open Std.Time

def timestamp (d : DatetimeTZ) : Timestamp := Time.timestampOf d.seconds d.nanos

/-- The local wall time in the value's zone. -/
def localTime (d : DatetimeTZ) : PlainDateTime :=
  Time.plainDateTimeOf (d.seconds + Int64.ofInt d.offsetSeconds.toInt) d.nanos

/-- The value as a `Std.Time.DateTime` whose zone is fixed at the value's offset. The instant and
local time are exact; date arithmetic across a DST change needs `toDateTimeWithRules`. -/
def toDateTime (d : DatetimeTZ) : DateTime :=
  let name := match d.zone with | .iana n => n | .fixed _ => ""
  let tz := TimeZone.ofSeconds name name (Second.Offset.ofInt d.offsetSeconds.toInt)
  DateTime.ofTimestampWithZone d.timestamp tz

/-- The value as a `Std.Time.DateTime` with the full rules of its IANA zone. -/
def toDateTimeWithRules (d : DatetimeTZ) : IO DateTime := do
  match d.zone with
  | .fixed _ => return d.toDateTime
  | .iana name => return DateTime.ofTimestamp d.timestamp (← Database.defaultGetZoneRules name)

/-- The instant of a `Std.Time.DateTime`, at its current offset. Pass `iana` to keep the zone's
name, e.g. `Europe/London`; otherwise the value carries a fixed offset. -/
def ofDateTime (dt : DateTime) (iana : Option String := none) : DatetimeTZ :=
  let (s, n) := Time.splitTimestamp dt.toTimestamp
  let off := Int32.ofInt dt.timezone.offset.second.val
  { seconds := s, nanos := n, offsetSeconds := off, zone := match iana with
    | some name => .iana name
    | none => .fixed off }

/-- A local time in an IANA zone, resolved with the zone's rules. -/
def ofLocal (pdt : PlainDateTime) (iana : String) : IO DatetimeTZ := do
  let rules ← Database.defaultGetZoneRules iana
  return ofDateTime (DateTime.ofPlainDateTime pdt rules) (some iana)

/-- A local time at a fixed UTC offset in seconds. -/
def ofLocalFixed (pdt : PlainDateTime) (offsetSeconds : Int32) : DatetimeTZ :=
  let (s, n) := Time.splitPlainDateTime pdt
  { seconds := s - Int64.ofInt offsetSeconds.toInt, nanos := n, offsetSeconds, zone := .fixed offsetSeconds }

end DatetimeTZ

end TypeDB
