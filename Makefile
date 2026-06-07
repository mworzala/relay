# Relay — build automation.
# `make` regenerates the Xcode project from project.yml, builds, and can launch.

SCHEME       := Relay
CONFIG       := Debug
PROJECT      := Relay.xcodeproj
DERIVED      := build
APP          := $(DERIVED)/Build/Products/$(CONFIG)/Relay.app
RELEASE_APP  := $(DERIVED)/Build/Products/Release/Relay.app
DEST         := platform=macOS,arch=arm64

.PHONY: all generate build test run launch clean reset open xcode install

all: build

## generate: (re)create Relay.xcodeproj from project.yml via XcodeGen
generate:
	xcodegen generate

## build: generate then compile the app
build: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination '$(DEST)' \
		-derivedDataPath $(DERIVED) \
		build

## test: generate then run the unit tests (RelayTests, hosted by Relay)
test: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination '$(DEST)' \
		-derivedDataPath $(DERIVED) \
		test

## install: build the RELEASE variant and install it to /Applications.
## This is the "real" app (bundle id com.mattworzala.Relay, "Relay", state dir Relay/) —
## distinct from the Debug/dev build (com.mattworzala.Relay.dev, "Relay Dev", Relay-Dev/),
## so the two coexist without fighting over TCC grants or settings. Grant
## Microphone + Accessibility to the installed copy on first launch.
install: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination '$(DEST)' \
		-derivedDataPath $(DERIVED) \
		build
	rm -rf /Applications/Relay.app
	cp -R "$(RELEASE_APP)" /Applications/Relay.app
	@echo "Installed /Applications/Relay.app (com.mattworzala.Relay)."

## run: build then launch the app via Finder (detached; no console logs)
run: build launch

## launch: open the already-built .app
launch:
	open "$(APP)"

## xcode: run the built binary directly so logs print to this terminal
xcode: build
	"$(APP)/Contents/MacOS/Relay"

## debug-run: run in debug mode — diagnostics strip above the pill (target app,
## injection mode, manual-AX flag, prefix length, mic) plus injector tracing to
## this terminal. RELAY_DEBUG implies the legacy RELAY_DEBUG_INJECT (tracing only).
debug-run: build
	RELAY_DEBUG=1 "$(APP)/Contents/MacOS/Relay"

## open: open the generated project in Xcode
open: generate
	open $(PROJECT)

## clean: remove build output and the generated project
clean:
	rm -rf $(DERIVED) $(PROJECT)

## reset: clean plus SwiftPM caches (forces a fresh dependency resolve)
reset: clean
	rm -rf ~/Library/Developer/Xcode/DerivedData/Relay-* .swiftpm
