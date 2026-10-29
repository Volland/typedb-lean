import TypeDB.Value
import TypeDB.Util

/-!
# TypeQL text

`typeql!"…"` builds a `Query` from TypeQL text. Each `{e}` is rendered by `ToTypeQL`, which
turns a Lean value into a TypeQL value literal: strings are quoted and escaped, so user data can
never change a query's structure. `Raw` is the only way to splice text verbatim.

The query's transaction mode is inferred from the literal parts: `define`, `undefine` or
`redefine` need a schema transaction, `insert`, `delete`, `update` or `put` a write transaction,
anything else a read transaction. TypeQL braces must be escaped as `\{` and `\}` because Lean
uses `{…}` for interpolation.
-/

namespace TypeDB

/-- The kind of a transaction, ordered by what it may do: `read ≤ write ≤ schema`. -/
inductive TxMode where
  | read
  | write
  | schema
  deriving DecidableEq, Repr, Inhabited, Ord

namespace TxMode

def rank : TxMode → Nat
  | read => 0 | write => 1 | schema => 2

instance : LE TxMode := ⟨fun a b => a.rank ≤ b.rank⟩
instance (a b : TxMode) : Decidable (a ≤ b) := inferInstanceAs (Decidable (a.rank ≤ b.rank))
instance : Max TxMode := ⟨fun a b => if a.rank ≤ b.rank then b else a⟩

/-- The driver's `TransactionType`. -/
def code : TxMode → UInt8
  | read => 0 | write => 1 | schema => 2

/-- `Allows cur need`: a transaction of mode `cur` may run an operation that needs `need`.
Resolved at compile time; a missing instance means the operation needs a stronger transaction. -/
class Allows (cur need : TxMode) : Prop where
  le : need ≤ cur

instance {m : TxMode} : Allows m .read := ⟨Nat.zero_le _⟩
instance : Allows .write .write := ⟨Nat.le_refl _⟩
instance : Allows .schema .write := ⟨by decide⟩
instance : Allows .schema .schema := ⟨Nat.le_refl _⟩

end TxMode

/-- TypeQL text and the weakest transaction mode that may run it. -/
structure Query (need : TxMode) where
  text : String
  deriving Inhabited

instance {m : TxMode} : ToString (Query m) := ⟨Query.text⟩

namespace Query

/-- A query from text the caller vouches for, with an explicit mode. -/
def raw (need : TxMode) (text : String) : Query need := ⟨text⟩

/-- Runs the query under a different mode requirement, e.g. to require a write transaction for a
read query whose mode the literal could not reveal. -/
def withMode {m : TxMode} (q : Query m) (need : TxMode) : Query need := ⟨q.text⟩

/-- Pipes two queries: `q₁ ++ q₂` runs `q₂`'s stages after `q₁`'s, needing the stronger mode. -/
def append {m n : TxMode} (q₁ : Query m) (q₂ : Query n) : Query (max m n) := ⟨q₁.text ++ "\n" ++ q₂.text⟩

end Query

/-- Text spliced into a query verbatim, such as a type label or a query fragment. -/
structure Raw where
  text : String
  deriving Inhabited, Repr

/-- Renders a Lean value as a TypeQL value literal. -/
class ToTypeQL (α : Type) where
  render : α → String

export ToTypeQL (render)

namespace TypeQL

