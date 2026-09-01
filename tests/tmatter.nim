import std/unittest

import matter

suite "matter":
  test "greets by name":
    check greet("Nim") == "hello, Nim"

