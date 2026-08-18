#!/usr/bin/env python3
"""Create a published manifest from verified OmniCore Release archives."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import tarfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any


RELEASE_REPOSITORY = "zzw-2025/omnicore-prebuilt"
SOURCE_REPOSITORY = "https://github.com/omnimind-ai/OmniCore"
ASSET_RE = re.compile(
    r"^omnicore-(?P<version>[0-9A-Za-z._-]+)-"
    r"(?P<platform>windows|macos)-(?P<architecture>x86_64|arm64)-"
    r"(?P<variant>cpu|metal|cuda-(?P<runtime>[0-9A-Za-z._-]+))"
    r"(?P<extension>\.zip|\.tar\.gz)$"
)
CONTRACTS = {
    ("windows", "x86_64", "cpu"): ("omnicore-cpu", "llama-server.exe", "zip"),
    ("windows", "x86_64", "cuda"): ("omnicore-cuda", "llama-server.exe", "zip"),
    ("macos", "arm64", "metal"): ("omnicore-metal", "llama-server", "tar.gz"),
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def archive_contents(path: Path) -> tuple[dict[str, Any], list[str]]:
    if path.name.endswith(".zip"):
        with zipfile.ZipFile(path) as archive:
            names = [name for name in archive.namelist() if not name.endswith("/")]
            metadata_names = [
                name for name in names if PurePosixPath(name).name == "build-metadata.json"
            ]
            if len(metadata_names) != 1:
                raise ValueError(f"{path.name}: expected one build-metadata.json")
            metadata = json.loads(archive.read(metadata_names[0]).decode("utf-8-sig"))
    else:
        with tarfile.open(path, "r:gz") as archive:
            members = [member for member in archive.getmembers() if member.isfile()]
            names = [member.name for member in members]
            metadata_members = [
                member
                for member in members
                if PurePosixPath(member.name).name == "build-metadata.json"
            ]
            if len(metadata_members) != 1:
                raise ValueError(f"{path.name}: expected one build-metadata.json")
            stream = archive.extractfile(metadata_members[0])
            if stream is None:
                raise ValueError(f"{path.name}: cannot read build-metadata.json")
            metadata = json.loads(stream.read().decode("utf-8-sig"))
    if not isinstance(metadata, dict):
        raise ValueError(f"{path.name}: build metadata must be an object")
    basenames = [PurePosixPath(name).name for name in names]
    if len(basenames) != len(set(basenames)):
        raise ValueError(f"{path.name}: runtime files must have unique basenames")
    return metadata, sorted(basenames)


def artifact_from_archive(
    archive: Path,
    version: str,
    tag: str,
    signature_mode: str,
    certificate_identity: str | None,
    certificate_oidc_issuer: str | None,
    public_key_id: str | None,
) -> dict[str, Any]:
    match = ASSET_RE.fullmatch(archive.name)
    if match is None or match.group("version") != version:
        raise ValueError(f"unexpected release asset name: {archive.name}")
    platform = match.group("platform")
    architecture = match.group("architecture")
    variant = match.group("variant")
    accelerator = "cuda" if variant.startswith("cuda-") else variant
    contract = CONTRACTS.get((platform, architecture, accelerator))
    if contract is None:
        raise ValueError(f"unsupported runtime contract: {archive.name}")
    backend_id, launcher, archive_kind = contract
    extension = ".zip" if archive_kind == "zip" else ".tar.gz"
    if match.group("extension") != extension:
        raise ValueError(f"{archive.name}: extension does not match platform contract")

    metadata, required_files = archive_contents(archive)
    expected = {
        "backendId": backend_id,
        "sourceRepository": SOURCE_REPOSITORY,
        "platform": platform,
        "architecture": architecture,
        "accelerator": accelerator,
    }
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise ValueError(f"{archive.name}: metadata {key} does not match {value}")
    source_commit = metadata.get("sourceCommit")
    if not isinstance(source_commit, str) or re.fullmatch(r"[0-9a-f]{40}", source_commit) is None:
        raise ValueError(f"{archive.name}: invalid source commit")
    for required in (launcher, "LICENSE", "THIRD_PARTY_NOTICES.md", "build-metadata.json"):
        if required not in required_files:
            raise ValueError(f"{archive.name}: required file is missing: {required}")

    runtime_version = match.group("runtime")
    if accelerator == "cuda" and metadata.get("cudaVersion") != runtime_version:
        raise ValueError(f"{archive.name}: CUDA version differs from build metadata")
    base_url = f"https://github.com/{RELEASE_REPOSITORY}/releases/download/{tag}"
    artifact: dict[str, Any] = {
        "backendId": backend_id,
        "version": version,
        "sourceRepository": SOURCE_REPOSITORY,
        "sourceCommit": source_commit,
        "platform": platform,
        "architecture": architecture,
        "accelerator": accelerator,
        "bootstrapCompatibility": {"minimumOmniInferVersion": "0.3.21"},
        "protocol": "llama.cpp-server",
        "capabilities": ["chat", "stream"],
        "archive": archive_kind,
        "launcher": launcher,
        "requiredFiles": required_files,
        "runtimeDependencies": (
            [f"NVIDIA driver compatible with CUDA {runtime_version}"]
            if accelerator == "cuda"
            else []
        ),
        "license": (
            "MIT"
            if platform == "macos"
            else (
                "MIT; Microsoft Visual Studio Redistributable terms; "
                "NVIDIA CUDA Toolkit EULA"
                if accelerator == "cuda"
                else "MIT; Microsoft Visual Studio Redistributable terms"
            )
        ),
        "assetUrl": f"{base_url}/{archive.name}",
        "sizeBytes": archive.stat().st_size,
        "sha256": sha256_file(archive),
    }
    if signature_mode == "cosign-keyless":
        if not certificate_identity or not certificate_oidc_issuer:
            raise ValueError("cosign-keyless requires certificate identity and issuer")
        bundle = archive.with_name(f"{archive.name}.sigstore.json")
        if not bundle.is_file():
            raise ValueError(f"{archive.name}: Sigstore bundle is missing")
        artifact["signature"] = {
            "algorithm": "cosign-keyless",
            "certificateIdentity": certificate_identity,
            "certificateOidcIssuer": certificate_oidc_issuer,
            "assetUrl": f"{base_url}/{bundle.name}",
            "sha256": sha256_file(bundle),
        }
    elif signature_mode == "minisign":
        if not public_key_id:
            raise ValueError("minisign requires a public key ID")
        signature = archive.with_name(f"{archive.name}.minisig")
        if not signature.is_file():
            raise ValueError(f"{archive.name}: minisign signature is missing")
        artifact["signature"] = {
            "algorithm": "minisign",
            "publicKeyId": public_key_id,
            "assetUrl": f"{base_url}/{signature.name}",
            "sha256": sha256_file(signature),
        }
    elif signature_mode != "none":
        raise ValueError(f"unsupported signature mode: {signature_mode}")
    if runtime_version:
        artifact["runtimeVersion"] = runtime_version
    return artifact


def prepare_manifest(
    assets_dir: Path,
    tag: str,
    signature_mode: str = "none",
    certificate_identity: str | None = None,
    certificate_oidc_issuer: str | None = None,
    public_key_id: str | None = None,
) -> dict[str, Any]:
    if not tag.startswith("v") or re.fullmatch(r"[0-9A-Za-z._-]+", tag[1:]) is None:
        raise ValueError("release tag must be v<version>")
    version = tag[1:]
    archives = sorted(
        path
        for path in assets_dir.iterdir()
        if path.is_file() and (path.name.endswith(".zip") or path.name.endswith(".tar.gz"))
    )
    if not archives:
        raise ValueError("release contains no runtime archives")
    artifacts = [
        artifact_from_archive(
            archive,
            version,
            tag,
            signature_mode,
            certificate_identity,
            certificate_oidc_issuer,
            public_key_id,
        )
        for archive in archives
    ]
    backend_ids = [artifact["backendId"] for artifact in artifacts]
    if len(backend_ids) != len(set(backend_ids)):
        raise ValueError("release contains duplicate backend artifacts")
    if len({artifact["sourceCommit"] for artifact in artifacts}) != 1:
        raise ValueError("all artifacts in a release must use one source commit")
    return {
        "$schema": "./manifest.schema.json",
        "schemaVersion": 1,
        "status": "published",
        "artifacts": artifacts,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets-dir", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument(
        "--signature-mode",
        choices=("none", "cosign-keyless", "minisign"),
        default="none",
    )
    parser.add_argument("--certificate-identity")
    parser.add_argument("--certificate-oidc-issuer")
    parser.add_argument("--public-key-id")
    parser.add_argument("--output", type=Path, default=Path("manifest.json"))
    args = parser.parse_args()
    try:
        manifest = prepare_manifest(
            args.assets_dir,
            args.tag,
            args.signature_mode,
            args.certificate_identity,
            args.certificate_oidc_issuer,
            args.public_key_id,
        )
        args.output.write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
    except (OSError, ValueError, json.JSONDecodeError, zipfile.BadZipFile, tarfile.TarError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
