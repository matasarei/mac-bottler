# wine-kitchen: build a standalone macOS app for a Windows game from a recipe.
# See README.md. make is the only entry point; scripts under core/ are internal.
#
#   make check                   verify the build prerequisites
#
# Targets arrive with the plan's steps (engine, prefix, helpers, app, test,
# compile, lint); until then they are not listed here.

.PHONY: help check

help:
	@sed -n '1,/^$$/p' Makefile | sed 's/^# \{0,1\}//'

check:
	@command -v swiftc >/dev/null || { echo "ERROR: swiftc not found: install the Xcode Command Line Tools (xcode-select --install)"; exit 1; }
	@command -v curl >/dev/null || { echo "ERROR: curl not found"; exit 1; }
	@command -v i686-w64-mingw32-gcc >/dev/null || { echo "ERROR: i686-w64-mingw32-gcc not found: brew install mingw-w64 (builds the small Windows helpers)"; exit 1; }
	@echo "==> prerequisites OK"
