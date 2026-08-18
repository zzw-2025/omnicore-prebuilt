# OmniCore prebuilt runtimes

This repository defines the publication contract for OmniCore runtime binaries used by OmniInfer and OmniStudio. Binary archives belong in GitHub Release assets, not in the Git tree.

## Current status

`manifest.json` records the latest reviewed Release metadata. An artifact must not
be added until its archive has been built on the target platform, smoke-tested,
uploaded, and assigned a final SHA-256 digest.

Stable backend IDs and initial publication targets:

| Backend ID | Platform | Architecture | Accelerator | Intended asset name |
|---|---|---|---|---|
| `omnicore-cpu` | Windows | x86_64 | CPU | `omnicore-<version>-windows-x86_64-cpu.zip` |
| `omnicore-cuda` | Windows | x86_64 | CUDA | `omnicore-<version>-windows-x86_64-cuda-<cuda-version>.zip` |
| `omnicore-metal` | macOS | arm64 | Metal | `omnicore-<version>-macos-arm64-metal.tar.gz` |

Windows CPU already has a verified preview Release. CUDA and Metal remain
publication targets until their native-platform gates pass.

## Publishing a downloadable release

The active release procedure is local and deliberately does not depend on
GitHub Actions:

1. choose an immutable OmniCore commit and an independent prebuilt version;
2. build each runtime on its native target platform with the scripts in this
   repository;
3. run the packaged real-model smoke test on that target platform;
4. create an unpublished draft Release using tag `v<version>` and upload every
   runtime archive plus its `.sha256` sidecar without renaming them;
5. run `scripts/finalize-release.ps1` from a maintainer workstation. The script
   downloads the draft assets, verifies the exact profile and checksums,
   optionally signs them with minisign, generates `release-manifest.json` and
   `omniinfer-catalog.json`, uploads the metadata, and publishes the draft;
6. review the generated manifest, update `manifest.json` through a normal
   commit, and merge the catalog fragment into OmniInfer only after its product
   entry point passes on a clean target machine.

`full` requires Windows CPU and macOS Metal archives and may also contain the
Windows CUDA archive. `windows-cpu-preview` requires exactly one Windows CPU
archive and a prerelease-marked draft.

Run a local validation without touching GitHub first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\finalize-release.ps1 `
  -Tag v<version> `
  -Profile <full-or-windows-cpu-preview> `
  -AssetsDir <path-to-local-runtime-assets>
```

For a signed Release, generate and protect a minisign key outside this
repository, then finalize the already-created draft:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\finalize-release.ps1 `
  -Tag v<version> `
  -Profile <full-or-windows-cpu-preview> `
  -SignatureMode minisign `
  -MinisignSecretKey <path-to-secret-key> `
  -MinisignPublicKey <path-to-public-key> `
  -PublicKeyId <stable-key-id> `
  -Publish
```

If the release owner explicitly accepts SHA-256-only integrity, use
`-SignatureMode none -AllowUnsignedPublish -Publish`. The second switch is a
deliberate safety acknowledgement; an unsigned draft cannot be published by
accident. A failed finalization remains a non-public draft, and an already
published Release is never modified.

Mark preview Releases as prereleases so they can be installed through an
OmniInfer integration branch before being promoted for general users. Creating
the Release does not by itself modify OmniInfer: merge the generated catalog
fragment into OmniInfer and validate its product entry point first.

CUDA remains a separate target gate because it requires Windows with a real
NVIDIA GPU and a matching CUDA toolkit. A published Release is immutable: if
CUDA was not included before publication, publish a new version instead of
adding it to an existing Release.

macOS uses OmniCore's native Metal backend. A Vulkan-labelled macOS package is
not part of this contract because it would require an additional MoltenVK and
Vulkan SDK dependency chain that OmniCore does not provide as its normal macOS
path.

## Reproducible builds

Build from a clean OmniCore checkout pinned to an immutable commit. The scripts
refuse a dirty source tree and write the exact source commit into the package.

From an x64 Visual Studio developer shell on Windows:

```powershell
.\scripts\build-windows.ps1 `
  -SourceDir <path-to-clean-omnicore-checkout> `
  -Version <release-version> `
  -Variant cpu
