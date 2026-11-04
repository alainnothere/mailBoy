# mailBoy build entry points. Everything wraps lazbuild.
#
#   make build          debug builds of the GUI and the CLI twin  -> bin/
#   make test           build, run the FPCUnit suite, run the shell smoke test
#   make release        optimised, stripped Linux builds           -> bin/mailboy, bin/mailboy-cli
#   make release-win64  same for Windows, cross-compiled            -> bin/mailboy.exe, bin/mailboy-cli.exe
#   make all            every binary above, release, both targets
#   make dist           all + the Windows portable zip              -> dist/mailboy-<ver>-win64-portable.zip
#
# Windows cross-compiling on Debian/Ubuntu needs only distro packages:
#   apt install binutils-mingw-w64-x86-64 fp-units-win-rtl-3.2.2 fp-units-win-base-3.2.2 \
#               fp-units-win-fcl-3.2.2 fp-units-win-misc-3.2.2
# and FPC-named links to the mingw tools:
#   for t in as ld strip windres dlltool objcopy ar; do
#     sudo ln -sf /usr/bin/x86_64-w64-mingw32-$t /usr/local/bin/x86_64-win64-$t; done
LAZBUILD ?= lazbuild
BIN      := bin
DIST     := dist
WIN      := --os=win64 --cpu=x86_64 --ws=win32
# Single source of truth for the version is MailBoyVersion in src/cli/mbcli.pas.
VERSION  := $(shell sed -n "s/.*MailBoyVersion *= *'\([^']*\)'.*/\1/p" src/cli/mbcli.pas)
PORTABLE := mailboy-$(VERSION)-win64-portable

.PHONY: build release release-win64 all dist test clean examples

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

all: release release-win64 examples

# One zip, two exes, the docs a stranger needs. Unzip anywhere, run, no
# installer, so the browser asks "are you sure" once instead of ten times.
dist: all
	rm -rf $(DIST)/$(PORTABLE) $(DIST)/$(PORTABLE).zip
	mkdir -p $(DIST)/$(PORTABLE)/examples
	cp $(BIN)/mailboy.exe $(BIN)/mailboy-cli.exe $(DIST)/$(PORTABLE)/
	cp README.md LICENSE $(DIST)/$(PORTABLE)/
	cp -r examples/hooks $(DIST)/$(PORTABLE)/examples/
	cd $(DIST) && zip -qr $(PORTABLE).zip $(PORTABLE)
	rm -rf $(DIST)/$(PORTABLE)
	@ls -l $(DIST)/$(PORTABLE).zip

test: build examples
	$(LAZBUILD) tests/mailboy_tests.lpi
	$(BIN)/mailboy_tests --all --format=plain
	sh tests/cli_smoke.sh
	BIN=$(BIN)/mailboy-cli sh tests/cli_smoke.sh
	sh tests/hook_examples.sh

clean:
	rm -rf lib tests/lib $(BIN)/* $(DIST)

# The Free Pascal example hook from examples/hooks, as a static binary -> bin/sign_rs256
examples:
	mkdir -p lib/examples $(BIN)
	fpc -Mobjfpc -Sh -O2 -Xs -XX -FUlib/examples -o$(BIN)/sign_rs256 examples/hooks/sign_rs256.pas
