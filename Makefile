# tiespace -- a TUI client for the Cyberspace API (FPC)

FPC   ?= fpc

# Directory holding gcc's C runtime objects (crtbeginS.o etc.); FPC's linker
# needs it and can't find it on its own on some distros. Empty if gcc is absent.
CRTDIR := $(dir $(shell gcc -print-file-name=crtbeginS.o 2>/dev/null))

# -vw shows real warnings. Two benign messages are hidden by number:
#   5093 "managed-type function result not initialised" (auto-initialised by FPC)
#   6058 "call to inline subroutine not inlined" (ncurses' mvaddstr binding)
FLAGS  = -Mobjfpc -Sh -O2 -vw -vm5093,6058 \
         -Fusrc/net -Fusrc/app -Fusrc/api -Fusrc/model -Fusrc/ui -FUbuild \
         $(if $(CRTDIR),-Fl$(CRTDIR))
BIN    = bin

.PHONY: all app version spike session test clean dirs appdir appimage appimage-release

# Targets share the build/ unit-output dir, so a parallel build (make -jN) could
# race two fpc runs compiling the same units. Builds are sub-second; serialise.
.NOTPARALLEL:

all: app test

app: version dirs
	$(FPC) $(FLAGS) -o$(BIN)/tiespace src/tiespace.pas

# Stamp src/app/version.inc (a Pascal string literal CsVersion includes) from
# git, so a local build reports e.g. 'v0.11' or 'v0.11-3-gabc1234' instead of
# 'dev'. version.inc is generated/untracked, so this never dirties the tree.
# When git is unavailable (the release container) the file is left as-is — the
# CI workflow pre-stamps it with the clean release tag — and only written as a
# 'dev' fallback if it's somehow missing entirely.
version:
	@if command -v git >/dev/null 2>&1 && git describe --tags --always >/dev/null 2>&1; then \
		printf "'%s'\n" "$$(git describe --tags --always)" > src/app/version.inc; \
	elif [ ! -f src/app/version.inc ]; then \
		printf "'dev'\n" > src/app/version.inc; \
	fi

spike: dirs
	$(FPC) $(FLAGS) -o$(BIN)/spike_login src/spikes/spike_login.pas

session: dirs
	$(FPC) $(FLAGS) -o$(BIN)/session_test src/spikes/session_test.pas

# Pure-function unit tests (no network, no terminal). Builds and runs them;
# the binary exits non-zero if any assertion fails, so this fails the build too.
test: dirs
	$(FPC) $(FLAGS) -o$(BIN)/testsuite tests/testsuite.pas
	./$(BIN)/testsuite

dirs:
	@mkdir -p $(BIN) build

clean:
	rm -rf build $(BIN)

# --- AppImage packaging (see packaging/appimage/) ---------------------------
# `make appdir`  -> packaging/tiespace.AppDir (binary + bundled OpenSSL/ncursesw)
# `make appimage`-> dist/tiespace-x86_64.AppImage using *host* libraries — quick,
#                   but NOT portable (inherits this machine's glibc). For a
#                   portable release, build in the old-glibc container instead:
# `make appimage-release` -> portable dist/tiespace-x86_64.AppImage via Docker.
appdir: app
	packaging/appimage/bundle.sh

appimage: appdir
	@mkdir -p dist
	@if command -v appimagetool >/dev/null 2>&1; then \
		ARCH=x86_64 appimagetool packaging/tiespace.AppDir dist/tiespace-x86_64.AppImage && \
		echo "built dist/tiespace-x86_64.AppImage (host glibc — not portable)"; \
	else \
		echo "appimagetool not on PATH — AppDir is ready at packaging/tiespace.AppDir/."; \
		echo "Install appimagetool, or use 'make appimage-release' (Docker)."; \
	fi

appimage-release:
	docker build -t tiespace-appimage-builder - < packaging/appimage/Dockerfile
	docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp \
		-v "$$PWD":/src -w /src tiespace-appimage-builder
