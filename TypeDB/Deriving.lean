import Lean
import TypeDB.ORM

/-!
# Deriving handlers

* `deriving FromRow` decodes a row into a structure, reading each field from the query variable
  of the same name (`Option` fields are optional columns).
* `deriving Entity` / `deriving Relation` map a structure to a TypeDB type (`TypeDB.ORM.Mapped`),
  and add `Keyed` when a field is a `Key`, and `S.field.<name>` handles for its attribute fields.
* `deriving Polymorphic` decodes a sum of mapped types by each instance's concrete type.

The generated code types every field through its projection (`fun (x : S) => x.f`), so it never
spells out a field's type.
-/

namespace TypeDB.Deriving

open Lean Elab Command Meta Term

/-- What a field's declared type says through the `Key`, `Role` and `Attr` markers. -/
structure Markers where
  key : Bool := false
  role : Option String := none
  label : Option String := none
  deriving Inhabited

private def stringLit? (e : Expr) : Option String :=
  match e with
  | .lit (.strVal s) => some s
  | _ => none

partial def markers (t : Expr) : Markers :=
  match t.getAppFn.constName?, t.getAppArgs with
  | some ``TypeDB.Key, #[a] => { markers a with key := true }
  | some ``TypeDB.Role, #[n, a] => { markers a with role := stringLit? n }
  | some ``TypeDB.Attr, #[n, a] => { markers a with label := stringLit? n }
  | _, _ => {}

/-- A flattened field of a structure. -/
structure FieldInfo where
  name : Name
  markers : Markers
  /-- Declared in a parent structure that is itself mapped. -/
  inherited : Bool
  deriving Inhabited

