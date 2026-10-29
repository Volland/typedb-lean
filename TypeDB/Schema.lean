import TypeDB.ORM

/-!
# Schema generation and verification

`Schema.defineText` turns the mapped types into one TypeQL `define`: attribute types with their
value types, entity and relation types with `sub`, `owns` (with `@key` and `@card`) and
`relates`, and the `plays` of every role player. `Schema.verify` checks a live database against
the same mappings and lists every difference.
-/

namespace TypeDB

open ORM

/-- What the schema needs to know about one mapped type. -/
structure TypeSpec where
  label : String
  kind : Kind
  parent : Option String
  fields : Array FieldSpec
  deriving Repr, Inhabited

/-- The schema description of a mapped type: `TypeSpec.of Person`. -/
def TypeSpec.of (α : Type) [Mapped α] : TypeSpec :=
  ⟨Mapped.label α, Mapped.kind α, Mapped.parent α, Mapped.fields α⟩

namespace Schema

private def ownsText (f : FieldSpec) : Option String :=
  match f.shape with
  | .attr _ card =>
    let ann := if f.key then " @key" else match card with
      | .one => " @card(1..1)"
      | .opt => ""
      | .many => " @card(0..)"
    some s!"owns {f.name}{ann}"
  | .role .. => none

/-- `relates` lines of a relation: a role filled by `n` single fields gets `@card(0..n)`, a role
with an array field `@card(0..)`. -/
private def relatesText (fields : Array FieldSpec) : Array String := Id.run do
  let mut roles : Array (String × Option Nat) := #[]
  for f in fields do
    let .role _ many := f.shape | continue
    match roles.findIdx? (·.1 == f.name) with
    | some i =>
      let (r, n) := roles[i]!
      roles := roles.set! i (r, if many then none else n.map (· + 1))
    | none => roles := roles.push (f.name, if many then none else some 1)
  return roles.map fun (r, n) => match n with
    | some 1 => s!"relates {r}"
    | some n => s!"relates {r} @card(0..{n})"
    | none => s!"relates {r} @card(0..)"

/-- The TypeQL `define` for the mapped types, or an error if two types give the same attribute
different value types. -/
-- @tg: implements:: [[openspec:orm#Schema generation]]
def defineText (specs : List TypeSpec) : Except String String := do
  let mut attrs : Array (String × String) := #[]
  for s in specs do
    for f in s.fields do
      if !f.own then continue
      let .attr vt _ := f.shape | continue
      match attrs.find? (·.1 == f.name) with
      | some (_, vt') =>
        if vt != vt' then throw s!"attribute '{f.name}' has value type {vt'} and {vt}"
      | none => attrs := attrs.push (f.name, vt)
  let mut out := #["define"]
  for (a, vt) in attrs do
    out := out.push s!"  attribute {a}, value {vt};"
  let mut plays : Array String := #[]
  for s in specs do
    let own := s.fields.filter (·.own)
    let mut parts := #[s!"{s.kind} {s.label}"]
    if let some p := s.parent then parts := parts.push s!"sub {p}"
    if s.kind == .relation then parts := parts ++ relatesText own
    parts := parts ++ own.filterMap ownsText
    out := out.push s!"  {", ".intercalate parts.toList};"
    for f in own do
      if let .role player _ := f.shape then
        let line := s!"  {player} plays {s.label}:{f.name};"
        unless plays.contains line do plays := plays.push line
  return "\n".intercalate (out ++ plays).toList ++ "\n"

/-- The `define` query for the mapped types. -/
def define (specs : List TypeSpec) : Except String (Query .schema) :=
  (⟨·⟩) <$> defineText specs

/-- Defines the mapped types in the current schema transaction. Unchanged types are left as they
are, so running it again is harmless. -/
def defineTx {m : TxMode} [TxMode.Allows m .schema] (specs : List TypeSpec) : Tx m Unit := do
  match define specs with
  | .ok q => exec q
  | .error e => Tx.fail (.internal e)

/-- Runs the TypeQL in a file, e.g. a `define` schema. -/
def load {m : TxMode} [TxMode.Allows m .schema] (path : System.FilePath) : Tx m Unit := do
  exec (Query.raw .schema (← IO.FS.readFile path))

private def labels {m : TxMode} [TxMode.Allows m .read] (q : String) (column : String) :
    Tx m (Array String) := do
  return (← queryWith (col (α := Label) column) (Query.raw .read q)).map (·.name)

private def unscoped (role : String) : String := (role.splitOn ":").getLast!

/-- Whether a type label exists. The server rejects a query naming an unknown label (`INF2`)
rather than answering it with no rows. -/
private def labelExists {m : TxMode} [TxMode.Allows m .read] (label : String) : Tx m (Option Concept) := do
  try
    let found ← queryWith (col (α := Concept) "t") (Query.raw .read s!"match $t label {label};")
    return found[0]?
  catch
    | .server "INF2" _ => return none
    | e => throw e

/-- Every difference between the mapped types and the database's schema. -/
-- @tg: implements:: [[openspec:orm#Schema verification]]
def verify {m : TxMode} [TxMode.Allows m .read] (specs : List TypeSpec) : Tx m (List SchemaIssue) := do
  let mut issues : Array SchemaIssue := #[]
  let mut checkedAttrs : Array String := #[]
  for s in specs do
    let some t ← labelExists s.label | issues := issues.push (.missingType s.label); continue
    let actualKind := match t with
      | .entityType _ => "entity" | .relationType _ => "relation"
      | .attributeType _ => "attribute" | _ => "role"
    if actualKind != toString s.kind then
      issues := issues.push (.wrongKind s.label (toString s.kind) actualKind)
      continue
    if let some p := s.parent then
      let sup ← labels s!"match $t label {s.label}; $t sub! $s;" "s"
      unless sup.contains p do issues := issues.push (.wrongSupertype s.label p sup[0]?)
    let owned ← labels s!"match $t label {s.label}; $t owns $a;" "a"
    let related ← if s.kind == .relation then
      labels s!"match $t label {s.label}; $t relates $r;" "r" else pure #[]
    for f in s.fields do
      match f.shape with
      | .attr vt _ =>
        unless owned.contains f.name do issues := issues.push (.missingOwns s.label f.name)
        if owned.contains f.name && !checkedAttrs.contains f.name then
          checkedAttrs := checkedAttrs.push f.name
          let ok ← labels s!"match $a label {f.name}; $a value {vt};" "a"
          if ok.isEmpty then issues := issues.push (.wrongValueType f.name vt "another value type")
      | .role player _ =>
        unless related.any (unscoped · == f.name) do issues := issues.push (.missingRelates s.label f.name)
        let plays ← if (← labelExists player).isSome then
          labels s!"match $t label {player}; $t plays $r;" "r" else pure #[]
        unless plays.contains s!"{s.label}:{f.name}" do
          issues := issues.push (.missingPlays player s!"{s.label}:{f.name}")
  return issues.toList

/-- Fails with `TypeDBError.schemaMismatch` unless the database matches the mapped types. -/
def verify! {m : TxMode} [TxMode.Allows m .read] (specs : List TypeSpec) : Tx m Unit := do
  let issues ← verify specs
  unless issues.isEmpty do Tx.fail (.schemaMismatch issues)

end Schema

end TypeDB
