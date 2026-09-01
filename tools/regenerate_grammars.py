#!/usr/bin/env python3
"""Build Matter's small, reproducible TextMate grammar archives.

The JSON manifest is deliberately the only hand-maintained catalog.  This tool
downloads the pinned VSIX files without npm/npx, extracts only its allowlisted
grammars, and writes both the archive catalog and Nim API generated from it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "tools" / "grammar_manifest.json"
DATA_DIR = ROOT / "data" / "grammars"
NIM_PATH = ROOT / "src" / "matter" / "grammarpackages.nim"
ZIP_DATE = (1980, 1, 1, 0, 0, 0)


def package_id(package: dict) -> str:
  return f"{package['namespace']}.{package['name']}"


def archive_name(package: dict) -> str:
  return f"{package['namespace']}-{package['name']}-{package['version']}.zip"


def source_url(package: dict) -> str:
  if "downloadUrl" in package:
    return package["downloadUrl"]
  platform = package.get("targetPlatform")
  stem = f"{package_id(package)}-{package['version']}"
  if platform:
    return (
      f"https://open-vsx.org/api/{package['namespace']}/{package['name']}/"
      f"{platform}/{package['version']}/file/{stem}@{platform}.vsix"
    )
  return (
    f"https://open-vsx.org/api/{package['namespace']}/{package['name']}/"
    f"{package['version']}/file/{stem}.vsix"
  )


def license_member(names: list[str]) -> str:
  matches = [
    name for name in names
    if name.startswith("extension/") and "/" not in name.removeprefix("extension/") and
    Path(name).name.lower().startswith("license")
  ]
  if not matches:
    raise RuntimeError("VSIX has no license file")
  return sorted(matches)[0]


def member_name(grammar_path: str) -> str:
  return "grammar/" + grammar_path.removeprefix("./")


def fixed_info(name: str) -> zipfile.ZipInfo:
  info = zipfile.ZipInfo(name, date_time=ZIP_DATE)
  info.compress_type = zipfile.ZIP_STORED
  info.external_attr = 0o100644 << 16
  info.create_system = 3
  return info


def write_archive(package: dict, source: Path, destination: Path) -> dict:
  with zipfile.ZipFile(source) as vsix:
    names = vsix.namelist()
    package_json = "extension/package.json"
    if package_json not in names:
      raise RuntimeError("VSIX has no extension/package.json")
    license_file = license_member(names)
    needed = [(member_name(item[4]), "extension/" + item[4].removeprefix("./"))
              for item in package["grammars"]]
    missing = [original for _, original in needed if original not in names]
    if missing:
      raise RuntimeError(f"{package_id(package)} lacks grammar members: {missing}")
    provenance = {
      "archiveFormat": "matter-textmate-grammar-archive-v1",
      "package": package_id(package),
      "version": package["version"],
      "downloadUrl": source_url(package),
      "repositoryUrl": package["repositoryUrl"],
      "licenseId": package["licenseId"],
      "licenseUrl": package["licenseUrl"],
      "sourceVsixMember": {member: original for member, original in needed},
    }
    members = {
      "LICENSE": vsix.read(license_file),
      "package.json": vsix.read(package_json),
      "PROVENANCE.json": (json.dumps(provenance, indent=2, sort_keys=True) + "\n").encode(),
    }
    members.update({member: vsix.read(original) for member, original in needed})
  destination.parent.mkdir(parents=True, exist_ok=True)
  with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_STORED) as archive:
    for name in sorted(members):
      archive.writestr(fixed_info(name), members[name])
  return provenance


def nim_string(value: str) -> str:
  return json.dumps(value, ensure_ascii=False)


def render_nim(catalog: dict) -> str:
  packages = catalog["packages"]
  grammars = [grammar + [package_id(package)]
              for package in packages for grammar in package["grammars"]]
  package_constants = []
  for package in packages:
    fields = [
      f"namespace: {nim_string(package['namespace'])}",
      f"name: {nim_string(package['name'])}",
      f"version: {nim_string(package['version'])}",
      f"targetPlatform: {nim_string(package.get('targetPlatform', ''))}",
      f"sourceVsixSha256: {nim_string(catalog['sourceVsixSha256'][package['sourceFile']])}",
      f"licenseId: {nim_string(package['licenseId'])}",
      f"repositoryUrl: {nim_string(package['repositoryUrl'])}",
      f"licenseUrl: {nim_string(package['licenseUrl'])}",
      f"downloadUrl: {nim_string(source_url(package))}",
      f"dataArchivePath: {nim_string('data/grammars/' + archive_name(package))}",
      f"archiveSha256: {nim_string(package['archiveSha256'])}",
    ]
    package_constants.append(
      f"  {package['constName']}* = SourcePackage(" + ", ".join(fields) + ")"
    )
  grammar_constants = []
  for const_name, display, language, scope, path, primary, key in grammars:
    archive = next(p for p in packages if package_id(p) == key)
    fields = [
      f"displayName: {nim_string(display)}",
      f"languageId: {nim_string(language)}",
      f"scopeName: {nim_string(scope)}",
      f"grammarPath: {nim_string(path)}",
      f"archiveMember: {nim_string(member_name(path))}",
      f"packageKey: {nim_string(key)}",
      f"dataArchivePath: {nim_string('data/grammars/' + archive_name(archive))}",
      f"isPrimary: {'true' if primary else 'false'}",
    ]
    grammar_constants.append(f"  {const_name}* = GrammarContribution(" + ", ".join(fields) + ")")
  mappings = []
  for mode, scope in catalog["moeMappings"]:
    mappings.append(f"    MoeGrammarMapping(modeName: {nim_string(mode)}, scopeName: {nim_string(scope)})")
  return """## Pinned, redistributable TextMate grammar packages for Matter.
