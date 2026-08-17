#!/usr/bin/env python3
"""Render OmniInfer schema-v6 catalog fragments from a published manifest."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse


COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
RELEASE_REPOSITORY = "zzw-2025/omnicore-prebuilt"
SOURCE_REPOSITORY = "omnimind-ai/OmniCore"
SIGNING_WORKFLOW = (
    "https://github.com/zzw-2025/omnicore-prebuilt/"
    ".github/workflows/sign-release.yml"
)
OIDC_ISSUER = "https://token.actions.githubusercontent.com"
BACKEND_CONTRACTS = {
    "omnicore-cpu": ("windows", "x86_64", "cpu", "zip", "llama-server.exe"),
    "omnicore-cuda": ("windows", "x86_64", "cuda", "zip", "llama-server.exe"),
    "omnicore-metal": ("macos", "arm64", "metal", "tar.gz", "llama-server"),
}


def github_repository(raw: str) -> str:
    parsed = urlparse(raw)
    parts = [part for part in parsed.path.split("/") if part]
    if parsed.scheme != "https" or parsed.netloc != "github.com" or len(parts) != 2:
        raise ValueError(f"not a canonical GitHub repository URL: {raw}")
    return "/".join(parts)


def release_identity(raw: str) -> tuple[str, str, str]:
    parsed = urlparse(raw)
    parts = [part for part in parsed.path.split("/") if part]
    if (
        parsed.scheme != "https"
        or parsed.netloc != "github.com"
        or len(parts) != 6
        or parts[2:4] != ["releases", "download"]
    ):
        raise ValueError(f"not a canonical GitHub Release asset URL: {raw}")
    return f"{parts[0]}/{parts[1]}", unquote(parts[4]), unquote(parts[5])


def render(manifest: dict[str, Any]) -> dict[str, Any]:
    if manifest.get("schemaVersion") != 1 or manifest.get("status") != "published":
        raise ValueError("manifest must be schemaVersion 1 with status published")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise ValueError("published manifest has no artifacts")

    sources: dict[str, dict[str, str]] = {}
    platforms: dict[str, dict[str, Any]] = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise ValueError("manifest artifact must be an object")
        backend = artifact.get("backendId")
        contract = BACKEND_CONTRACTS.get(backend)
        if contract is None:
            raise ValueError(f"unsupported OmniCore backend ID: {backend}")
        platform, architecture, accelerator, archive, launcher = contract
        actual_contract = (
            artifact.get("platform"),
            artifact.get("architecture"),
            artifact.get("accelerator"),
            artifact.get("archive"),
            artifact.get("launcher"),
        )
        if actual_contract != contract:
            raise ValueError(f"{backend}: artifact does not match its platform contract")
        source_repository = github_repository(artifact.get("sourceRepository", ""))
        if source_repository != SOURCE_REPOSITORY:
            raise ValueError(f"{backend}: unexpected source repository {source_repository}")
        source_commit = artifact.get("sourceCommit")
        if not isinstance(source_commit, str) or not COMMIT_RE.fullmatch(source_commit):
            raise ValueError(f"{backend}: invalid source commit")
        release_repository, release_tag, asset_name = release_identity(
            artifact.get("assetUrl", "")
        )
        if release_repository != RELEASE_REPOSITORY:
            raise ValueError(f"{backend}: unexpected release repository {release_repository}")
        version = artifact.get("version")
        if not isinstance(version, str) or not version or release_tag != f"v{version}":
            raise ValueError(f"{backend}: version does not match Release tag {release_tag}")
        suffix = accelerator
        if accelerator == "cuda":
            runtime_version = artifact.get("runtimeVersion")
            if not isinstance(runtime_version, str) or not runtime_version:
                raise ValueError(f"{backend}: CUDA runtimeVersion is required")
            suffix = f"cuda-{runtime_version}"
        extension = "zip" if archive == "zip" else "tar.gz"
        expected_asset_name = (
            f"omnicore-{version}-{platform}-{architecture}-{suffix}.{extension}"
        )
        if asset_name != expected_asset_name:
            raise ValueError(
                f"{backend}: asset name {asset_name} does not match {expected_asset_name}"
            )
        size_bytes = artifact.get("sizeBytes")
        if not isinstance(size_bytes, int) or size_bytes < 1_048_576:
            raise ValueError(f"{backend}: invalid asset size")
        digest = artifact.get("sha256")
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            raise ValueError(f"{backend}: invalid SHA-256")
        signature = artifact.get("signature")
        if not isinstance(signature, dict) or signature.get("algorithm") != "cosign-keyless":
            raise ValueError(f"{backend}: published artifact has no keyless cosign signature")
        signature_repository, signature_tag, signature_name = release_identity(
            signature.get("assetUrl", "")
        )
        if (
            signature_repository != release_repository
            or signature_tag != release_tag
            or signature_name != f"{asset_name}.sigstore.json"
        ):
            raise ValueError(f"{backend}: signature bundle does not match the runtime asset")
        signature_sha256 = signature.get("sha256")
        if not isinstance(signature_sha256, str) or not SHA256_RE.fullmatch(
            signature_sha256
        ):
            raise ValueError(f"{backend}: invalid signature bundle SHA-256")
        if signature.get("certificateOidcIssuer") != OIDC_ISSUER:
            raise ValueError(f"{backend}: unexpected certificate OIDC issuer")
        valid_identities = {
            f"{SIGNING_WORKFLOW}@refs/tags/{release_tag}",
            f"{SIGNING_WORKFLOW}@refs/heads/main",
        }
        if signature.get("certificateIdentity") not in valid_identities:
            raise ValueError(f"{backend}: unexpected signing workflow identity")

        source = {
            "source_repository": source_repository,
            "source_commit": source_commit,
            "release_repository": release_repository,
            "release_tag": release_tag,
        }
        existing = sources.setdefault(source_repository, source)
        if existing != source:
            raise ValueError(f"{backend}: source or release identity differs from another artifact")

        entry = {
            "source": source_repository,
            "url": artifact["assetUrl"],
            "archive": archive,
            "launcher": launcher,
            "sha256": digest,
        }
        required_files = artifact.get("requiredFiles", [])
        if required_files:
            entry["required_files"] = required_files
        platform_entries = platforms.setdefault(platform, {})
        if backend in platform_entries:
            raise ValueError(f"duplicate backend ID: {backend}")
        platform_entries[backend] = entry

    return {"sources": sources, "platforms": platforms}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path("manifest.json"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        payload = render(json.loads(args.manifest.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, ValueError) as error:
        parser.error(str(error))
    rendered = json.dumps(payload, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered, encoding="utf-8", newline="\n")
    else:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
