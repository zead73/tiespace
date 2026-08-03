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

.PHONY: all app spike session clean dirs

all: app

app: dirs
	$(FPC) $(FLAGS) -o$(BIN)/cyberspace src/cyberspace.pas

spike: dirs
	$(FPC) $(FLAGS) -o$(BIN)/spike_login src/spikes/spike_login.pas

session: dirs
	$(FPC) $(FLAGS) -o$(BIN)/session_test src/spikes/session_test.pas

dirs:
	@mkdir -p $(BIN) build

clean:
	rm -rf build $(BIN)
