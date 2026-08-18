from __future__ import annotations

import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "validate-release-assets.py"
SPEC = importlib.util.spec_from_file_location("validate_release_assets", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def add_asset(root: Path, name: str, content: bytes = b"runtime") -> Path:
    archive = root / name
    archive.write_bytes(content)
    digest = hashlib.sha256(content).hexdigest()
    archive.with_name(f"{name}.sha256").write_text(
        f"{digest}  {name}\n", encoding="ascii"
    )
    return archive


class ValidateReleaseAssetsTests(unittest.TestCase):
    def test_accepts_exact_windows_cpu_preview(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            add_asset(root, "omnicore-0.1.0-preview.1-windows-x86_64-cpu.zip")
            archives = MODULE.validate_assets(
                root, "v0.1.0-preview.1", "windows-cpu-preview"
            )
            self.assertEqual(len(archives), 1)

    def test_preview_rejects_additional_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            add_asset(root, "omnicore-0.1.0-windows-x86_64-cpu.zip")
            add_asset(root, "omnicore-0.1.0-macos-arm64-metal.tar.gz")
            with self.assertRaisesRegex(ValueError, "exactly one Windows CPU"):
                MODULE.validate_assets(root, "v0.1.0", "windows-cpu-preview")

    def test_full_requires_windows_cpu_and_macos_metal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            add_asset(root, "omnicore-0.1.0-windows-x86_64-cpu.zip")
            with self.assertRaisesRegex(ValueError, "requires Windows CPU"):
                MODULE.validate_assets(root, "v0.1.0", "full")

    def test_rejects_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = add_asset(root, "omnicore-0.1.0-windows-x86_64-cpu.zip")
            archive.write_bytes(b"modified")
            with self.assertRaisesRegex(ValueError, "SHA-256 sidecar mismatch"):
                MODULE.validate_assets(root, "v0.1.0", "windows-cpu-preview")

    def test_rejects_wrong_release_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            add_asset(root, "omnicore-0.2.0-windows-x86_64-cpu.zip")
            with self.assertRaisesRegex(ValueError, "unexpected release asset name"):
                MODULE.validate_assets(root, "v0.1.0", "windows-cpu-preview")


if __name__ == "__main__":
    unittest.main()
