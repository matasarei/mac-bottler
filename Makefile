# mac-bottler: build a standalone macOS app for a Windows game from a recipe.
# See README.md. make is the only entry point; scripts under core/ are internal.
#
#   make check                   verify the build prerequisites
#   make project NAME=<n> RECIPE=<recipe> GAME=<folder>   a new project (projects/<n>/)
#   make app PROJECT=<n>         build projects/<n>/<title>.app with the game inside
#   make engine APP=<app> [ENGINE=<name>]   install a pinned Wine engine (engines/)
#   make prefix APP=<app>        create the app's Wine prefix
#   make helpers                 build the Windows helpers into build/win/
#   make test                    hermetic tests (synthetic PE files, no game data, no wine)
#   make compile                 type-check the Swift sources
#   make lint                    shellcheck the scripts (error level)
#   make check-pins              every pinned download still exists with its SHA256
#
# Targets arrive with the plan's steps (engine, prefix, helpers, app, test,
# compile, lint); until then they are not listed here.

APP    ?= build/bottler-test.app
ENGINE ?= crossover-23
RES     = $(APP)/Contents/Resources
DEPS    = build/deps

.PHONY: help check project app engine prefix helpers test compile lint check-pins

help:
	@sed -n '1,/^$$/p' Makefile | sed 's/^# \{0,1\}//'

check:
	@command -v swiftc >/dev/null || { echo "ERROR: swiftc not found: install the Xcode Command Line Tools (xcode-select --install)"; exit 1; }
	@command -v curl >/dev/null || { echo "ERROR: curl not found"; exit 1; }
	@command -v i686-w64-mingw32-gcc >/dev/null || { echo "ERROR: i686-w64-mingw32-gcc not found: brew install mingw-w64 (builds the small Windows helpers)"; exit 1; }
	@command -v 7zz >/dev/null || { echo "ERROR: 7zz not found: brew install sevenzip (unpacks the Wine engine)"; exit 1; }
	@echo "==> prerequisites OK"

engine:
	@core/engine.sh "$(ENGINE)" "$(RES)" "$(DEPS)"

prefix: engine
	@core/prefix.sh "$(RES)"

test:
	@bash tests/run-tests.sh

helpers:
	@mkdir -p build/win
	@i686-w64-mingw32-gcc -O2 -mwindows -o build/win/bottler-place.exe win/place.c
	@echo "==> build/win/bottler-place.exe"

project:
	@[ -n "$(NAME)" ] && [ -n "$(RECIPE)" ] && [ -n "$(GAME)" ] || { echo "usage: make project NAME=<n> RECIPE=<recipe> GAME=<folder>"; exit 2; }
	@core/project.sh "$(NAME)" "$(RECIPE)" "$(GAME)"

app:
	@[ -n "$(PROJECT)" ] || { echo "usage: make app PROJECT=<name>"; exit 2; }
	@core/build-app.sh "projects/$(PROJECT)"

compile:
	@swiftc -typecheck tools/bottler.swift
	@swiftc -typecheck -parse-as-library core/launcher/Launcher.swift core/launcher/Decision.swift
	@echo "==> Swift sources type-check"

lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck not found: brew install shellcheck"; exit 1; }
	@shellcheck -S error core/*.sh win/*.sh tests/*.sh && echo "==> shellcheck: no errors"

check-pins:
	@bash core/check-pins.sh
