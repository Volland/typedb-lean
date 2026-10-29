import Harness
import CompileChecks
import UnitTests
import CoreTests
import QueryTests
import OrmTests

def main (args : List String) : IO UInt32 :=
  Harness.main args UnitTests.all (CoreTests.all ++ QueryTests.all ++ OrmTests.all)