private def projTerm (s : Name) (f : Name) : TermElabM Term :=
  `(fun ($(mkIdent `x) : $(mkIdent s)) => $(mkIdent (`x ++ f)))

private def isMapped (s : Name) : TermElabM Bool := do
  let inst ← mkAppM ``TypeDB.ORM.Mapped #[mkConst s]
  return (← synthInstance? inst).isSome

def fieldInfos (s : Name) : TermElabM (Array FieldInfo) := do
  let env ← getEnv
  let fields := getStructureFieldsFlattened env s (includeSubobjectFields := false)
  fields.mapM fun f => do
    let some decl := findField? env s f | throwError "field {f} of {s} not found"
    let ci ← getConstInfo (decl ++ f)
    let ty ← forallTelescope ci.type fun _ t => pure t
    let inherited := decl != s && (← isMapped decl)
    return { name := f, markers := markers ty, inherited }

private def labelOf (s : Name) : CoreM String := do
  match ORM.typedbLabelAttr.getParam? (← getEnv) s with
  | some l => pure l
  | none => pure (Str.kebab s.getString!)

/-! ## FromRow -/

def mkFromRow (s : Name) : TermElabM Command := do
  let env ← getEnv
  let fields := getStructureFieldsFlattened env s (includeSubobjectFields := false)
  let sId := mkIdent s
  if fields.isEmpty then
    return ← `(command| instance : TypeDB.FromRow $sId := ⟨pure ({} : $sId)⟩)
  let vars := fields.mapIdx fun i _ => mkIdent (Name.mkSimple s!"a{i}")
  let fieldIds := fields.map mkIdent
  let ctor ← `(fun $vars* => ({ $[$fieldIds:ident := $vars:ident],* } : $sId))
  let mut body ← `($ctor <$> TypeDB.ORM.columnOf $(← projTerm s fields[0]!) $(quote fields[0]!.toString))
  for f in fields[1:] do
    body ← `($body <*> TypeDB.ORM.columnOf $(← projTerm s f) $(quote f.toString))
  `(command| instance : TypeDB.FromRow $sId := ⟨$body⟩)

def fromRowHandler (names : Array Name) : CommandElabM Bool := do
  unless names.size == 1 && isStructure (← getEnv) names[0]! do return false
  elabCommand (← liftTermElabM (mkFromRow names[0]!))
  return true

/-! ## Entity and Relation -/

-- @tg: implements:: [[openspec:orm#Subtyping]]
def mkMapped (s : Name) (kind : ORM.Kind) : TermElabM (Array Command) := do
  let env ← getEnv
  let sId := mkIdent s
  let infos ← fieldInfos s
  let label ← labelOf s
  let hasRole := infos.any (·.markers.role.isSome)
  if kind == .entity && hasRole then
    throwError "{s}: `Role` fields are only allowed in a relation; derive `Relation` instead"
  if kind == .relation && !hasRole then
    throwError "{s}: a relation needs at least one `Role` field"
  let parents ← (getStructureParentInfo env s).filterMapM fun p => do
    if ← isMapped p.structName then pure (some p.structName) else pure none
  let parent ← match parents[0]? with
    | some p => `(some (TypeDB.ORM.Mapped.label $(mkIdent p)))
    | none => `(none)
  let kindStx ← match kind with
    | .entity => `(TypeDB.ORM.Kind.entity)
    | .relation => `(TypeDB.ORM.Kind.relation)
  let mut specs := #[]
  let mut encs := #[]
  for fi in infos do
    let fname := fi.name.toString
    let name := fi.markers.role.getD (fi.markers.label.getD (Str.kebab fname))
    let proj ← projTerm s fi.name
    specs := specs.push (← `(TypeDB.ORM.FieldSpec.mk $(quote fname) $(quote name)
      (TypeDB.ORM.shapeOf $proj) $(quote fi.markers.key) $(quote !fi.inherited)))
    encs := encs.push (← `(TypeDB.ORM.encodeField $(mkIdent (`x ++ fi.name))))
  let vars := infos.mapIdx fun i _ => mkIdent (Name.mkSimple s!"v{i}")
  let fieldIds := infos.map (mkIdent ·.name)
  let mut decodeBody ← `(pure ({ $[$fieldIds:ident := $vars:ident],* } : $sId))
  for i in (List.range infos.size).reverse do
    let fi := infos[i]!
    decodeBody ← `(TypeDB.ORM.decodeField $(← projTerm s fi.name) $(quote fi.name.toString) $(mkIdent `d) $(quote i)
      >>= fun $(vars[i]!) => $decodeBody)
  let marker := mkIdent (match kind with | .entity => ``TypeDB.Entity | .relation => ``TypeDB.Relation)
  let mut cmds := #[
    ← `(command| instance : TypeDB.ORM.Mapped $sId where
          label := $(quote label)
          kind := $kindStx
          parent := $parent
          fields := #[$specs,*]
          encode := fun $(mkIdent `x) => #[$encs,*]
          decode := fun $(mkIdent `d) => $decodeBody),
    ← `(command| instance : $marker $sId := ⟨⟨inferInstance⟩⟩)]
  if let some k := infos.find? (·.markers.key) then
    cmds := cmds.push (← `(command| instance : TypeDB.ORM.Keyed $sId (TypeDB.ORM.TypeOf $(← projTerm s k.name)) :=
      ⟨$(quote (k.markers.label.getD (Str.kebab k.name.toString)))⟩))
  for fi in infos do
    if fi.markers.role.isSome then continue
    let proj ← projTerm s fi.name
    let attr := fi.markers.label.getD (Str.kebab fi.name.toString)
    let fieldName := mkIdent (`_root_ ++ s ++ `field ++ fi.name)
    cmds := cmds.push (← `(command|
      /-- The attribute field handle for `Entity.update`. -/
      def $fieldName : TypeDB.ORM.Field $sId (TypeDB.ORM.TypeOf $proj) :=
        ⟨$(quote attr), TypeDB.ORM.cardOf $proj⟩))
  return cmds

def mappedHandler (kind : ORM.Kind) (names : Array Name) : CommandElabM Bool := do
  unless names.size == 1 && isStructure (← getEnv) names[0]! do return false
  for cmd in ← liftTermElabM (mkMapped names[0]! kind) do elabCommand cmd
  return true

/-! ## Polymorphic -/

def mkPolymorphic (t : Name) : TermElabM Command := do
  let env ← getEnv
  let some (.inductInfo ind) := env.find? t | throwError "{t} is not an inductive type"
  let tId := mkIdent t
  let mut variants := #[]
  let mut first : Option Term := none
  for c in ind.ctors do
    let ci ← getConstInfo c
    let argTy ← forallTelescope ci.type fun xs _ => do
      unless xs.size == 1 do throwError "constructor {c} must take exactly one mapped value"
      inferType xs[0]!
    let ty ← PrettyPrinter.delab argTy
    if first.isNone then first := some ty
    variants := variants.push (← `((TypeDB.ORM.Mapped.label $ty, TypeDB.ORM.Mapped.fields $ty,
      fun $(mkIdent `d) => $(mkIdent c) <$> TypeDB.ORM.Mapped.decode (α := $ty) $(mkIdent `d))))
  let some root := first | throwError "{t} has no constructors"
  `(command| instance : TypeDB.Polymorphic $tId where
      root := TypeDB.ORM.Mapped.label $root
      isRelation := TypeDB.ORM.Mapped.kind $root == .relation
      variants := #[$variants,*])

def polymorphicHandler (names : Array Name) : CommandElabM Bool := do
  unless names.size == 1 do return false
  elabCommand (← liftTermElabM (mkPolymorphic names[0]!))
  return true

-- @tg: implements:: [[openspec:decoding#Derived row decoders]]
initialize registerDerivingHandler ``TypeDB.FromRow fromRowHandler
-- @tg: implements:: [[openspec:orm#Entity mapping]]
initialize registerDerivingHandler ``TypeDB.Entity (mappedHandler .entity)
-- @tg: implements:: [[openspec:orm#Relation mapping]]
initialize registerDerivingHandler ``TypeDB.Relation (mappedHandler .relation)
initialize registerDerivingHandler ``TypeDB.Polymorphic polymorphicHandler

end TypeDB.Deriving
