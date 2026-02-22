#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

VERSION_LABEL="${1:-all-targets}"
RELEASE_DIR="${2:-release/${VERSION_LABEL}}"
BUILD_ROOT=".zig-out-matrix/${VERSION_LABEL}"

HOST_OS="$(uname -s)"
case "${HOST_OS}" in
  Linux)
    TARGETS=(
      "x86_64-linux-gnu"
      "aarch64-linux-gnu"
      "x86_64-windows-gnu"
      "aarch64-windows-gnu"
    )
    ;;
  Darwin)
    TARGETS=(
      "x86_64-macos"
      "aarch64-macos"
    )
    ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    TARGETS=(
      "x86_64-windows-gnu"
      "aarch64-windows-gnu"
    )
    ;;
  *)
    echo "Unsupported host OS for build matrix: ${HOST_OS}" >&2
    exit 1
    ;;
esac

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
    -Dtarget="${target}"

  binary_name="codex-manager"
  case "${target}" in
    *windows*) binary_name="${binary_name}.exe" ;;
  esac

  target_arch="${target%%-*}"
  target_rest="${target#*-}"
  target_os="${target_rest%%-*}"
  output_name="codex-manager-${target_os}-${target_arch}"
  cp "${prefix}/bin/${binary_name}" "${RELEASE_DIR}/${output_name}"
done

echo "Done. Artifacts written to ${RELEASE_DIR}"