##
## This file is generated by ``tools/regenerate_grammars.py`` from
## ``tools/grammar_manifest.json``.  The catalog is network-free at runtime;
## each listed archive contains only allowlisted grammar files and attribution.

import std/options

type
  SourcePackage* = object ## A pinned grammar source package and local archive.
    namespace*: string
    name*: string
    version*: string
    targetPlatform*: string
    sourceVsixSha256*: string
    licenseId*: string
    repositoryUrl*: string
    licenseUrl*: string
    downloadUrl*: string
    dataArchivePath*: string
    archiveSha256*: string

  OpenVsxPackage* = SourcePackage ## Compatibility name for Open VSX packages.

  GrammarContribution* = object ## A grammar file retained in a local archive.
    displayName*: string
    languageId*: string
    scopeName*: string
    grammarPath*: string
    archiveMember*: string
    packageKey*: string
    dataArchivePath*: string
    isPrimary*: bool

  LanguageGrammar* = GrammarContribution ## Compatibility name for grammar records.

  MoeGrammarMapping* = object ## One current Moe ``SourceLanguage`` mode.
    modeName*: string
    scopeName*: string

const
  openVsxApiBaseUrl* = "https://open-vsx.org/api"
""" + "\n".join(package_constants) + "\n\n" + "  knownPackages* = [\n" + ",\n".join(
    f"    {p['constName']}" for p in packages
  ) + "\n  ]\n\n" + "\n".join(grammar_constants) + "\n\n" + "  knownGrammars* = [\n" + ",\n".join(
    f"    {grammar[0]}" for grammar in grammars
  ) + "\n  ]\n\n  moeGrammarMappings* = [\n" + ",\n".join(mappings) + "\n  ]\n\n" + """func extensionId*(package: SourcePackage): string =
  ## Returns the source extension identifier, such as ``vscode.cpp``.
  package.namespace & "." & package.name

func versionMetadataUrl*(namespace, name, version: string): string =
  ## Returns the Open VSX metadata URL for a specific extension version.
  openVsxApiBaseUrl & "/" & namespace & "/" & name & "/" & version

func versionMetadataUrl*(package: SourcePackage): string =
  ## Returns the conventional Open VSX metadata URL for this package.
  versionMetadataUrl(package.namespace, package.name, package.version)

func latestMetadataUrl*(package: SourcePackage): string =
  ## Returns the conventional Open VSX latest-version metadata URL.
  versionMetadataUrl(package.namespace, package.name, "latest")

func vsixDownloadUrl*(namespace, name, version: string): string =
  ## Returns a direct versioned Open VSX VSIX URL.
  let extension = namespace & "." & name & "-" & version & ".vsix"
  versionMetadataUrl(namespace, name, version) & "/file/" & extension

func vsixDownloadUrl*(package: SourcePackage): string =
  ## Returns this package's exact pinned VSIX URL, including target platforms.
  package.downloadUrl

func findGrammar*(scopeName: string): Option[GrammarContribution] =
  ## Finds an archived grammar by its TextMate scope name.
  for grammar in knownGrammars:
    if grammar.scopeName == scopeName:
      return some(grammar)
  none(GrammarContribution)

func findMoeGrammar*(modeName: string): Option[GrammarContribution] =
  ## Finds the primary grammar imported for a current Moe language mode.
  for mapping in moeGrammarMappings:
    if mapping.modeName == modeName:
      return findGrammar(mapping.scopeName)
  none(GrammarContribution)

iterator importedGrammars*(modeName: string): GrammarContribution =
  ## Yields a Moe mode's primary grammar followed by support grammars bundled
  ## with the same source package.  Callers can read every yielded member from
  ## its ``dataArchivePath`` without downloading anything.
  let primary = findMoeGrammar(modeName)
  if primary.isSome:
    yield primary.get
    for grammar in knownGrammars:
      if grammar.packageKey == primary.get.packageKey and
          grammar.scopeName != primary.get.scopeName:
        yield grammar
