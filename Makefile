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

.PHONY: all app spike session test clean dirs

# Targets share the build/ unit-output dir, so a parallel build (make -jN) could
# race two fpc runs compiling the same units. Builds are sub-second; serialise.
.NOTPARALLEL:

all: app test

app: dirs
	$(FPC) $(FLAGS) -o$(BIN)/tiespace src/tiespace.pas

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