```

For CUDA, use `-Variant cuda -CudaVersion <cuda-version>` on a machine with a
supported CUDA toolkit. On Apple silicon:

```sh
bash ./scripts/build-macos.sh \
  --source-dir <path-to-clean-omnicore-checkout> \
  --version <release-version>
```

Artifacts are written to `dist/`. Windows archives include the MSVC CRT and
OpenMP redistributable DLLs required by the packaged static OmniCore server;
users do not need a Visual Studio installation.

The CUDA archive additionally includes the matching `cudart`, `cublas`, and
`cublasLt` runtime DLLs from the selected CUDA toolkit and requires a compatible
NVIDIA driver on the target machine. The default package compiles CUDA
architectures `75;80;86;89;90`; changing that list changes the hardware
compatibility contract and requires a separately reviewed Release. The CUDA target gate
must run the extracted server on a clean GPU host so missing transitive toolkit
dependencies cannot pass publication merely because they existed on the build
machine.

Run the packaged real-model smoke gate after building. The scripts download a
pinned tiny GGUF, verify its SHA-256, start the extracted package launcher, and
require both `/health` and one `/v1/chat/completions` response with token usage:

```powershell
.\scripts\smoke-windows.ps1 `
  -ArchivePath .\dist\omnicore-<version>-windows-x86_64-cpu.zip
```

```sh
bash ./scripts/smoke-macos.sh \
  ./dist/omnicore-<version>-macos-arm64-metal.tar.gz
```

Use `-RequireCuda` for the Windows CUDA archive. That gate additionally
requires a real CUDA device to be listed; a CPU fallback does not pass. Run
these smoke scripts manually on every release candidate; a launcher that merely
answers `--version` is insufficient for publication.

The initial manifest advertises only `chat` and `stream`, which are exercised
by the packaged-runtime smoke tests. Do not add `vision` until the corresponding
Release package passes an image-plus-projector request through the product
entry point.

## Integration contract

Each archive must contain `llama-server.exe` on Windows or `llama-server` on macOS together with every runtime library needed on a clean target machine. The launcher and its adjacent dependencies are installed into `<runtime-root>/<backend-id>/bin/` by OmniInfer.

Before publishing an artifact:

1. Build from an immutable OmniCore commit and record that commit in `manifest.json`.
2. Run the launcher smoke test on the target platform (`--version` and `--list-devices` where supported).
3. Test model load and one inference request through the packaged launcher, not the build-tree binary.
4. Upload the archive as a versioned GitHub Release asset in this repository;
   never reuse its tag or replace an uploaded runtime archive.
5. Record the final asset URL, byte size, SHA-256, launcher, and required files in `manifest.json`.
6. Add the same verified URL and SHA-256 to OmniInfer's compiled prebuilt catalog and register the backend ID there.
7. Validate discovery with `omniinfer advisor system --json`, then install through `omniinfer backend install <backend-id> --json` on a clean machine.

Minisign is the supported local signature mode. Keep the secret key outside the
repository and back it up according to the release owner's key-management
policy. The public key ID in the manifest must remain stable for the lifetime
of that key. SHA-256 remains mandatory with or without a signature.

Release `v0.1.0-preview.1` was signed by the former GitHub Actions keyless
workflow. Its historical Sigstore metadata remains valid and supported by the
manifest/catalog parsers; removing the workflow does not rewrite that Release.

After the signed Release metadata has been written to `manifest.json`, render
the exact OmniInfer schema-v6 source and platform entries with:

```sh
python scripts/emit-omniinfer-catalog.py --manifest manifest.json
```

The renderer refuses draft manifests, noncanonical URLs, invalid hashes,
malformed signature metadata, mixed source commits, and mixed Release tags.
Merge its output into OmniInfer only after the target-platform gates have
passed.

`manifest.json` is publication metadata. The current OmniInfer installer does not fetch this manifest remotely; it uses the catalog compiled into the OmniInfer CLI. This separation prevents an unpublished or partially uploaded asset from appearing in OmniStudio.

See [docs/package-contract.md](docs/package-contract.md) for archive and verification details. `manifest.schema.json` is the machine-readable schema for release metadata.
