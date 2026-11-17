# Kan — build, install and test. `make help` lists the targets.
#
# First time:   make bootstrap signing app models install   (models first: Kan listens for calls at once)
# Day to day:   make app install                       (rebuild, replace the installed app, relaunch)
#
# Written for the GNU Make 3.81 that ships with macOS.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Passed through to the scripts; see each script's --help for details.
CONFIG ?= release
SIGN_MODE ?= selfsigned
HARDENED ?= 1
CLI ?= 0
INSTALL_FLAGS ?=
MODELS ?= --recommended
SUITES ?=
TEST_ARGS ?=
PROBE_ARGS ?= clients

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
TOOLS_DIR := .build/kan-tools

.PHONY: help bootstrap signing icon app install run test probe models clean

help: ## Show this help
	@echo "Usage: make <target> [VARIABLE=value …]"
	@echo
	@awk 'BEGIN { FS = ":.*## " } /^[a-z][a-z-]*:.*## / { printf "  %-10s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "Variables:"
	@echo "  CONFIG=release|debug            app build configuration (default release)"
	@echo "  SIGN_MODE=selfsigned|adhoc|none how to sign Kan.app (default selfsigned)"
	@echo "  HARDENED=0                      sign without the hardened runtime (troubleshooting only)"
	@echo "  CLI=1                           make install also links ~/.local/bin/kan"
	@echo "  INSTALL_FLAGS='--no-launch'     extra flags for scripts/install.sh"
	@echo "  MODELS='--minimal'              model set for make models (--recommended, --all, --only ID,…)"
	@echo "  SUITES='core agent'             test suites for make test (default: all)"
	@echo "  TEST_ARGS='--filter Library'    arguments for every test executable"
	@echo "  PROBE_ARGS=watch                arguments for kan-probe (default: clients)"

bootstrap: ## Build the whisper.cpp static libraries (once, and after a fresh clone)
	@scripts/bootstrap-whisper.sh

signing: ## Create the local code-signing identity (once per Mac)
	@scripts/setup-signing.sh

icon: ## Re-render Resources/AppIcon.icns from scripts/make-icon.swift
	@mkdir -p $(TOOLS_DIR)
	@swiftc -O scripts/make-icon.swift -o $(TOOLS_DIR)/make-icon
	@$(TOOLS_DIR)/make-icon --icns Resources/AppIcon.icns

app: ## Build and sign build/Kan.app
	@CONFIG=$(CONFIG) SIGN_MODE=$(SIGN_MODE) HARDENED=$(HARDENED) scripts/build-app.sh

install: ## Copy build/Kan.app to /Applications (or ~/Applications) and relaunch it
	@scripts/install.sh $(if $(filter 1,$(CLI)),--cli) $(INSTALL_FLAGS)

run: ## Open the installed Kan
	@app=""; \
	for dir in /Applications "$$HOME/Applications"; do \
	  if [ -d "$$dir/Kan.app" ]; then app="$$dir/Kan.app"; break; fi; \
	done; \
	if [ -z "$$app" ]; then echo "Kan isn't installed yet: make app install" >&2; exit 1; fi; \
	echo "open $$app"; open "$$app"

test: ## Build and run the kan-selftest-* suites
	@scripts/test.sh $(SUITES) $(if $(strip $(TEST_ARGS)),-- $(TEST_ARGS))

probe: ## List the apps using audio right now (kan-probe; PROBE_ARGS=watch to follow live)
	@swift build --product kan-probe
	@"$$(swift build --show-bin-path)/kan-probe" $(PROBE_ARGS)

models: ## Download the transcription models (resumable)
	@scripts/download-models.sh $(MODELS)

clean: ## Remove build products (swift package clean, build/); keeps the whisper libraries
	@if [ -d build/Kan.app ]; then $(LSREGISTER) -u build/Kan.app 2>/dev/null || true; fi
	swift package clean
	rm -rf build $(TOOLS_DIR)
