import TypeDB.Query
import TypeDB.ORM.Attr

/-!
# A lightweight ORM

`deriving Entity` and `deriving Relation` map a Lean structure to a TypeDB entity or relation
type (`TypeDB.ORM.Deriving`). The mapping is Lean-first: the structure is the source of truth,
`Schema.define` generates the TypeQL `define` for it, and `verifySchema` checks a live database
against it.

Fields map by their type:

* `τ` with a TypeDB value type: an owned attribute, required (`@card(1..1)`);
* `Option τ`: an optional attribute; `Array τ`: a multi-valued attribute (`@card(0..)`);
* `Key τ`: the type's key (`@key`);
* `Role "r" (Ref β)` or `Role "r" (Array (Ref β))`: in a relation, the instances playing role `r`;
* `Attr "l" τ`: overrides the attribute label, which is otherwise the field name in kebab-case.

A structure that `extends` a mapped structure maps to a subtype (`sub`) and inherits its
attributes, roles and key. `@[typedb "label"]` on the structure sets the type label.

Instances are referenced by `Ref α`: by key value (`Ref.key`) or by IID (`Ref.iid`). `insert`
returns an IID reference.
-/

namespace TypeDB

/-- Marks the field holding the type's key attribute. Transparent: a `Key String` is a `String`. -/
abbrev Key (α : Type) := α
/-- Marks a relation field holding the player(s) of role `name`. -/
abbrev Role (_name : String) (α : Type) := α
/-- Sets the TypeDB attribute label of a field. -/
abbrev Attr (_label : String) (α : Type) := α

namespace ORM

/-- How a reference finds its instance. -/
inductive Target where
  /-- `$x isa typeLabel, has keyAttr literal` -/
  | key (typeLabel : String) (keyAttr : String) (literal : String)
  | iid (iid : IID)
  deriving DecidableEq, Repr, Inhabited, Hashable

end ORM

