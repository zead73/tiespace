#!/usr/bin/env bash
# Assemble packaging/tiespace.AppDir: bin/tiespace plus the non-system shared
# libraries it needs.
#
# OpenSSL is dlopen'd at runtime (so it never appears in the binary's ldd) — it's
# added explicitly, with the unversioned libssl.so/libcrypto.so aliases that
# FPC's OpenSSL unit asks for. glibc / libm / the dynamic loader are deliberately
# NOT bundled (they must come from the host); terminfo is left to the host's
# universal /usr/share/terminfo.
#
# Run this INSIDE the old-glibc build environment (see Dockerfile) so the bundled
# libraries carry a low glibc floor — that, not the tooling, is what makes the
# AppImage portable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/packaging/appimage"
APPDIR="$ROOT/packaging/tiespace.AppDir"
BIN="$ROOT/bin/tiespace"
LIBDIR="$APPDIR/usr/lib"

[ -x "$BIN" ] || { echo "missing $BIN — run 'make app' first" >&2; exit 1; }

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$LIBDIR"
cp "$BIN" "$APPDIR/usr/bin/tiespace"

is_system() { # libs tied to the kernel/glibc — always host-provided
  case "$1" in
    libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|ld-linux*|linux-vdso*) return 0 ;;
    *) return 1 ;;
  esac
}
deps()    { ldd "$1" 2>/dev/null | awk '/=>/ {print $3} !/=>/ && /^\// {print $1}'; }
findlib() { ldconfig -p 2>/dev/null | awk -v n="$1" '$1==n {print $NF; exit}'; }

# OpenSSL 3, resolved via the loader cache (handles /usr/lib vs /usr/lib64).
SSL="$(findlib libssl.so.3)"
CRYPTO="$(findlib libcrypto.so.3)"
[ -n "$SSL" ] && [ -n "$CRYPTO" ] || {
  echo "OpenSSL 3 (libssl.so.3 / libcrypto.so.3) not found on this system." >&2
  echo "Build in an environment that ships OpenSSL 3 (e.g. the provided Dockerfile)." >&2
  exit 1
}
cp -Lv "$SSL" "$LIBDIR/libssl.so.3"
cp -Lv "$CRYPTO" "$LIBDIR/libcrypto.so.3"
ln -sf libssl.so.3 "$LIBDIR/libssl.so"       # FPC 3.2.2 asks for the unversioned
ln -sf libcrypto.so.3 "$LIBDIR/libcrypto.so" # name; provide it.

for seed in "$BIN" "$SSL" "$CRYPTO"; do
  for dep in $(deps "$seed"); do
    base="$(basename "$dep")"
    is_system "$base" && continue
    [ -e "$LIBDIR/$base" ] && continue
    [ -e "$dep" ] && cp -Lv "$dep" "$LIBDIR/$base"
  done
done

install -m 755 "$SRC/AppRun" "$APPDIR/AppRun"
install -m 644 "$SRC/tiespace.desktop" "$APPDIR/tiespace.desktop"
install -m 644 "$SRC/tiespace.png" "$APPDIR/tiespace.png"
chmod +x "$APPDIR/usr/bin/tiespace"

echo "AppDir ready: $APPDIR"
echo "bundled libs:"; ls -1 "$LIBDIR"