/-- Quotes and escapes a string as a TypeQL string literal. -/
-- @tg: implements:: [[openspec:query#Injection-safe escaping]]
def quote (s : String) : String := Id.run do
  let mut out := "\""
  for c in s.toList do
    out := match c with
      | '"' => out ++ "\\\""
      | '\\' => out ++ "\\\\"
      | '\n' => out ++ "\\n"
      | '\r' => out ++ "\\r"
      | '\t' => out ++ "\\t"
      | '\x08' => out ++ "\\b"
      | '\x0c' => out ++ "\\f"
      | c =>
        if c.toNat < 0x20 then
          let h := String.ofList (Nat.toDigits 16 c.toNat)
          out ++ "\\u" ++ "".pushn '0' (4 - h.length) ++ h
        else out.push c
  return out.push '"'

private def pad (width : Nat) (n : Nat) : String :=
  let s := toString n
  "".pushn '0' (width - s.length) ++ s

/-- Civil date (year, month, day) of a day count since 1970-01-01 (Hinnant's algorithm). -/
def civilOfDays (z : Int) : Int × Nat × Nat :=
  let z := z + 719468
  let era := (if z ≥ 0 then z else z - 146096) / 146097
  let doe := (z - era * 146097).toNat
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y : Int := yoe + era * 400
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let d := doy - (153 * mp + 2) / 5 + 1
  let m := if mp < 10 then mp + 3 else mp - 9
  (if m ≤ 2 then y + 1 else y, m, d)

def dateText (days : Int) : String :=
  let (y, m, d) := civilOfDays days
  let year := if 0 ≤ y && y ≤ 9999 then pad 4 y.toNat
    else (if y < 0 then "-" else "+") ++ pad 4 y.natAbs
  s!"{year}-{pad 2 m}-{pad 2 d}"

/-- `YYYY-MM-DDTHH:MM:SS[.fffffffff]` for UTC seconds and nanoseconds since the epoch. -/
def datetimeText (seconds : Int) (nanos : Nat) : String :=
  let days := seconds.fdiv 86400
  let sod := (seconds.fmod 86400).toNat
  let frac := if nanos == 0 then "" else "." ++ Str.dropRightWhile (pad 9 nanos) (· == '0')
  s!"{dateText days}T{pad 2 (sod / 3600)}:{pad 2 (sod / 60 % 60)}:{pad 2 (sod % 60)}{frac}"

/-- `±HH:MM` for an offset in seconds. -/
def offsetText (offset : Int) : String :=
  let a := offset.natAbs
  (if offset < 0 then "-" else "+") ++ s!"{pad 2 (a / 3600)}:{pad 2 (a / 60 % 60)}"

/-- The exact decimal expansion of a finite double, or `none` for NaN and infinities. Every
double is `m · 2^e`, whose decimal expansion is finite, so the literal parses back to exactly the
same double. -/
def exactDouble (f : Float) : Option String :=
  let bits := f.toBits
  let neg := bits >>> 63 == 1
  let expBits := ((bits >>> 52) &&& 0x7FF).toNat
  let frac := (bits &&& 0xFFFFFFFFFFFFF).toNat
  if expBits == 0x7FF then none else
  let (m, e) : Nat × Int := if expBits == 0 then (frac, -1074) else (frac + 2 ^ 52, expBits - 1075)
  let sign := if neg then "-" else ""
  if e ≥ 0 then some s!"{sign}{m * 2 ^ e.toNat}.0" else
  let k := e.natAbs
  let n := m * 5 ^ k
  let digits := toString n
  let digits := "".pushn '0' (k + 1 - min (k + 1) digits.length) ++ digits
  let whole := Str.dropRight digits k
  let fracPart := Str.dropRightWhile (Str.takeRight digits k) (· == '0')
  some s!"{sign}{whole}.{if fracPart.isEmpty then "0" else fracPart}"

end TypeQL

section instances
open TypeQL

instance : ToTypeQL String := ⟨quote⟩
instance : ToTypeQL Raw := ⟨Raw.text⟩
instance : ToTypeQL Bool := ⟨fun b => if b then "true" else "false"⟩
instance : ToTypeQL Int := ⟨toString⟩
instance : ToTypeQL Nat := ⟨toString⟩
instance : ToTypeQL Int64 := ⟨fun i => toString i.toInt⟩
instance : ToTypeQL Int32 := ⟨fun i => toString i.toInt⟩
instance : ToTypeQL UInt64 := ⟨fun i => toString i.toNat⟩
instance : ToTypeQL UInt32 := ⟨fun i => toString i.toNat⟩
/-- Doubles render exactly. NaN and infinities have no TypeQL literal and render as `NaN` or
`inf`, which the server rejects. -/
instance : ToTypeQL Float := ⟨fun f => (exactDouble f).getD (if f.isNaN then "NaN" else "inf")⟩
instance : ToTypeQL Decimal := ⟨fun d => d.toString ++ "dec"⟩
instance : ToTypeQL Duration := ⟨Duration.toISO⟩
instance : ToTypeQL IID := ⟨IID.hex⟩
instance : ToTypeQL Std.Time.PlainDate := ⟨fun d => dateText d.toEpochDay.val⟩
instance : ToTypeQL Std.Time.PlainDateTime where
  render pdt := let (s, n) := Time.splitPlainDateTime pdt; datetimeText s.toInt n.toNat
instance : ToTypeQL DatetimeTZ where
  render d :=
    let wall := datetimeText (d.seconds.toInt + d.offsetSeconds.toInt) d.nanos.toNat
    match d.zone with
    | .iana name => wall ++ " " ++ name
    | .fixed off => wall ++ offsetText off.toInt
instance : ToTypeQL Std.Time.DateTime := ⟨fun dt => render (DatetimeTZ.ofDateTime dt)⟩

end instances

namespace TypeQL

/-- The weakest mode that can run TypeQL text, from its keywords outside string literals. -/
def inferMode (text : String) : TxMode := Id.run do
  let mut mode := TxMode.read
  let mut word := ""
  let mut inStr : Option Char := none
  let mut escaped := false
  let mut prev := ' '
  for c in text.toList ++ [' '] do
    if let some q := inStr then
      if escaped then escaped := false
      else if c == '\\' then escaped := true
      else if c == q then inStr := none
      continue
    if c.isAlpha || c == '-' || c == '_' || (c.isDigit && !word.isEmpty) then
      if word.isEmpty && (prev == '$' || prev == '@' || prev == '?') then
        word := "#"
      word := word.push c
    else
      match word with
      | "define" | "undefine" | "redefine" => mode := .schema
      | "insert" | "delete" | "update" | "put" => if mode == .read then mode := .write
      | _ => pure ()
      word := ""
      if c == '"' || c == '\'' then inStr := some c
    prev := c
  return mode

def modeSyntax : TxMode → Lean.MacroM Lean.Term
  | .read => `(TypeDB.TxMode.read)
  | .write => `(TypeDB.TxMode.write)
  | .schema => `(TypeDB.TxMode.schema)

end TypeQL

/-- TypeQL text with `{e}` holes rendered by `ToTypeQL`. Its transaction mode is inferred from
the literal text; see the module docs. -/
syntax:max "typeql!" interpolatedStr(term) : term

-- @tg: implements:: [[openspec:query#Typed interpolation]]
-- @tg: implements:: [[openspec:query#Explicit raw splicing]]
macro_rules
  | `(typeql! $s:interpolatedStr) => do
    let literal := s.raw.getArgs.foldl (init := "") fun acc chunk =>
      match chunk.isInterpolatedStrLit? with
      | some str => acc ++ str ++ " "
      | none => acc ++ " 0 "
    let mode ← TypeQL.modeSyntax (TypeQL.inferMode literal)
    let text ← s.expandInterpolatedStr (← `(String)) (← `(TypeDB.ToTypeQL.render))
      (← `(id))
    `((⟨$text⟩ : TypeDB.Query $mode))

end TypeDB
