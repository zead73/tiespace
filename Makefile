# tiespace -- a TUI client for the Cyberspace API (FPC)

FPC   ?= fpc
FLAGS  = -Mobjfpc -Sh -O2 -vn -viwn- \
         -Fusrc/net -Fusrc/app -Fusrc/api -Fusrc/model -Fusrc/ui -FUbuild
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
