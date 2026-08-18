#!/usr/bin/env python3
"""Validate the exact runtime archive set uploaded to a draft Release."""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path


ASSET_RE = re.compile(
    r"^omnicore-(?P<version>[0-9A-Za-z._-]+)-"
    r"(?P<platform>windows|macos)-(?P<architecture>x86_64|arm64)-"
    r"(?P<variant>cpu|metal|cuda-[0-9A-Za-z._-]+)"
    r"(?P<extension>\.zip|\.tar\.gz)$"
)
WINDOWS_CPU = ("windows", "x86_64", "cpu", ".zip")
MACOS_METAL = ("macos", "arm64", "metal", ".tar.gz")
SUPPORTED_CONTRACTS = {
    WINDOWS_CPU,
    MACOS_METAL,
    ("windows", "x86_64", "cuda", ".zip"),
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def archive_contract(path: Path, version: str) -> tuple[str, str, str, str]:
    match = ASSET_RE.fullmatch(path.name)
    if match is None or match.group("version") != version:
        raise ValueError(f"unexpected release asset name: {path.name}")
    variant = match.group("variant")
    accelerator = "cuda" if variant.startswith("cuda-") else variant
    contract = (
        match.group("platform"),
        match.group("architecture"),
        accelerator,
        match.group("extension"),
    )
    if contract not in SUPPORTED_CONTRACTS:
        raise ValueError(f"unsupported runtime contract: {path.name}")
    return contract


def validate_sidecar(archive: Path) -> None:
    sidecar = archive.with_name(f"{archive.name}.sha256")
    if not sidecar.is_file():
        raise ValueError(f"missing checksum sidecar: {sidecar.name}")
    fields = sidecar.read_text(encoding="ascii").strip().split()
    if len(fields) != 2 or fields[1] != archive.name:
        raise ValueError(f"invalid checksum sidecar: {sidecar.name}")
    expected = fields[0]
    if re.fullmatch(r"[0-9a-f]{64}", expected) is None:
        raise ValueError(f"invalid SHA-256 in sidecar: {sidecar.name}")
    actual = sha256_file(archive)
    if actual != expected:
        raise ValueError(f"SHA-256 sidecar mismatch for {archive.name}")


def validate_assets(assets_dir: Path, tag: str, profile: str) -> list[Path]:
    if re.fullmatch(r"v[0-9A-Za-z._-]+", tag) is None:
        raise ValueError("release tag must use the form v<version>")
    version = tag[1:]
    archives = sorted(
        path
        for path in assets_dir.iterdir()
        if path.is_file() and (path.name.endswith(".zip") or path.name.endswith(".tar.gz"))
    )
    contracts = [archive_contract(path, version) for path in archives]
    if len(contracts) != len(set(contracts)):
        raise ValueError("release contains duplicate runtime contracts")

    if profile == "full":
        missing = {WINDOWS_CPU, MACOS_METAL}.difference(contracts)
        if missing:
            raise ValueError("full release requires Windows CPU and macOS Metal archives")
    elif profile == "windows-cpu-preview":
        if contracts != [WINDOWS_CPU]:
            raise ValueError("windows-cpu-preview requires exactly one Windows CPU archive")
    else:
        raise ValueError(f"unknown release profile: {profile}")

    for archive in archives:
        validate_sidecar(archive)
    sidecars = {path.name for path in assets_dir.glob("*.sha256")}
    expected_sidecars = {f"{archive.name}.sha256" for archive in archives}
    if sidecars != expected_sidecars:
        raise ValueError("release contains an orphan or unexpected checksum sidecar")
    return archives


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets-dir", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument(
        "--profile", choices=("full", "windows-cpu-preview"), required=True
    )
    args = parser.parse_args()
    try:
        archives = validate_assets(args.assets_dir, args.tag, args.profile)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(f"validated {len(archives)} archive(s) for {args.profile}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
