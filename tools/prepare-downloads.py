#!/usr/bin/env python3
"""Prepare curated public installer assets; never publishes or builds an APK.

Use --from-dir for locally curated artifacts before publication. Without it,
download only the fixed public v1.2.0 release and verify its SHA256SUMS.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
from pathlib import Path
import re
import shutil
import sys
import urllib.request

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
VERSION = "v1.2.0"
BASE = "https://github.com/gil906/openreader_mobile/releases/download/" + VERSION
ASSETS = (
    "OpenReader-Native-v1.2.0.apk",
    "OpenReader-Native-source.zip",
    "kokoro-english-v1.zip",
)


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(name: str, destination: Path) -> None:
    request = urllib.request.Request(BASE + "/" + name, headers={"User-Agent": "OpenReader-public-asset-preparer/1.2.0"})
    with urllib.request.urlopen(request, timeout=90) as response:
        # GitHub release downloads redirect to the public asset CDN.
        if not response.url.startswith("https://"):
            raise ValueError("refusing non-HTTPS asset redirect")
        with destination.open("wb") as stream:
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > 1024 * 1024 * 1024:
                    raise ValueError("asset exceeds 1 GiB")
                stream.write(chunk)


def checksums(path: Path) -> dict[str, str]:
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([a-fA-F0-9]{64}) [ *]([A-Za-z0-9._-]+)", line)
        if not match:
            raise ValueError("malformed checksum manifest")
        sha, name = match.groups()
        if name in result:
            raise ValueError("duplicate checksum entry")
        result[name] = sha.lower()
    if set(result) != set(ASSETS):
        raise ValueError("checksum manifest must contain exactly the three curated assets")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from-dir", type=Path, help="already curated local APK, source ZIP, and pinned voice ZIP; no network")
    parser.add_argument("--checksums", type=Path, help="independently trusted checksum manifest; required for stronger provenance")
    args = parser.parse_args()
    dist = ROOT / "dist"
    if dist.exists():
        parser.error("dist already exists; review and remove it explicitly before preparing again")
    source = args.from_dir.resolve() if args.from_dir else None
    dist.mkdir()
    try:
        spec = importlib.util.spec_from_file_location("public_guard", ROOT / "tools/check_public_release.py")
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        expected = checksums(args.checksums) if args.checksums else None
        if source is None and expected is None:
            fetch("SHA256SUMS", dist / "SHA256SUMS")
            expected = checksums(dist / "SHA256SUMS")
        for name in ASSETS:
            destination = dist / name
            if source:
                origin = source / name
                if origin.is_symlink() or not origin.is_file():
                    raise ValueError("local asset must be a regular file")
                shutil.copyfile(origin, destination)
            else:
                fetch(name, destination)
            if expected and digest(destination) != expected[name]:
                raise ValueError("release asset checksum mismatch")
        scanner = guard.Scanner()
        for name in ASSETS:
            scanner.artifact(dist / name)
        if scanner.errors:
            raise ValueError("asset privacy validation failed; run the scanner directly for redacted diagnostics")
        if (dist / ASSETS[0]).stat().st_size == 0:
            raise ValueError("APK is empty")
        (dist / "SHA256SUMS").write_text(
            "".join(f"{digest(dist / name)}  {name}\n" for name in ASSETS), encoding="utf-8"
        )
        shutil.copyfile(ROOT / "container/index.html", dist / "index.html")
        print("Prepared dist/: three scanned installer assets, matching checksums, and download page.")
        print("No files published. Independently verify APK signing certificate and corresponding source.")
        return 0
    except Exception as error:
        shutil.rmtree(dist)
        # Exceptions may contain private local paths, so do not print their values.
        print(f"Preparation failed ({type(error).__name__}); incomplete dist removed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
