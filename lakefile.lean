import Lake

open System Lake DSL

/-- The one place the TypeDB version is pinned: the driver source tag, the vendored
`ffi/typedb_driver.h` (regenerate it with `scripts/update-driver-header.sh` after a bump), the
`typedb/typedb` image the integration tests start, and the Rust benchmark's driver. -/
def typedbVersion : String := (include_str "TYPEDB_VERSION").trimAscii.toString

/-- Native libraries the Rust static library needs (`cargo rustc -- --print native-static-libs`).
On macOS the frameworks are linked through the TAPI stubs in `ffi/macos`, because Lean's bundled
linker cannot read recent SDKs' stubs; `scripts/gen-macos-stubs.sh` regenerates them. -/
-- @tg: implements:: [[openspec:native-driver#Supported platforms]]
def driverLinkArgs : Array String :=
  let stubsDisabled : Bool := run_io do return (← IO.getEnv "TYPEDB_STUBS_DISABLED").isSome
  if Platform.isOSX && stubsDisabled then #[]
  else if Platform.isOSX then
    #[(__dir__ / "ffi" / "macos" / "CoreFoundation.tbd").toString,
      (__dir__ / "ffi" / "macos" / "Security.tbd").toString]
  else
    #["-lpthread", "-ldl", "-lm"]

package «typedb-lean» where
  version := v!"0.1.0"
  description := "TypeDB 3 client for Lean 4: a mode-indexed transaction monad, typed TypeQL interpolation, batched row decoding, a lightweight ORM and migrations, over the official C driver."
  keywords := #["typedb", "database", "graph", "orm", "ffi"]
  license := "Apache-2.0"
  licenseFiles := #["LICENSE"]
  readmeFile := "README.md"
  testDriver := "tests"
  leanOptions := #[⟨`autoImplicit, false⟩]
  moreLinkArgs := driverLinkArgs

/-- Clones `typedb-driver` at the pinned tag and builds its C crate with cargo, or uses the
prebuilt static library named by `TYPEDB_DRIVER_LIB`. -/
-- @tg: implements:: [[openspec:native-driver#Pinned driver build]]
-- @tg: implements:: [[openspec:native-driver#Prebuilt library override]]
extern_lib typedb_driver_clib pkg := do
  if let some path ← IO.getEnv "TYPEDB_DRIVER_LIB" then
    let lib : FilePath := path
    unless ← lib.pathExists do
      error s!"TYPEDB_DRIVER_LIB is set to '{path}', but that file does not exist"
    return ← inputBinFile lib
  let srcDir := pkg.buildDir / "typedb-driver" / typedbVersion
  let lib := srcDir / "target" / "release" / "libtypedb_driver_clib.a"
  Job.async do
    unless ← (srcDir / "Cargo.toml").pathExists do
      IO.FS.createDirAll srcDir.parent.get!
      let cloneArgs := #["clone", "--quiet", "--depth", "1", "--branch", typedbVersion,
        "https://github.com/typedb/typedb-driver.git", srcDir.toString]
      proc { cmd := "git", args := cloneArgs }
    let cargoArgs := #["build", "--release", "--quiet", "-p", "typedb_driver_clib"]
    proc { cmd := "cargo", args := cargoArgs, cwd := srcDir, env := #[("RUSTFLAGS", "-Awarnings")] }
    setTrace (← computeTrace lib)
    return lib

target typedb_lean.o pkg : FilePath := do
  let oFile := pkg.buildDir / "ffi" / "typedb_lean.o"
  let srcJob ← inputTextFile <| pkg.dir / "ffi" / "typedb_lean.c"
  let headerJob ← inputTextFile <| pkg.dir / "ffi" / "typedb_driver.h"
  let weakArgs := #["-I", (← getLeanIncludeDir).toString, "-I", (pkg.dir / "ffi").toString]
  buildO oFile srcJob weakArgs #["-fPIC", "-O3", "-Wall"] "cc" (extraDepTrace := do
    let _ ← headerJob.await
    return headerJob.getTrace)

/-- The C shim between Lean objects and the driver's C types. -/
extern_lib typedb_lean pkg := do
  let o ← fetch <| pkg.target ``typedb_lean.o
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "typedb_lean") #[o]

@[default_target] lean_lib TypeDB where
  precompileModules := false

lean_lib TestSupport where
  srcDir := "tests"
  roots := #[`Harness, `Model, `CompileChecks, `UnitTests, `CoreTests, `QueryTests, `OrmTests]

lean_exe tests where
  srcDir := "tests"
  root := `TestMain

lean_exe social where
  srcDir := "examples/social"
  root := `Social

lean_exe bench where
  srcDir := "bench"
  root := `Bench

/-- Prints the pinned TypeDB version (used by CI and the test harness). -/
script «typedb-version» do
  IO.println typedbVersion
  return 0
