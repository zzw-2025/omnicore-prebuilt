import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

import jsonschema


SCRIPT = Path(__file__).parents[1] / "scripts" / "prepare-release-manifest.py"
SPEC = importlib.util.spec_from_file_location("prepare_release_manifest", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)
EMIT_SCRIPT = Path(__file__).parents[1] / "scripts" / "emit-omniinfer-catalog.py"
EMIT_SPEC = importlib.util.spec_from_file_location("emit_omniinfer_catalog", EMIT_SCRIPT)
EMIT_MODULE = importlib.util.module_from_spec(EMIT_SPEC)
assert EMIT_SPEC and EMIT_SPEC.loader
EMIT_SPEC.loader.exec_module(EMIT_MODULE)


class PrepareReleaseManifestTests(unittest.TestCase):
    def make_cpu_archive(
        self,
        root: Path,
        *,
        source_commit: str = "a" * 40,
        backend_id: str = "omnicore-cpu",
    ) -> Path:
        archive = root / "omnicore-0.1.0-windows-x86_64-cpu.zip"
        metadata = {
            "formatVersion": 1,
            "backendId": backend_id,
            "sourceRepository": "https://github.com/omnimind-ai/OmniCore",
            "sourceCommit": source_commit,
            "platform": "windows",
            "architecture": "x86_64",
            "accelerator": "cpu",
        }
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("omnicore-runtime/llama-server.exe", b"x" * 1_100_000)
            bundle.writestr("omnicore-runtime/LICENSE", "MIT")
            bundle.writestr("omnicore-runtime/THIRD_PARTY_NOTICES.md", "Third-party terms")
            bundle.writestr("omnicore-runtime/build-metadata.json", json.dumps(metadata))
        archive.with_name(f"{archive.name}.sigstore.json").write_text(
            '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}',
            encoding="utf-8",
        )
        return archive

    def test_generates_published_cpu_manifest_from_archive_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_cpu_archive(root)
            identity = (
                "https://github.com/zzw-2025/omnicore-prebuilt/"
                ".github/workflows/sign-release.yml@refs/tags/v0.1.0"
            )
            manifest = MODULE.prepare_manifest(
                root,
                "v0.1.0",
                "cosign-keyless",
                identity,
                "https://token.actions.githubusercontent.com",
            )
            schema = json.loads(
                (Path(__file__).parents[1] / "manifest.schema.json").read_text(encoding="utf-8")
            )
            jsonschema.Draft202012Validator(schema).validate(manifest)
            catalog = EMIT_MODULE.render(manifest)
            artifact = manifest["artifacts"][0]
            self.assertEqual(manifest["status"], "published")
            self.assertEqual(artifact["backendId"], "omnicore-cpu")
            self.assertEqual(artifact["sizeBytes"], archive.stat().st_size)
            self.assertEqual(artifact["sourceCommit"], "a" * 40)
            self.assertIn("llama-server.exe", artifact["requiredFiles"])
            self.assertTrue(artifact["assetUrl"].endswith(f"/v0.1.0/{archive.name}"))
            self.assertEqual(artifact["signature"]["certificateIdentity"], identity)
            self.assertEqual(
                catalog["platforms"]["windows"]["omnicore-cpu"]["sha256"],
                artifact["sha256"],
            )

    def test_rejects_missing_signature_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_cpu_archive(root)
            archive.with_name(f"{archive.name}.sigstore.json").unlink()
            with self.assertRaisesRegex(ValueError, "Sigstore bundle is missing"):
                MODULE.prepare_manifest(
                    root,
                    "v0.1.0",
                    "cosign-keyless",
                    "workflow identity",
                    "https://token.actions.githubusercontent.com",
                )

    def test_generates_unsigned_manifest_when_explicitly_selected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_cpu_archive(root)
            archive.with_name(f"{archive.name}.sigstore.json").unlink()
            manifest = MODULE.prepare_manifest(root, "v0.1.0", "none")
            schema = json.loads(
                (Path(__file__).parents[1] / "manifest.schema.json").read_text(
                    encoding="utf-8"
                )
            )
            jsonschema.Draft202012Validator(schema).validate(manifest)
            self.assertNotIn("signature", manifest["artifacts"][0])

    def test_generates_minisign_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_cpu_archive(root)
            archive.with_name(f"{archive.name}.sigstore.json").unlink()
            archive.with_name(f"{archive.name}.minisig").write_text(
                "untrusted comment: signature\ntest\n", encoding="utf-8"
            )
            manifest = MODULE.prepare_manifest(
                root, "v0.1.0", "minisign", public_key_id="release-key-1"
            )
            signature = manifest["artifacts"][0]["signature"]
            self.assertEqual(signature["algorithm"], "minisign")
            self.assertEqual(signature["publicKeyId"], "release-key-1")

    def test_rejects_filename_metadata_contract_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_cpu_archive(root, backend_id="omnicore-cuda")
            with self.assertRaisesRegex(ValueError, "metadata backendId"):
                MODULE.prepare_manifest(root, "v0.1.0", "none")


if __name__ == "__main__":
    unittest.main()
