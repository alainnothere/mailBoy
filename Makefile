# mailBoy build entry points. Everything wraps lazbuild.
#
#   make build          debug builds of the GUI and the CLI twin  -> bin/
#   make test           build, run the FPCUnit suite, run the shell smoke test
#   make release        optimised, stripped Linux builds           -> bin/mailboy, bin/mailboy-cli
#   make release-win64  same for Windows, cross-compiled            -> bin/mailboy.exe, bin/mailboy-cli.exe
#
# Windows cross-compiling on Debian/Ubuntu needs only distro packages:
#   apt install binutils-mingw-w64-x86-64 fp-units-win-rtl-3.2.2 fp-units-win-base-3.2.2 \
#               fp-units-win-fcl-3.2.2 fp-units-win-misc-3.2.2
# and FPC-named links to the mingw tools:
#   for t in as ld strip windres dlltool objcopy ar; do
#     sudo ln -sf /usr/bin/x86_64-w64-mingw32-$t /usr/local/bin/x86_64-win64-$t; done
LAZBUILD ?= lazbuild
BIN      := bin
WIN      := --os=win64 --cpu=x86_64 --ws=win32

.PHONY: build release release-win64 test clean examples

build:
	$(LAZBUILD) --build-mode=Debug mailboy.lpi
	$(LAZBUILD) --build-mode=Debug mailboy_cli.lpi

release:
	$(LAZBUILD) --build-mode=Release mailboy.lpi
	$(LAZBUILD) --build-mode=Release mailboy_cli.lpi
	@ls -l $(BIN)/mailboy $(BIN)/mailboy-cli

release-win64:
	$(LAZBUILD) $(WIN) --build-mode=Release mailboy.lpi
	$(LAZBUILD) $(WIN) --build-mode=Release mailboy_cli.lpi
	@ls -l $(BIN)/mailboy.exe $(BIN)/mailboy-cli.exe

test: build examples
	$(LAZBUILD) tests/mailboy_tests.lpi
	$(BIN)/mailboy_tests --all --format=plain
	sh tests/cli_smoke.sh
	BIN=$(BIN)/mailboy-cli sh tests/cli_smoke.sh
	sh tests/hook_examples.sh

clean:
	rm -rf lib tests/lib $(BIN)/*

# The Free Pascal example hook from examples/hooks, as a static binary -> bin/sign_rs256
examples:
	mkdir -p lib/examples $(BIN)
	fpc -Mobjfpc -Sh -O2 -Xs -XX -FUlib/examples -o$(BIN)/sign_rs256 examples/hooks/sign_rs256.pas
