import TypeDB.Native

namespace TypeDB

/-- One difference between a Lean mapping and the live schema, found by `verifySchema`. -/
inductive SchemaIssue where
  | missingType (label : String)
  | wrongKind (label : String) (expected : String) (actual : String)
  | wrongSupertype (label : String) (expected : String) (actual : Option String)
  | missingOwns (owner : String) (attr : String)
  | wrongValueType (attr : String) (expected : String) (actual : String)
  | missingRelates (relation : String) (role : String)
  | missingPlays (player : String) (role : String)
  deriving Repr, BEq, Inhabited

instance : ToString SchemaIssue where
  toString
    | .missingType l => s!"type '{l}' does not exist"
    | .wrongKind l e a => s!"type '{l}' is a {a}, expected a {e}"
    | .wrongSupertype l e a => s!"type '{l}' has supertype {a.getD "none"}, expected '{e}'"
    | .missingOwns o a => s!"type '{o}' does not own '{a}'"
    | .wrongValueType a e v => s!"attribute '{a}' has value type {v}, expected {e}"
    | .missingRelates r ro => s!"relation '{r}' does not relate '{ro}'"
    | .missingPlays p ro => s!"type '{p}' does not play '{ro}'"

/-- Everything that can go wrong talking to TypeDB. -/
-- @tg: implements:: [[openspec:transactions#Typed errors]]
inductive TypeDBError where
  /-- The server could not be reached, or refused the connection or credentials. -/
  | connection (code : String) (message : String)
  /-- The server rejected a request; `code` is TypeDB's error code, e.g. `TQL03`. -/
  | server (code : String) (message : String)
  /-- A commit lost against a concurrent transaction; retrying may succeed. -/
  | conflict (message : String)
  /-- A column or document did not have the shape the decoder expects. -/
  | decode (column : String) (expected : String) (got : String)
  /-- The live schema differs from the Lean mappings. -/
  | schemaMismatch (issues : List SchemaIssue)
  /-- A migration could not run; `version` names the step. -/
  | migration (version : Nat) (message : String)
  /-- An `IO` error raised inside a transaction body. -/
  | io (message : String)
  /-- A misuse of the library or a driver failure with no TypeDB code. -/
  | internal (message : String)
  deriving Repr, Inhabited

namespace TypeDBError

def isConflict : TypeDBError → Bool
  | .conflict _ => true
  | _ => false

/-- The message of a server error, without the `[CODE]` prefix the driver puts before it. -/
private def stripCode (msg : String) : String :=
  let msg := Str.trim msg
  if msg.startsWith "[" then
    match msg.splitOn "] " with
    | _ :: rest@(_ :: _) => "] ".intercalate rest
    | _ => msg
  else msg

/-- Classifies a driver error. Commit conflicts are storage errors `STC2` ("isolation conflict"),
which the server may wrap in another error, so the whole message is searched. -/
def ofNative (e : Native.NativeError) : TypeDBError :=
  let e := { e with code := String.ofList (e.code.toList.filter (fun c => c != '[' && c != ']')) }
  if e.code == "TDBLEAN2" then .decode e.message "column in the answer" "no such column"
  else if e.code.startsWith "TDBLEAN" then .internal e.message
  else if e.code.startsWith "CXN" then .connection e.code (stripCode e.message)
  else if (e.message.splitOn "isolation conflict").length > 1 || (e.message.splitOn "[STC2]").length > 1 then
    .conflict (stripCode e.message)
  else .server e.code (stripCode e.message)

protected def toString : TypeDBError → String
  | .connection c m => s!"connection error [{c}]: {m}"
  | .server c m => s!"server error [{c}]: {m}"
  | .conflict m => s!"commit conflict: {m}"
  | .decode col e g => s!"cannot decode column '{col}': expected {e}, got {g}"
  | .schemaMismatch is => "schema mismatch:\n" ++ "\n".intercalate (is.map (s!"  - {·}"))
  | .migration v m => s!"migration {v}: {m}"
  | .io m => s!"IO error: {m}"
  | .internal m => s!"internal error: {m}"

instance : ToString TypeDBError := ⟨TypeDBError.toString⟩

end TypeDBError

/-- Maps the error of an `EIO` action. -/
@[inline] def mapError {ε ε' α : Type} (f : ε → ε') (x : EIO ε α) : EIO ε' α := do
  match ← (x.toBaseIO : BaseIO (Except ε α)) with
  | .ok a => pure a
  | .error e => throw (f e)

/-- `IO` actions run inside TypeDB code report their errors as `TypeDBError.io`. -/
instance : MonadLift IO (EIO TypeDBError) where
  monadLift x := IO.toEIO (fun e => .io (toString e)) x

/-- Runs a native call, classifying its error. -/
@[inline] def native {α : Type} (x : Native.NIO α) : EIO TypeDBError α :=
  mapError TypeDBError.ofNative x

end TypeDB
