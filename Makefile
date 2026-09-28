# wine-kitchen: build a standalone macOS app for a Windows game from a recipe.
# See README.md. make is the only entry point; scripts under core/ are internal.
#
#   make check                   verify the build prerequisites
#   make engine APP=<app> [ENGINE=<name>]   install a pinned Wine engine (engines/)
#   make prefix APP=<app>        create the app's Wine prefix
#   make helpers                 build the Windows helpers into build/win/
#   make test                    hermetic tests (synthetic PE files, no game data, no wine)
#
# Targets arrive with the plan's steps (engine, prefix, helpers, app, test,
# compile, lint); until then they are not listed here.

APP    ?= build/kitchen-test.app
ENGINE ?= crossover-23
RES     = $(APP)/Contents/Resources
DEPS    = build/deps

.PHONY: help check engine prefix helpers test

help:
	@sed -n '1,/^$$/p' Makefile | sed 's/^# \{0,1\}//'

check:
	@command -v swiftc >/dev/null || { echo "ERROR: swiftc not found: install the Xcode Command Line Tools (xcode-select --install)"; exit 1; }
	@command -v curl >/dev/null || { echo "ERROR: curl not found"; exit 1; }
	@command -v i686-w64-mingw32-gcc >/dev/null || { echo "ERROR: i686-w64-mingw32-gcc not found: brew install mingw-w64 (builds the small Windows helpers)"; exit 1; }
	@echo "==> prerequisites OK"

engine:
	@core/engine.sh "$(ENGINE)" "$(RES)" "$(DEPS)"

prefix: engine
	@core/prefix.sh "$(RES)"

test:
	@bash tests/run-tests.sh

helpers:
	@mkdir -p build/win
	@i686-w64-mingw32-gcc -O2 -mwindows -o build/win/kitchen-place.exe win/place.c
	@echo "==> build/win/kitchen-place.exe"
