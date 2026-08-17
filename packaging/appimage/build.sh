#!/usr/bin/env bash
# Build a portable tiespace AppImage: compile, assemble the AppDir, package it.
#
# Run this INSIDE the old-glibc build environment (see Dockerfile) so the binary
# and bundled libraries get a low glibc floor. Needs fpc + ncursesw-dev, OpenSSL 3
# libs, and appimagetool on PATH — all provided by the Dockerfile.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ARCH="${ARCH:-x86_64}"
OUT="dist/tiespace-${ARCH}.AppImage"

make app
packaging/appimage/bundle.sh
mkdir -p dist
ARCH="$ARCH" appimagetool packaging/tiespace.AppDir "$OUT"

echo "built $OUT"