/-- A reference to an instance of the mapped type `α`. -/
-- @tg: implements:: [[openspec:orm#References by key or IID]]
structure Ref (α : Type) where
  target : ORM.Target
  deriving DecidableEq, Repr, Inhabited, Hashable

instance {α : Type} : BEq (Ref α) := ⟨fun a b => a.target == b.target⟩

namespace ORM

inductive Kind where
  | entity
  | relation
  deriving DecidableEq, Repr, Inhabited

instance : ToString Kind := ⟨fun | .entity => "entity" | .relation => "relation"⟩

inductive Card where
  | one
  | opt
  | many
  deriving DecidableEq, Repr, Inhabited

/-- What a field stores. -/
inductive Shape where
  | attr (valueType : String) (card : Card)
  /-- Players of a role; `player` is the label of the referenced type. -/
  | role (player : String) (many : Bool)
  deriving DecidableEq, Repr, Inhabited

/-- One mapped field. `name` is the attribute label or the role name. -/
structure FieldSpec where
  field : String
  name : String
  shape : Shape
  key : Bool := false
  /-- Declared in this type rather than inherited from its supertype. -/
  own : Bool := true
  deriving DecidableEq, Repr, Inhabited

/-- A field's contribution to an `insert`. -/
inductive FieldEnc where
  | attrs (literals : Array String)
  | players (targets : Array Target)

/-- What a field decodes from: attribute values or role players' IIDs. -/
inductive FieldData where
  | attrs (values : Array Value)
  | players (iids : Array IID)

/-- TypeDB value types of Lean types. -/
class ValueType (α : Type) where
  name : String

instance : ValueType String := ⟨"string"⟩
instance : ValueType Bool := ⟨"boolean"⟩
instance : ValueType Int64 := ⟨"integer"⟩
instance : ValueType Int := ⟨"integer"⟩
instance : ValueType Nat := ⟨"integer"⟩
instance : ValueType Float := ⟨"double"⟩
instance : ValueType Decimal := ⟨"decimal"⟩
instance : ValueType Duration := ⟨"duration"⟩
instance : ValueType Std.Time.PlainDate := ⟨"date"⟩
instance : ValueType Std.Time.PlainDateTime := ⟨"datetime"⟩
instance : ValueType DatetimeTZ := ⟨"datetime-tz"⟩
instance : ValueType Std.Time.DateTime := ⟨"datetime-tz"⟩

/-- How a field type is stored and read back. -/
class FieldCodec (β : Type) where
  shape : Shape
  encode : β → FieldEnc
  decode : FieldData → Except String β

private def decodeValue {γ : Type} [FromConcept γ] (v : Value) : Except String γ :=
  (FromConcept.decode (.value v) : Except String γ).mapError fun got =>
    s!"expected {FromConcept.expected γ}, got {got}"

instance (priority := low) {γ : Type} [ValueType γ] [ToTypeQL γ] [FromConcept γ] : FieldCodec γ where
  shape := .attr (ValueType.name γ) .one
  encode x := .attrs #[render x]
  decode
    | .attrs #[v] => decodeValue v
    | .attrs vs => if vs.isEmpty then .error "required attribute is missing"
      else .error s!"expected one value, found {vs.size}"
    | .players _ => .error "expected an attribute"

instance {γ : Type} [ValueType γ] [ToTypeQL γ] [FromConcept γ] : FieldCodec (Option γ) where
  shape := .attr (ValueType.name γ) .opt
  encode | some x => .attrs #[render x] | none => .attrs #[]
  decode
    | .attrs #[] => .ok none
    | .attrs #[v] => some <$> decodeValue v
    | .attrs vs => .error s!"expected at most one value, found {vs.size}"
    | .players _ => .error "expected an attribute"

-- @tg: implements:: [[openspec:orm#Multi-valued attributes]]
instance {γ : Type} [ValueType γ] [ToTypeQL γ] [FromConcept γ] : FieldCodec (Array γ) where
  shape := .attr (ValueType.name γ) .many
  encode xs := .attrs (xs.map render)
  decode
    | .attrs vs => vs.mapM decodeValue
    | .players _ => .error "expected an attribute"

/-- A Lean type mapped to a TypeDB entity or relation type. Derive it with `deriving Entity` or
`deriving Relation`. `fields`, `encode` and `decode` cover every field, inherited ones included,
in the same order. -/
class Mapped (α : Type) where
  label : String
  kind : Kind
  parent : Option String
  fields : Array FieldSpec
  encode : α → Array FieldEnc
  decode : Array FieldData → Except String α

/-- Mapped types with a key attribute of type `K`. -/
class Keyed (α : Type) (K : outParam Type) where
  keyAttr : String

-- @tg: implements:: [[openspec:orm#Relations as role players]]
instance {γ : Type} [Mapped γ] : FieldCodec (Ref γ) where
  shape := .role (Mapped.label γ) false
  encode r := .players #[r.target]
  decode
    | .players #[i] => .ok ⟨.iid i⟩
    | .players ps => .error s!"expected one role player, found {ps.size}"
    | .attrs _ => .error "expected a role player"

instance {γ : Type} [Mapped γ] : FieldCodec (Array (Ref γ)) where
  shape := .role (Mapped.label γ) true
  encode rs := .players (rs.map (·.target))
  decode
    | .players ps => .ok (ps.map (⟨.iid ·⟩))
    | .attrs _ => .error "expected role players"

/-- A typed handle on one attribute field of `α`, generated as `α.field.<name>`. -/
structure Field (α : Type) (β : Type) where
  attr : String
  card : Card

end ORM

namespace Ref

open ORM

variable {α : Type}

def iid (i : IID) : Ref α := ⟨.iid i⟩

/-- A reference by key value. Only types with a key attribute have one. -/
def key {K : Type} [Mapped α] [Keyed α K] [ToTypeQL K] (k : K) : Ref α :=
  ⟨.key (Mapped.label α) (Keyed.keyAttr α) (render k)⟩

def iid? (r : Ref α) : Option IID := match r.target with
  | .iid i => some i
  | .key .. => none

/-- The same instance seen as a supertype. -/
def up {β : Type} (r : Ref α) : Ref β := ⟨r.target⟩

end Ref

namespace ORM

variable {α : Type} {m : TxMode}

/-- A TypeQL pattern binding `var` to the referenced instance of type `label`. -/
def Target.pattern (var : String) (label : String) : Target → String
  | .key tl k lit => s!"${var} isa {if label.isEmpty then tl else label}, has {k} {lit};"
  | .iid i => if label.isEmpty then s!"${var} iid {i};" else s!"${var} iid {i}; ${var} isa {label};"

/-- The `insert` query for a value, with `match` clauses for its role players. -/
def insertText [Mapped α] (x : α) : String := Id.run do
  let fields := Mapped.fields α
  let encs := Mapped.encode x
  let mut matchClauses := #[]
  let mut links := #[]
  let mut has := #[]
  for (spec, enc) in fields.zip encs do
    match enc with
    | .attrs lits => for l in lits do has := has.push s!"has {spec.name} {l}"
    | .players ts =>
      let player := match spec.shape with | .role p _ => p | _ => ""
      for t in ts do
        let v := s!"p{matchClauses.size}"
        matchClauses := matchClauses.push (t.pattern v player)
        links := links.push s!"{spec.name}: ${v}"
  let linksTxt := if links.isEmpty then "" else s!", links ({", ".intercalate links.toList})"
  let hasTxt := String.join (has.toList.map (", " ++ ·))
  let matchTxt := if matchClauses.isEmpty then "" else "match " ++ " ".intercalate matchClauses.toList ++ "\n"
  return s!"{matchTxt}insert $x isa {Mapped.label α}{linksTxt}{hasTxt};"

/-- Groups rows of (instance, concept) by the instance's IID, keeping first-seen order. -/
private def groupBy (rows : Array (Concept × Option Concept)) :
    Array (IID × String × Array Concept) := Id.run do
  let mut order : Array IID := #[]
  let mut map : Std.HashMap IID (String × Array Concept) := {}
  for (x, c) in rows do
    let some i := x.iid? | continue
    let label := x.label?.getD ""
    let entry := match map[i]? with
      | some e => e
      | none => (label, #[])
    if !map.contains i then order := order.push i
    map := map.insert i (entry.1, match c with | some c => entry.2.push c | none => entry.2)
  return order.map fun i => let (l, cs) := map.getD i ("", #[]); (i, l, cs)

/-- The field data of one instance from its attributes and role players. Fields that share a role
take its players in order: a single field one player, an array field the rest. -/
def assemble (fields : Array FieldSpec) (attrs : Array Concept) (players : Array (String × IID)) :
    Array FieldData := Id.run do
  let mut taken : Std.HashMap String Nat := {}
  let mut out := #[]
  for f in fields do
    match f.shape with
    | .attr .. =>
      out := out.push (.attrs (attrs.filterMap fun c => match c with
        | .attribute l v => if l == f.name then some v else none
        | _ => none))
    | .role _ many =>
      let ofRole := players.filterMap fun (r, i) => if r == f.name then some i else none
      let start := taken.getD f.name 0
      let mine := if many then ofRole.extract start ofRole.size else ofRole.extract start (start + 1)
      taken := taken.insert f.name (start + mine.size)
      out := out.push (.players mine)
  return out

/-- The attributes and role players of every instance matched by `pattern` (which binds `$x`):
two queries, whatever the number of instances. -/
def fetchRaw [TxMode.Allows m .read] (pattern : String) (isRelation : Bool) :
    Tx m (Array (IID × String × Array Concept × Array (String × IID))) := do
  let dx : RowDecoder (Concept × Option Concept) := Prod.mk <$> col "x" <*> colOpt "a"
  let rows ← queryWith dx (Query.raw .read s!"match {pattern} try \{ $x has $a; };")
  let groups := groupBy rows
  let players ← if isRelation then do
      let dp : RowDecoder (Concept × Label × IID) := (·, ·, ·) <$> col "x" <*> col "role" <*> col "p"
      let ps ← queryWith dp (Query.raw .read s!"match {pattern} $x links ($role: $p);")
      pure <| ps.foldl (init := ({} : Std.HashMap IID (Array (String × IID)))) fun acc (x, role, p) =>
        match x.iid? with
        | some i =>
          let roleName := (role.name.splitOn ":").getLast!
          acc.insert i ((acc.getD i #[]).push (roleName, p))
        | none => acc
    else pure {}
  return groups.map fun (i, label, attrs) => (i, label, attrs, players.getD i #[])

/-- Decodes the instances matched by `pattern` with the given fields. -/
def fetchInstances [TxMode.Allows m .read] (pattern : String) (fields : Array FieldSpec)
    (isRelation : Bool) : Tx m (Array (IID × String × Array FieldData)) := do
  return (← fetchRaw pattern isRelation).map fun (i, l, attrs, ps) => (i, l, assemble fields attrs ps)

private def decodeOrFail (label : String) (i : IID) (r : Except String α) : Tx m α :=
  match r with
  | .ok a => pure a
  | .error e => Tx.fail (.decode label s!"a mapped {label}" s!"{e} (instance {i})")

end ORM

namespace ORM

/-! Helpers the deriving handlers call: each is typed by a field's projection, so generated code
never spells out field types. -/

abbrev TypeOf {σ β : Type} (_ : σ → β) : Type := β

def shapeOf {σ β : Type} [FieldCodec β] (_ : σ → β) : Shape := FieldCodec.shape β

def cardOf {σ β : Type} [FieldCodec β] (_ : σ → β) : Card :=
  match FieldCodec.shape β with
  | .attr _ c => c
  | .role _ many => if many then .many else .one

def encodeField {β : Type} [FieldCodec β] (x : β) : FieldEnc := FieldCodec.encode x

def decodeField {σ β : Type} [FieldCodec β] (_ : σ → β) (name : String) (d : Array FieldData)
    (i : Nat) : Except String β :=
  (FieldCodec.decode (d.getD i (.attrs #[])) : Except String β).mapError (s!"field '{name}': " ++ ·)

def columnOf {σ β : Type} [FromColumn β] (_ : σ → β) (name : String) : RowDecoder β :=
  FromColumn.column name

end ORM

/-- Marks a structure derived as a TypeDB entity type (`deriving Entity`). -/
class Entity (α : Type) : Prop where
  mapped : Nonempty (ORM.Mapped α)

/-- Marks a structure derived as a TypeDB relation type (`deriving Relation`). -/
class Relation (α : Type) : Prop where
  mapped : Nonempty (ORM.Mapped α)

/-! ## Operations on mapped types -/

namespace Entity

open ORM

variable {α β : Type} {m : TxMode}

/-- Inserts the value and returns an IID reference to it. Fails if a referenced role player does
not exist, in which case nothing is inserted. -/
def insert [Mapped α] [TxMode.Allows m .write] (x : α) : Tx m (Ref α) := do
  let iids ← query (α := Col "x" IID) (Query.raw .write (insertText x))
  match iids[0]? with
  | some i => pure ⟨.iid i.val⟩
  | none => Tx.fail (.server "TDBLEAN4" s!"insert of {Mapped.label α} matched no role players")

/-- The instance a reference points to, or `none`. -/
def get? [Mapped α] [TxMode.Allows m .read] (r : Ref α) : Tx m (Option α) := do
  let fields := Mapped.fields α
  let found ← fetchInstances (r.target.pattern "x" (Mapped.label α)) fields
    (Mapped.kind α == .relation)
  match found[0]? with
  | none => pure none
  | some (i, _, data) => some <$> decodeOrFail (Mapped.label α) i (Mapped.decode data)

/-- Every instance of the type (and its subtypes), with an IID reference to each. -/
def all [Mapped α] [TxMode.Allows m .read] : Tx m (Array (Ref α × α)) := do
  let found ← fetchInstances s!"$x isa {Mapped.label α};" (Mapped.fields α) (Mapped.kind α == .relation)
  found.mapM fun (i, _, data) => return (⟨.iid i⟩, ← decodeOrFail (Mapped.label α) i (Mapped.decode data))

/-- Replaces the value(s) of one attribute. -/
def update [Mapped α] [TxMode.Allows m .write] [FieldCodec β] (r : Ref α) (f : Field α β) (v : β) :
    Tx m Unit := do
  let pat := r.target.pattern "x" (Mapped.label α)
  let lits := match FieldCodec.encode v with | .attrs ls => ls | .players _ => #[]
  match f.card, lits[0]? with
  | .one, some l => exec (Query.raw .write s!"match {pat} update $x has {f.attr} {l};")
  | .opt, some l => exec (Query.raw .write s!"match {pat} update $x has {f.attr} {l};")
  | _, _ =>
    exec (Query.raw .write s!"match {pat} $x has {f.attr} $old; delete has $old of $x;")
    unless lits.isEmpty do
      let has := ", ".intercalate (lits.toList.map (s!"has {f.attr} " ++ ·))
      exec (Query.raw .write s!"match {pat} insert $x {has};")

/-- Deletes the instance. -/
def delete [Mapped α] [TxMode.Allows m .write] (r : Ref α) : Tx m Unit :=
  exec (Query.raw .write s!"match {r.target.pattern "x" (Mapped.label α)} delete $x;")

/-- How many instances of the type (and its subtypes) exist. -/
def count [Mapped α] [TxMode.Allows m .read] : Tx m Nat := do
  let n ← queryOne (α := Col "n" Int64) (Query.raw .read s!"match $x isa {Mapped.label α}; reduce $n = count;")
  return n.val.toInt.toNat

end Entity

-- @tg: implements:: [[openspec:orm#Update and delete]]
namespace Relation
export Entity (insert get? all update delete count)
end Relation

/-! ## Polymorphic decoding -/

/-- A sum type whose constructors wrap mapped types, decoded by each instance's concrete type.
Derive it with `deriving Polymorphic`; the first constructor's type is the root that is
queried. -/
class Polymorphic (α : Type) where
  root : String
  isRelation : Bool
  /-- Fields and decoder for the constructor of concrete type `label`. -/
  variants : Array (String × Array ORM.FieldSpec × (Array ORM.FieldData → Except String α))

namespace Polymorphic

open ORM

/-- Every instance of the root type, each decoded into the constructor of its concrete type.
Instances of an unmapped subtype decode as the closest constructor listed first. -/
-- @tg: implements:: [[openspec:orm#Polymorphic decoding]]
def all {α : Type} {m : TxMode} [Polymorphic α] [TxMode.Allows m .read] : Tx m (Array (IID × α)) := do
  let variants := Polymorphic.variants (α := α)
  let found ← fetchRaw s!"$x isa {Polymorphic.root α};" (Polymorphic.isRelation α)
  found.mapM fun (i, label, attrs, ps) => do
    let some (_, fields, dec) := variants.find? (·.1 == label) <|> variants[0]?
      | Tx.fail (.internal "polymorphic type without variants")
    match dec (assemble fields attrs ps) with
    | .ok a => pure (i, a)
    | .error e => Tx.fail (.decode label s!"a mapped {label}" e)

end Polymorphic

end TypeDB
