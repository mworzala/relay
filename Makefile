# Relay — build automation.
# `make` regenerates the Xcode project from project.yml, builds, and can launch.

SCHEME       := Relay
CONFIG       := Debug
PROJECT      := Relay.xcodeproj
DERIVED      := build
APP          := $(DERIVED)/Build/Products/$(CONFIG)/Relay.app
DEST         := platform=macOS,arch=arm64

.PHONY: all generate build run launch clean reset open xcode

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

## run: build then launch the app via Finder (detached; no console logs)
run: build launch

## launch: open the already-built .app
launch:
	open "$(APP)"

## xcode: run the built binary directly so logs print to this terminal
xcode: build
	"$(APP)/Contents/MacOS/Relay"

## debug-run: run with injector tracing (logs each keystroke edit to this terminal)
debug-run: build
	RELAY_DEBUG_INJECT=1 "$(APP)/Contents/MacOS/Relay"

## open: open the generated project in Xcode
open: generate
	open $(PROJECT)

## clean: remove build output and the generated project
clean:
	rm -rf $(DERIVED) $(PROJECT)

## reset: clean plus SwiftPM caches (forces a fresh dependency resolve)
reset: clean
	rm -rf ~/Library/Developer/Xcode/DerivedData/Relay-* .swiftpm
