import TypeDB.Error
import TypeDB.TypeQL

/-!
# Decoding answers

A `RowDecoder α` reads named columns of a concept row and builds an `α`. Decoders compose as an
applicative, and every decoder knows up front which columns it reads and which parts of each
concept it needs (its `plan`). The query layer hands the plan to the native batch call, which
returns exactly those concepts for many rows at once.

`FromConcept` says how one column becomes a Lean value. `deriving FromRow` (see
`TypeDB.Deriving.FromRow`) maps each structure field to the query variable of the same name.
-/

namespace TypeDB

/-- Column flag, Lean side only: resolve the UTC offset of IANA-zoned datetimes. -/
def wantZone : UInt8 := 4

/-- How one column of a row becomes a Lean value. -/
-- @tg: implements:: [[openspec:decoding#Value type mapping]]
class FromConcept (α : Type) where
  /-- The expected shape, for decode errors (`"string"`, `"entity"`, …). -/
  expected : String
  /-- Which parts of the concept the native layer must read (see `Native.wantLabel`). -/
  flags : UInt8 := 0
  /-- The value, or a description of what the concept is instead. -/
  decode : Concept → Except String α

/-- Decodes the value of an attribute or value concept with `f`. -/
@[instance_reducible] def FromConcept.ofValue {α : Type} (expected : String) (f : Value → Option α) (flags : UInt8 := 0) :
    FromConcept α where
  expected
  flags
  decode c := match c.value? with
    | some v => match f v with
      | some a => .ok a
      | none => .error c.describe
    | none => .error c.describe

section instances
open FromConcept

instance : FromConcept String := ofValue "string" fun | .string s => some s | _ => none
instance : FromConcept Bool := ofValue "boolean" fun | .bool b => some b | _ => none
instance : FromConcept Int64 := ofValue "integer" fun | .integer i => some i | _ => none
instance : FromConcept Int := ofValue "integer" fun | .integer i => some i.toInt | _ => none
/-- Rejects negative integers. -/
instance : FromConcept Nat where
  expected := "non-negative integer"
  decode c := match c.value? with
    | some (.integer i) => if i.toInt ≥ 0 then .ok i.toInt.toNat else .error s!"integer {i.toInt}"
    | _ => .error c.describe
instance : FromConcept Float := ofValue "double" fun | .double d => some d | _ => none
instance : FromConcept Decimal := ofValue "decimal" fun | .decimal i f => some ⟨i, f⟩ | _ => none
instance : FromConcept Duration := ofValue "duration" fun
  | .duration mo d n => some ⟨mo, d, n⟩ | _ => none
instance : FromConcept Std.Time.PlainDate := ofValue "date" fun
  | .date s => some (Time.plainDateOfSeconds s) | _ => none
instance : FromConcept Std.Time.PlainDateTime := ofValue "datetime" fun
  | .datetime s n => some (Time.plainDateTimeOf s n) | _ => none
instance : FromConcept DatetimeTZ := ofValue "datetime-tz" (flags := wantZone) fun
  | .datetimeTz s n zone off fixed =>
    some { seconds := s, nanos := n, offsetSeconds := off,
           zone := if fixed then .fixed off else .iana zone }
  | _ => none
/-- A `Std.Time.DateTime` at the value's offset; see `DatetimeTZ.toDateTime`. -/
instance : FromConcept Std.Time.DateTime where
  expected := "datetime-tz"
  flags := wantZone
  decode c := (FromConcept.decode c : Except String DatetimeTZ).map DatetimeTZ.toDateTime
instance : FromConcept Value := ⟨"value", 0, fun c => match c.value? with
  | some v => .ok v | none => .error c.describe⟩
instance : FromConcept IID where
  expected := "entity or relation"
  flags := Native.wantIID
  decode c := match c.iid? with | some i => .ok i | none => .error c.describe
/-- The whole concept, with its label and IID. -/
instance : FromConcept Concept := ⟨"concept", Native.wantLabel ||| Native.wantIID, .ok⟩

end instances

/-- The type label of a concept: an instance's type, or a type itself. -/
structure Label where
  name : String
  deriving DecidableEq, Repr, Inhabited, Hashable

instance : FromConcept Label where
  expected := "type or instance"
  flags := Native.wantLabel
  decode c := match c.label? with | some l => .ok ⟨l⟩ | none => .error c.describe

/-- Reads columns of a concept row. `columns` lists, in order, the variables it reads and the
flags for each; `run` gets the concepts for those columns starting at `offset`. -/
-- @tg: implements:: [[openspec:decoding#Row decoder]]
structure RowDecoder (α : Type) where
  columns : Array (String × UInt8)
  run : Array (Option Concept) → (offset : Nat) → Except TypeDBError α

namespace RowDecoder

variable {α β : Type}

instance : Functor RowDecoder where
  map f d := { d with run := fun r o => f <$> d.run r o }

instance : Applicative RowDecoder where
  pure a := ⟨#[], fun _ _ => .ok a⟩
  seq f x :=
    let dx := x ()
    ⟨f.columns ++ dx.columns, fun r o => do
      let g ← f.run r o
      let a ← dx.run r (o + f.columns.size)
      return g a⟩

/-- Fails the decode of every row with `err` if `ok` is false. -/
def guard (ok : α → Bool) (err : α → TypeDBError) (d : RowDecoder α) : RowDecoder α :=
  { d with run := fun r o => do let a ← d.run r o; if ok a then pure a else throw (err a) }

/-- Column names and per-column flags, as the native batch call takes them. -/
def plan (d : RowDecoder α) : Array String × ByteArray :=
  (d.columns.map (·.1), ⟨d.columns.map (·.2)⟩)

end RowDecoder

/-- The required column `name`. -/
def col {α : Type} (name : String) [i : FromConcept α] : RowDecoder α :=
  ⟨#[(name, i.flags)], fun r o => match r[o]? with
    | some (some c) => (i.decode c).mapError (.decode name i.expected ·)
    | _ => .error (.decode name i.expected "empty")⟩

/-- The optional column `name`: `none` when the row leaves it empty (e.g. from a `try`). -/
def colOpt {α : Type} (name : String) [i : FromConcept α] : RowDecoder (Option α) :=
  ⟨#[(name, i.flags)], fun r o => match r[o]? with
    | some (some c) => (i.decode c).map some |>.mapError (.decode name i.expected ·)
    | _ => .ok none⟩

/-- How a structure field reads its column; `Option` fields are optional. -/
class FromColumn (α : Type) where
  column : String → RowDecoder α

instance (priority := low) {α : Type} [FromConcept α] : FromColumn α := ⟨fun n => col n⟩
instance {α : Type} [FromConcept α] : FromColumn (Option α) := ⟨fun n => colOpt n⟩

/-- Types decoded from a whole row. Derive it for structures with `deriving FromRow`. -/
class FromRow (α : Type) where
  decoder : RowDecoder α

/-- A single named column. -/
structure Col (name : String) (α : Type) where
  val : α
  deriving Repr, Inhabited

instance {name : String} {α : Type} [FromConcept α] : FromRow (Col name α) := ⟨(⟨·⟩) <$> col name⟩

instance {α β : Type} [FromRow α] [FromRow β] : FromRow (α × β) :=
  ⟨Prod.mk <$> FromRow.decoder <*> FromRow.decoder⟩

end TypeDB
