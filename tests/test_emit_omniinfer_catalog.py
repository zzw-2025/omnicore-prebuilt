from __future__ import annotations

import runpy
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "emit-omniinfer-catalog.py"
render = runpy.run_path(str(SCRIPT), run_name="catalog_renderer_test")["render"]


def published_manifest() -> dict:
    return {
        "schemaVersion": 1,
        "status": "published",
        "artifacts": [
            {
                "backendId": "omnicore-cpu",
                "version": "0.1.0",
                "sourceRepository": "https://github.com/omnimind-ai/OmniCore",
                "sourceCommit": "093b52aa7838e2da0a2d2a73133c1bad895ce157",
                "platform": "windows",
                "architecture": "x86_64",
                "accelerator": "cpu",
                "archive": "zip",
                "launcher": "llama-server.exe",
                "requiredFiles": ["vcomp140.dll"],
                "assetUrl": "https://github.com/zzw-2025/omnicore-prebuilt/releases/download/v0.1.0/omnicore-0.1.0-windows-x86_64-cpu.zip",
                "sizeBytes": 3_790_517,
                "sha256": "a" * 64,
                "signature": {
                    "algorithm": "cosign-keyless",
                    "assetUrl": "https://github.com/zzw-2025/omnicore-prebuilt/releases/download/v0.1.0/omnicore-0.1.0-windows-x86_64-cpu.zip.sigstore.json",
                    "sha256": "b" * 64,
                    "certificateIdentity": "https://github.com/zzw-2025/omnicore-prebuilt/.github/workflows/sign-release.yml@refs/tags/v0.1.0",
                    "certificateOidcIssuer": "https://token.actions.githubusercontent.com",
                },
            }
        ],
    }


class CatalogRendererTests(unittest.TestCase):
    def test_renders_separate_source_and_release_identity(self) -> None:
        result = render(published_manifest())
        source = result["sources"]["omnimind-ai/OmniCore"]
        self.assertEqual(source["release_repository"], "zzw-2025/omnicore-prebuilt")
        self.assertEqual(source["release_tag"], "v0.1.0")
        entry = result["platforms"]["windows"]["omnicore-cpu"]
        self.assertEqual(entry["required_files"], ["vcomp140.dll"])

    def test_rejects_draft_manifest(self) -> None:
        manifest = published_manifest()
        manifest["status"] = "draft"
        with self.assertRaisesRegex(ValueError, "status published"):
            render(manifest)

    def test_accepts_unsigned_artifact_with_sha256(self) -> None:
        manifest = published_manifest()
        del manifest["artifacts"][0]["signature"]
        result = render(manifest)
        self.assertEqual(
            result["platforms"]["windows"]["omnicore-cpu"]["sha256"], "a" * 64
        )

    def test_accepts_minisign_signature(self) -> None:
        manifest = published_manifest()
        manifest["artifacts"][0]["signature"] = {
            "algorithm": "minisign",
            "publicKeyId": "release-key-1",
            "assetUrl": (
                "https://github.com/zzw-2025/omnicore-prebuilt/releases/download/"
                "v0.1.0/omnicore-0.1.0-windows-x86_64-cpu.zip.minisig"
            ),
            "sha256": "b" * 64,
        }
        result = render(manifest)
        self.assertIn("omnicore-cpu", result["platforms"]["windows"])

    def test_rejects_signature_bundle_from_another_release(self) -> None:
        manifest = published_manifest()
        manifest["artifacts"][0]["signature"]["assetUrl"] = (
            "https://github.com/zzw-2025/omnicore-prebuilt/releases/download/"
            "v0.2.0/omnicore-0.1.0-windows-x86_64-cpu.zip.sigstore.json"
        )
        with self.assertRaisesRegex(ValueError, "signature bundle does not match"):
            render(manifest)

    def test_rejects_backend_platform_contract_mismatch(self) -> None:
        manifest = published_manifest()
        manifest["artifacts"][0]["accelerator"] = "cuda"
        with self.assertRaisesRegex(ValueError, "platform contract"):
            render(manifest)

    def test_rejects_version_that_does_not_match_release_tag(self) -> None:
        manifest = published_manifest()
        manifest["artifacts"][0]["version"] = "0.2.0"
        with self.assertRaisesRegex(ValueError, "version does not match"):
            render(manifest)


if __name__ == "__main__":
    unittest.main()
