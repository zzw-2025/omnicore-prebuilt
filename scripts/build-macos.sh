#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --source-dir <clean-omnicore-checkout> --version <release-version>" >&2
}

SOURCE_DIR=""
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir) SOURCE_DIR=${2:-}; shift 2 ;;
    --version) VERSION=${2:-}; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$SOURCE_DIR" && -n "$VERSION" ]] || { usage; exit 2; }
[[ "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "invalid version" >&2; exit 2; }
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || {
  echo "the Metal package must be built on Apple silicon" >&2
  exit 1
}

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE_DIR=$(cd "$SOURCE_DIR" && pwd)
[[ -z $(git -C "$SOURCE_DIR" status --porcelain=v1) ]] || {
  echo "OmniCore source checkout is dirty" >&2
  exit 1
}
SOURCE_COMMIT=$(git -C "$SOURCE_DIR" rev-parse HEAD)
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid source commit" >&2; exit 1; }

WORK_ROOT="$REPO_ROOT/.work/macos"
BUILD_DIR="$WORK_ROOT/build-metal"
STAGE_PARENT="$WORK_ROOT/stage-metal"
STAGE_DIR="$STAGE_PARENT/omnicore-runtime"
DIST_DIR="$REPO_ROOT/dist"
rm -rf "$BUILD_DIR" "$STAGE_PARENT"
mkdir -p "$BUILD_DIR" "$STAGE_DIR" "$DIST_DIR"

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_CUDA=OFF \
  -DGGML_VULKAN=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_UI=OFF \
  -DLLAMA_USE_PREBUILT_UI=OFF
cmake --build "$BUILD_DIR" --config Release --target llama-server --parallel

SERVER=$(find "$BUILD_DIR" -type f -path '*/bin/llama-server' -perm -111 -print -quit)
[[ -n "$SERVER" ]] || { echo "llama-server was not produced" >&2; exit 1; }
cp "$SERVER" "$STAGE_DIR/llama-server"
cp "$SOURCE_DIR/LICENSE" "$STAGE_DIR/LICENSE"
cp "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$STAGE_DIR/THIRD_PARTY_NOTICES.md"
cat > "$STAGE_DIR/build-metadata.json" <<EOF
{
  "formatVersion": 1,
  "backendId": "omnicore-metal",
  "sourceRepository": "https://github.com/omnimind-ai/OmniCore",
  "sourceCommit": "$SOURCE_COMMIT",
  "platform": "macos",
  "architecture": "arm64",
  "accelerator": "metal",
  "buildSharedLibraries": false,
  "metalLibraryEmbedded": true
}
EOF

"$STAGE_DIR/llama-server" --version
ASSET_NAME="omnicore-$VERSION-macos-arm64-metal.tar.gz"
ASSET_PATH="$DIST_DIR/$ASSET_NAME"
COPYFILE_DISABLE=1 tar -C "$STAGE_PARENT" -czf "$ASSET_PATH" omnicore-runtime
DIGEST=$(shasum -a 256 "$ASSET_PATH" | awk '{print $1}')
printf '%s  %s\n' "$DIGEST" "$ASSET_NAME" > "$ASSET_PATH.sha256"
printf '{"backendId":"omnicore-metal","asset":"%s","sizeBytes":%s,"sha256":"%s","sourceCommit":"%s"}\n' \
  "$ASSET_PATH" "$(stat -f %z "$ASSET_PATH")" "$DIGEST" "$SOURCE_COMMIT"
