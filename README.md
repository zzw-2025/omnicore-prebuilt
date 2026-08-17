# OmniCore prebuilt runtimes

This repository defines the publication contract for OmniCore runtime binaries used by OmniInfer and OmniStudio. Binary archives belong in GitHub Release assets, not in the Git tree.

## Current status

`manifest.json` is intentionally empty while the first verified Release artifacts are being prepared. An artifact must not be added until its archive has been built on the target platform, smoke-tested, uploaded, and assigned a final SHA-256 digest.

Stable backend IDs and initial publication targets:

| Backend ID | Platform | Architecture | Accelerator | Intended asset name |
|---|---|---|---|---|
| `omnicore-cpu` | Windows | x86_64 | CPU | `omnicore-<version>-windows-x86_64-cpu.zip` |
| `omnicore-cuda` | Windows | x86_64 | CUDA | `omnicore-<version>-windows-x86_64-cuda-<cuda-version>.zip` |
| `omnicore-metal` | macOS | arm64 | Metal | `omnicore-<version>-macos-arm64-metal.tar.gz` |

These are publication targets, not claims that the artifacts already exist.

## Publishing a downloadable release

Use the **Build and publish prebuilt release** workflow and provide an immutable
OmniCore source commit plus a version without the `v` prefix. The workflow:

1. builds Windows x86_64 CPU and macOS arm64 Metal packages on their native
   GitHub-hosted runners;
2. runs each packaged runtime against the pinned real-model smoke test;
3. verifies archive SHA-256 sidecars and creates an unpublished draft Release;
4. triggers the signing workflow, which signs every runtime archive with
   GitHub OIDC and verifies each generated Sigstore bundle;
5. derives `release-manifest.json` from the archive's embedded build metadata
   and the final Release assets, then renders `omniinfer-catalog.json`;
6. uploads both metadata files, publishes the verified draft as a versioned
   GitHub Release, and opens a pull request updating `manifest.json`.

If signing, verification, or metadata generation fails, the Release remains a
non-public draft. The signing workflow refuses to modify an already-published
Release, so a failed or superseded build must use a new version instead of
replacing public assets.

The first release defaults to a prerelease so it can be installed through an
OmniInfer integration branch before being promoted for general users. Creating
the Release does not by itself modify OmniInfer: merge the generated catalog
fragment into OmniInfer and validate its product entry point first.

CUDA remains a separate **Build CUDA prebuilt runtime** workflow because its
publication gate requires a self-hosted Windows runner with a real NVIDIA GPU.
Upload a CUDA archive to a Release only after that workflow passes; rerun the
signing workflow for the tag to regenerate signed metadata containing it.

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
requires a real CUDA device to be listed; a CPU fallback does not pass. The
same smoke scripts run in the target-platform build workflows, so a launcher
that merely answers `--version` is insufficient for publication.

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

Sign published assets with the repository's keyless cosign workflow. A local
build may have a real SHA-256 but is not a published artifact until its Sigstore
bundle exists and the target-platform gates have passed.

To verify a published archive, use the bundle uploaded beside it:

```sh
cosign verify-blob \
  --bundle <archive>.sigstore.json \
  --certificate-identity-regexp '^https://github.com/zzw-2025/omnicore-prebuilt/.github/workflows/sign-release.yml@refs/(heads/main|tags/[^/]+)$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  <archive>
```

The signing workflow is intentionally separate from building. The explicit
publish workflow creates a draft first, and only the signing workflow can turn
that verified draft into a public Release. CI builds and pull requests cannot
silently create public runtime assets.

The repository setting **Allow GitHub Actions to create and approve pull
requests** must be enabled for the automatic manifest-update PR. If policy
disables it, the signed `release-manifest.json` and `omniinfer-catalog.json`
remain attached to the Release, but a maintainer must update `manifest.json`
through a normal reviewed PR.

After the signed Release metadata has been written to `manifest.json`, render
the exact OmniInfer schema-v6 source and platform entries with:

```sh
python scripts/emit-omniinfer-catalog.py --manifest manifest.json
```

The renderer refuses draft manifests, noncanonical URLs, invalid hashes,
unsigned artifacts, mixed source commits, and mixed Release tags. Merge its
output into OmniInfer only after the target-platform gates have passed.

`manifest.json` is publication metadata. The current OmniInfer installer does not fetch this manifest remotely; it uses the catalog compiled into the OmniInfer CLI. This separation prevents an unpublished or partially uploaded asset from appearing in OmniStudio.

See [docs/package-contract.md](docs/package-contract.md) for archive and verification details. `manifest.schema.json` is the machine-readable schema for release metadata.
