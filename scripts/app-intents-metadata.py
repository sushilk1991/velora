#!/usr/bin/env python3
"""Validate checked-in App Intents metadata; optionally regenerate with Xcode.

The app itself builds with Command Line Tools. Apple ships its metadata
extractor only with Xcode, so keep its generated output and source digest in
the repository. A changed intent must be regenerated before packaging.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources/Velora/Shortcuts/VeloraIntents.swift"
DEST = ROOT / "Resources/Metadata.appintents"
MANIFEST = ROOT / "Resources/AppIntentsManifest.json"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def refresh(const_values: Path) -> None:
    if const_values.stat().st_mtime_ns < SOURCE.stat().st_mtime_ns:
        raise SystemExit("The compiler values predate the intent source. Run swift build before refreshing metadata.")
    developer = Path(os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
    tool = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor"
    version = plistlib.loads((developer.parent / "version.plist").read_bytes())["ProductBuildVersion"]
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    sdk = os.environ.get("SDKROOT", sdk)
    toolchain = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
    toolchain = str(Path(toolchain).resolve().parent.parent)
    with tempfile.TemporaryDirectory(prefix="velora-intents-") as work:
        temporary = Path(work)
        sources = temporary / "sources.txt"
        values = temporary / "values.txt"
        sources.write_text(str(SOURCE) + "\n")
        values.write_text(str(const_values.resolve(strict=True)) + "\n")
        subprocess.run([str(tool), "--output", str(temporary), "--toolchain-dir", toolchain,
                        "--module-name", "Velora", "--sdk-root", sdk, "--xcode-version", version,
                        "--platform-family", "macOS", "--deployment-target", "14.0",
                        "--target-triple", "arm64-apple-macos14.0", "--source-file-list", str(sources),
                        "--swift-const-vals-list", str(values), "--deployment-aware-processing"], check=True)
        DEST.mkdir(parents=True, exist_ok=True)
        for name in ("extract.actionsdata", "version.json"):
            (DEST / name).write_bytes((temporary / "Metadata.appintents" / name).read_bytes())
    manifest = {"source": str(SOURCE.relative_to(ROOT)), "sha256": digest(SOURCE),
                "files": {name: digest(DEST / name) for name in ("extract.actionsdata", "version.json")}}
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")


def validate() -> None:
    manifest = json.loads(MANIFEST.read_text())
    if digest(SOURCE) != manifest["sha256"]:
        raise SystemExit("App Intents changed. Build, then regenerate metadata with scripts/app-intents-metadata.py --refresh --const-values <VeloraIntents.swiftconstvalues>.")
    for name, expected in manifest["files"].items():
        if digest(DEST / name) != expected:
            raise SystemExit("App Intents metadata differs from its manifest: " + name)
    actions = json.loads((DEST / "extract.actionsdata").read_text())["actions"]
    expected = {"VeloraGetLastResultIntent", "VeloraReformatTextIntent",
                "VeloraTranscribeFileIntent", "VeloraExportMeetingIntent"}
    if set(actions) != expected:
        raise SystemExit("App Intents catalog is missing a supported action")
    print("App Intents metadata OK (4 actions)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--const-values", type=Path)
    args = parser.parse_args()
    if args.refresh:
        if args.const_values is None:
            parser.error("--refresh requires --const-values from the current Swift build")
        refresh(args.const_values)
    validate()
