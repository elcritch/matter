"""Exercise local grammar packaging without network access or repository writes."""

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
  "regenerate_grammars",
  Path(__file__).resolve().parents[1] / "tools" / "regenerate_grammars.py",
)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class LocalGrammarTests(unittest.TestCase):
  def setUp(self):
    self.temporary = tempfile.TemporaryDirectory(prefix="matter-local-grammar-")
    self.addCleanup(self.temporary.cleanup)
    self.root = Path(self.temporary.name)
    self.data = self.root / "data" / "grammars"
    self.package = {
      "constName": "examplePackage", "namespace": "matter", "name": "example",
      "version": "1.0.0", "sourceKind": "local", "sourceRoot": "grammars/example",
      "licenseId": "MIT", "licenseUrl": "https://example.com/LICENSE",
      "repositoryUrl": "https://example.com/grammar", "downloadUrl": "",
      "specificationUrl": "https://example.com/spec",
      "grammars": [["exampleGrammar", "Example", "example", "source.example",
                    "./example.tmLanguage.json", True]],
    }
    self.manifest = {
      "archiveFormat": "matter-textmate-grammar-archive-v1",
      "moeSourceCommit": "example", "moeMappings": [],
      "sourceVsixSha256": {}, "sourceArchiveSha256": {},
      "packages": [self.package],
    }
    self.source = self.root / "grammars" / "example"
    self.source.mkdir(parents=True)
    (self.source / "LICENSE").write_text("Example license\n")
    (self.source / "package.json").write_text('{"name":"example"}\n')
    self.grammar = self.source / "example.tmLanguage.json"
    self.grammar.write_text('{"scopeName":"source.example","patterns":[]}\n')
    self.paths = patch.multiple(
      builder, ROOT=self.root, DATA_DIR=self.data, NIM_PATH=self.root / "catalog.nim"
    )
    self.paths.start()
    self.addCleanup(self.paths.stop)
    self.archive = self.data / builder.archive_name(self.package)
    self.catalog = self.data / "catalog.json"

  def regenerate(self):
    with patch.object(builder.urllib.request, "urlretrieve", side_effect=AssertionError("network access")), \
         patch.object(builder.subprocess, "run") as formatter, \
         contextlib.redirect_stdout(io.StringIO()):
      builder.regenerate(self.manifest)
      formatter.assert_called_once()

  def test_local_regeneration_is_offline_and_reproducible(self):
    self.regenerate()
    archive = self.archive.read_bytes()
    catalog = self.catalog.read_bytes()
    self.regenerate()
    self.assertEqual(self.archive.read_bytes(), archive)
    self.assertEqual(self.catalog.read_bytes(), catalog)
    builder.verify(self.manifest, self.catalog)
    package = json.loads(catalog)["packages"][0]
    self.assertEqual(package["provenance"]["specificationUrl"], self.package["specificationUrl"])
    self.assertEqual(builder.source_checksum(self.manifest, self.package), "")

  def test_verifier_rejects_changed_local_grammar(self):
    self.regenerate()
    self.grammar.write_text('{"scopeName":"source.example","patterns":[{"match":"x"}]}\n')
    with self.assertRaisesRegex(RuntimeError, "local source differs from archive"):
      builder.verify(self.manifest, self.catalog)

  def test_verifier_rejects_changed_attribution(self):
    self.regenerate()
    (self.source / "LICENSE").write_text("Changed license\n")
    with self.assertRaisesRegex(RuntimeError, "local source differs from archive"):
      builder.verify(self.manifest, self.catalog)


if __name__ == "__main__":
  unittest.main()
