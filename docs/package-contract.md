# Package contract

## Archive layout

OmniInfer locates the configured launcher anywhere in the extracted primary archive, then stages every file adjacent to that launcher into the backend runtime `bin` directory. Keep one unambiguous launcher in the archive and place all runtime dependencies beside it.

Windows example:

```text
omnicore-runtime/
  llama-server.exe
  msvcp140.dll
  vcomp140.dll
  vcruntime140.dll
  vcruntime140_1.dll
  <CUDA runtime DLLs for the CUDA variant>
  LICENSE
  THIRD_PARTY_NOTICES.md
  build-metadata.json
```

macOS example:

```text
omnicore-runtime/
  llama-server
  <required dylibs, if the build is not self-contained>
  LICENSE
  THIRD_PARTY_NOTICES.md
  build-metadata.json
```

Do not include source trees, object files, model files, build caches, absolute-path configuration, logs, credentials, or symbols that are not intentionally published.

The initial Windows packages use a static OmniCore/ggml build plus adjacent
MSVC CRT and OpenMP redistributables. At source commit
`093b52aa7838e2da0a2d2a73133c1bad895ce157`, an MSVC shared-library build fails
on conflicting TurboQuant export/linkage declarations (`C2375`/`C4273`). The
static layout avoids that source-side defect and reduces the runtime DLL
surface without disabling OpenMP. Re-evaluate the shared layout only after an
upstream source fix and a clean packaged-runtime dependency audit.

## Manifest fields

- `backendId` must match a registered OmniInfer backend and its compiled prebuilt catalog entry.
- `sourceRepository` and the exact 40-character `sourceCommit` identify the source tree used by the build; never infer identity from a local directory name.
- `runtimeVersion` records an accelerator runtime such as a CUDA toolkit version when relevant.
- `bootstrapCompatibility` bounds the OmniInfer versions allowed to install the artifact.
- `protocol` and `capabilities` describe the API surface exposed by the packaged launcher.
- `requiredFiles` lists dependencies that OmniInfer must verify after extraction in addition to the launcher.
- `runtimeDependencies` records target-machine dependencies that are intentionally not shipped in the archive.
- Windows packages are also governed by the Microsoft Visual Studio
  Redistributable terms; CUDA packages additionally carry the NVIDIA CUDA
  Toolkit EULA and require a compatible NVIDIA driver. Record these boundaries
  in the generated artifact metadata instead of representing the whole archive
  as MIT-only.
- `assetUrl`, `sizeBytes`, and `sha256` describe the final uploaded Release asset. Compute the digest after upload preparation; never use a placeholder hash.
- `signature` identifies either a keyless cosign Sigstore bundle and its expected
  GitHub Actions certificate identity/issuer, or a minisign asset and trusted
  public key. SHA-256 remains mandatory even when a signature is present.

The source repository and the Release-asset repository are intentionally
different: packages are built from `omnimind-ai/OmniCore` and published by this
repository. OmniInfer's catalog must preserve both identities instead of
pretending the Release tag is an OmniCore source tag.

## Target-platform gate

For every artifact, retain evidence for:

- clean extraction and SHA-256 match;
- packaged launcher startup on the declared OS and architecture;
- reported device/backend identity matching the declared accelerator;
- model load and a successful inference request through OmniInfer's product entry point;
- failure on a corrupted archive, a missing required file, and incompatible hardware;
- installation into a fresh runtime root with no dependency on the build workspace.

Publishing metadata is complete only after the OmniInfer catalog references the same versioned Release URL and digest and `advisor system` reports the backend as compatible and prebuilt-installable on the target machine. Never replace a runtime archive under an existing Release tag.
