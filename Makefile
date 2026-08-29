APP_NAME := AskAI
BUNDLE   := dist/$(APP_NAME).app
INSTALLED := /Applications/$(APP_NAME).app

# XCTest ships only with full Xcode, so the suite uses swift-testing. SwiftPM
# normally finds Testing.framework via `xcrun --show-sdk-platform-path`, which
# fails on a Command Line Tools-only install -- so point at it explicitly.
# This is why you must run `make test`, not a bare `swift test`. See NOTES.md.
#
# -disable-cross-import-overlays: CLT ships _Testing_Foundation.framework with
# its binary but no Modules directory, so the Testing+Foundation cross-import
# overlay cannot be resolved and any file importing both fails to compile.
# Nothing this suite uses lives in that overlay.
DEV_FRAMEWORKS := $(shell xcode-select -p)/Library/Developer/Frameworks
TEST_FLAGS := -Xswiftc -F -Xswiftc $(DEV_FRAMEWORKS) \
              -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
              -Xlinker -F -Xlinker $(DEV_FRAMEWORKS) \
              -Xlinker -rpath -Xlinker $(DEV_FRAMEWORKS)

.PHONY: build test bundle run install uninstall clean entitlements services logs probe

build:
	swift build

test:
	swift test $(TEST_FLAGS)

bundle:
	@bash scripts/bundle.sh

# Launch the signed bundle. `swift run` is NOT a valid way to test this app:
# a loose binary has no Info.plist, no signature, hence no Services and no
# entitlements (PLAN.md appendix #10).
run: bundle
	@pkill -x $(APP_NAME) 2>/dev/null || true
	open $(BUNDLE)

# Launch Services only reliably scans a few locations; /Applications is one.
install: bundle
	@pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf $(INSTALLED)
	cp -R $(BUNDLE) $(INSTALLED)
	@echo "==> installed to $(INSTALLED)"

uninstall:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf $(INSTALLED)

entitlements: bundle
	codesign -d --entitlements - $(BUNDLE)

services:
	/System/Library/CoreServices/pbs -dump_pboard | grep -A 20 $(APP_NAME) || \
		echo "!! no $(APP_NAME) entry in the pbs dump"

logs:
	/usr/bin/log stream --predicate 'subsystem == "com.yourname.AskAI"' --info

clean:
	swift package clean
	rm -rf .build dist

# Fire the service from a separate process and report the resulting panel
# window + which app is actually frontmost. Verification without UI automation.
probe:
	@swift scripts/fire-service.swift "$(TEXT)"