"""


def write_catalog(manifest: dict, provenance: dict[str, dict]) -> dict:
  catalog = json.loads(json.dumps(manifest))
  for package in catalog["packages"]:
    archive = DATA_DIR / archive_name(package)
    package["downloadUrl"] = source_url(package)
    package["dataArchivePath"] = "data/grammars/" + archive.name
    package["archiveSha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
    package["archiveMembers"] = sorted([
      "LICENSE", "package.json", "PROVENANCE.json",
      *{member_name(item[4]) for item in package["grammars"]},
    ])
    package["provenance"] = provenance[package_id(package)]
  return catalog


def write_notices(catalog: dict) -> None:
  lines = ["# Grammar archive notices", "", "These archives are generated from pinned VSIX sources.",
           "Each ZIP includes its source package license, manifest, and provenance.", ""]
  for package in catalog["packages"]:
    lines.extend([
      f"## {package_id(package)} {package['version']}", "",
      f"- License: {package['licenseId']} ({package['licenseUrl']})",
      f"- Source: {package['downloadUrl']}",
      f"- Repository: {package['repositoryUrl']}",
      f"- SHA-256: `{package['archiveSha256']}`", "",
    ])
  (DATA_DIR / "NOTICES.md").write_text("\n".join(lines), encoding="utf-8")


def regenerate(manifest: dict) -> None:
  with tempfile.TemporaryDirectory(prefix="matter-grammars-") as temporary:
    source_dir = Path(temporary)
    provenance = {}
    for package in manifest["packages"]:
      source = source_dir / package["sourceFile"]
      print(f"download {package_id(package)} {package['version']}")
      urllib.request.urlretrieve(source_url(package), source)
      actual_sha256 = hashlib.sha256(source.read_bytes()).hexdigest()
      expected_sha256 = manifest["sourceVsixSha256"][package["sourceFile"]]
      if actual_sha256 != expected_sha256:
        raise RuntimeError(
          f"source checksum mismatch for {package_id(package)}: {actual_sha256}"
        )
      destination = DATA_DIR / archive_name(package)
      provenance[package_id(package)] = write_archive(package, source, destination)
    catalog = write_catalog(manifest, provenance)
    (DATA_DIR / "catalog.json").write_text(
      json.dumps(catalog, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    write_notices(catalog)
    NIM_PATH.write_text(render_nim(catalog), encoding="utf-8")
    subprocess.run(["nph", str(NIM_PATH)], cwd=ROOT, check=True)


def verify(manifest: dict, catalog_path: Path = DATA_DIR / "catalog.json") -> None:
  if not catalog_path.exists():
    raise RuntimeError("missing data/grammars/catalog.json; run regenerateGrammars")
  catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
  for key in ("archiveFormat", "moeSourceCommit", "moeMappings", "sourceVsixSha256"):
    if catalog.get(key) != manifest.get(key):
      raise RuntimeError(f"catalog {key} differs from the source manifest")
  expected_ids = [package_id(package) for package in manifest["packages"]]
  actual_ids = [package_id(package) for package in catalog["packages"]]
  if actual_ids != expected_ids:
    raise RuntimeError("catalog packages differ from the source manifest")
  for expected, actual in zip(manifest["packages"], catalog["packages"]):
    for key, value in expected.items():
      if actual.get(key) != value:
        raise RuntimeError(
          f"catalog package {package_id(expected)} field {key} differs from the source manifest"
        )
  for package in catalog["packages"]:
    archive = DATA_DIR / archive_name(package)
    if not archive.exists():
      raise RuntimeError(f"missing archive: {archive}")
    if hashlib.sha256(archive.read_bytes()).hexdigest() != package["archiveSha256"]:
      raise RuntimeError(f"checksum mismatch: {archive}")
    with zipfile.ZipFile(archive) as source:
      members = source.namelist()
      if members != sorted(members) or members != package["archiveMembers"]:
        raise RuntimeError(f"unexpected archive members: {archive}")
      for info in source.infolist():
        if (info.compress_type != zipfile.ZIP_STORED or info.date_time != ZIP_DATE or
            info.external_attr >> 16 != 0o100644):
          raise RuntimeError(f"archive is not deterministic ZIP_STORED: {archive}")
      if "LICENSE" not in members or "package.json" not in members:
        raise RuntimeError(f"archive lacks attribution: {archive}")
      for grammar in package["grammars"]:
        member = member_name(grammar[4])
        contents = source.read(member)
        try:
          scope = json.loads(contents)["scopeName"]
        except UnicodeDecodeError:
          scope = plistlib.loads(contents)["scopeName"]
        except json.JSONDecodeError:
          scope = plistlib.loads(contents)["scopeName"]
        if scope != grammar[3]:
          raise RuntimeError(f"scope mismatch in {archive}:{member}: {scope}")
  print(f"verified {len(catalog['packages'])} archives and {len(catalog['moeMappings'])} Moe modes")


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("--verify", action="store_true", help="verify existing archives offline")
  parser.add_argument("--catalog", type=Path, help="catalog path used with --verify")
  args = parser.parse_args()
  manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
  if args.verify:
    verify(manifest, args.catalog or DATA_DIR / "catalog.json")
  elif args.catalog:
    parser.error("--catalog requires --verify")
  else:
    regenerate(manifest)


if __name__ == "__main__":
  try:
    main()
  except Exception as error:
    print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)
