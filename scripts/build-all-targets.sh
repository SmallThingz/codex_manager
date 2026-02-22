#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION_LABEL="${1:-all-targets}"
RELEASE_DIR="${2:-release/${VERSION_LABEL}}"
BUILD_ROOT=".zig-out-matrix/${VERSION_LABEL}"

TARGETS=(
  "x86_64-linux-gnu"
  "aarch64-linux-gnu"
  "x86_64-windows-gnu"
  "aarch64-windows-gnu"
  "x86_64-macos"
  "aarch64-macos"
)

mkdir -p "${RELEASE_DIR}"
mkdir -p "${BUILD_ROOT}"

echo "Building codex-manager for ${#TARGETS[@]} targets..."
for target in "${TARGETS[@]}"; do
  echo "==> ${target}"
  prefix="${BUILD_ROOT}/${target}"
  rm -rf "${prefix}"

  zig build install \
    --prefix "${prefix}" \
    -Doptimize=ReleaseFast \
    -Dportable_backend=true \
    -Dtarget="${target}"

  binary_name="codex-manager"
  case "${target}" in
    *windows*) binary_name="${binary_name}.exe" ;;
  esac

  output_dir="${RELEASE_DIR}/${target}"
  mkdir -p "${output_dir}"
  cp "${prefix}/bin/${binary_name}" "${output_dir}/${binary_name}"
done

echo "Done. Artifacts written to ${RELEASE_DIR}"
