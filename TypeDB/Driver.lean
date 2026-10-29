import TypeDB.Error

/-!
# Connecting and managing databases

`Driver.connect` opens one connection, which every transaction shares. The driver multiplexes
concurrent transactions over it, so there is no pool.
-/

namespace TypeDB

/-- TLS settings for a connection. -/
inductive Tls where
  | disabled
  /-- TLS with the operating system's root certificates. -/
  | system
  /-- TLS with a custom root CA certificate (PEM file). -/
  | rootCA (path : System.FilePath)
  deriving Repr, Inhabited

/-- How to reach and authenticate with a server. -/
structure Config where
  address : String := "127.0.0.1:1729"
  username : String := "admin"
  password : String := "password"
  tls : Tls := .disabled
  /-- Request timeout in milliseconds; 0 keeps the driver's default. -/
  requestTimeoutMs : Nat := 0
  deriving Repr, Inhabited

/-- Options applied to every transaction a `run` opens. -/
-- @tg: implements:: [[openspec:connection#Driver options]]
structure TxOptions where
  /-- Transaction timeout in milliseconds; 0 keeps the server's default. -/
  timeoutMs : Nat := 0
  /-- How many answers the server sends ahead of the client's reads; 0 keeps the server's
  default, which is small enough to make large scans wait on the network. -/
  prefetch : Nat := 512
  /-- How many rows one native call decodes. -/
  batchSize : Nat := 256
  deriving Repr, Inhabited

/-- An open connection to a TypeDB server. Safe to share between threads. -/
-- @tg: implements:: [[openspec:connection#Driver is shareable]]
structure Driver where
  handle : Native.DriverHandle
  config : Config

namespace Driver

/-- Connects to a server. Fails with `TypeDBError.connection` if the server is unreachable or
refuses the credentials. -/
-- @tg: implements:: [[openspec:connection#Connect with credentials]]
-- @tg: implements:: [[openspec:connection#Optional TLS]]
def connect (config : Config := {}) : EIO TypeDBError Driver := do
  let (tls, ca) ← match config.tls with
    | .disabled => pure (false, "")
    | .system => pure (true, "")
    | .rootCA path => do
      unless ← (path.pathExists : IO Bool) do
        throw (.connection "TDBLEAN3" s!"root CA certificate '{path}' does not exist")
      pure (true, path.toString)
  let h ← native <| Native.driverOpen config.address config.username config.password tls ca
    (Int64.ofNat config.requestTimeoutMs)
  return { handle := h, config }

/-- Closes the connection. Later calls on this driver fail. -/
def close (d : Driver) : EIO TypeDBError Unit := native (Native.driverClose d.handle)

def isOpen (d : Driver) : EIO TypeDBError Bool := native (Native.driverIsOpen d.handle)

/-- Connects, runs `f`, and closes the connection whatever `f` does. -/
def withDriver {α : Type} (config : Config) (f : Driver → EIO TypeDBError α) : EIO TypeDBError α := do
  let d ← connect config
  try f d finally discard <| (d.close.toBaseIO : BaseIO _)

/-! ## Databases -/

-- @tg: implements:: [[openspec:connection#Database management]]
/-- Creates a database; fails if one with that name exists. -/
def createDatabase (d : Driver) (name : String) : EIO TypeDBError Unit := do
  if ← native (Native.dbContains d.handle name) then
    throw (.server "TDBLEAN5" s!"database '{name}' already exists")
  native (Native.dbCreate d.handle name)
def databaseExists (d : Driver) (name : String) : EIO TypeDBError Bool := native (Native.dbContains d.handle name)
def deleteDatabase (d : Driver) (name : String) : EIO TypeDBError Unit := native (Native.dbDelete d.handle name)
def databases (d : Driver) : EIO TypeDBError (Array String) := native (Native.dbAll d.handle)
/-- The database's schema and functions as TypeQL `define` text. -/
def schema (d : Driver) (name : String) : EIO TypeDBError String := native (Native.dbSchema d.handle name 0)
/-- The database's types only, without functions. -/
def typeSchema (d : Driver) (name : String) : EIO TypeDBError String := native (Native.dbSchema d.handle name 1)

/-- Creates the database unless it exists. -/
def ensureDatabase (d : Driver) (name : String) : EIO TypeDBError Unit := do
  unless ← d.databaseExists name do d.createDatabase name

end Driver

end TypeDB
