import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

const workflow = staticRead("../.github/workflows/release.yml")

proc publishScript(): string =
  # Exercise the actual workflow step with an offline gh stub.
  const marker =
    "      - name: Publish GitHub Release\n        shell: bash\n        run: |\n"
  let start = workflow.find(marker)
  doAssert start >= 0, "release publishing step not found"
  for line in workflow[start + marker.len .. ^1].splitLines():
    if line.len == 0:
      continue
    if not line.startsWith("          "):
      break
    result.add(line[10 .. ^1] & "\n")

proc publish(viewExit, publishExit: int): tuple[code: int, calls, output: string] =
  let directory = createTempDir("matter-release-", "")
  defer:
    removeDir(directory)
  writeFile(
    directory / "grammar-archives.txt",
    "data/grammars/one.zip\ndata/grammars/two words.zip\n",
  )
  writeFile(directory / "publish.sh", publishScript())
  let stub = directory / "stub.sh"
  writeFile(
    stub,
    """
gh() {
  printf '%s\n' "$@" >> "$RUNNER_TEMP/calls.txt"
  printf '%s\n' '<END>' >> "$RUNNER_TEMP/calls.txt"
  case "$1 $2" in
    'release view') return "$MATTER_VIEW_EXIT" ;;
    'release create')
      if [ "$MATTER_VIEW_EXIT" = 0 ]; then return 17; fi
      return "$MATTER_PUBLISH_EXIT" ;;
    'release upload') return "$MATTER_PUBLISH_EXIT" ;;
    *) return 99 ;;
  esac
}
""",
  )
  # Restrict PATH so no real gh command can run, even if stub loading fails.
  let environment = newStringTable(
    {
      "PATH": directory,
      "BASH_ENV": stub,
      "RUNNER_TEMP": directory,
      "GITHUB_REF_NAME": "v0.6.0",
      "MATTER_VIEW_EXIT": $viewExit,
      "MATTER_PUBLISH_EXIT": $publishExit,
    }
  )
  let process = startProcess(
    findExe("bash"),
    args = @["--noprofile", "--norc", "-e", "-o", "pipefail", directory / "publish.sh"],
    env = environment,
    options = {poStdErrToStdOut},
  )
  defer:
    process.close()
  result.output = process.outputStream.readAll()
  result.code = process.waitForExit()
  result.calls = readFile(directory / "calls.txt")

suite "release workflow publishing":
  test "creates a new release with every archive as a separate argument":
    let published = publish(1, 0)
    checkpoint(published.output)
    check published.code == 0
    check published.calls ==
      "release\nview\nv0.6.0\n<END>\n" &
      "release\ncreate\nv0.6.0\ndata/grammars/one.zip\ndata/grammars/two words.zip\n" &
      "--verify-tag\n--generate-notes\n<END>\n"

  test "uploads archives to an existing release instead of recreating it":
    let published = publish(0, 0)
    checkpoint(published.output)
    check published.code == 0
    check published.calls ==
      "release\nview\nv0.6.0\n<END>\n" &
      "release\nupload\nv0.6.0\ndata/grammars/one.zip\ndata/grammars/two words.zip\n" &
      "--clobber\n<END>\n"

  test "reports failures when creating or updating a release":
    for viewExit in [0, 1]:
      let published = publish(viewExit, 7)
      checkpoint(published.output)
      check published.code == 7
