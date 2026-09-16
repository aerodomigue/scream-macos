APP_NAME := ScreamBar
APP_VERSION := 1.2.0
BUNDLE_ID := com.screambar.app
BUILD_DIR := .build/release
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := /Applications
SIGNING_IDENTITY ?= ScreamBar Local Signing
SIGNING_KEYCHAIN := $(abspath .screambar-signing.keychain-db)

HOMEBREW_PREFIX := /opt/homebrew

LIBJACK := $(HOMEBREW_PREFIX)/opt/jack/lib/libjack.0.1.0.dylib
LIBSOXR := $(HOMEBREW_PREFIX)/opt/libsoxr/lib/libsoxr.0.dylib
LIBDB := $(HOMEBREW_PREFIX)/opt/berkeley-db@5/lib/libdb-5.3.dylib
LIBSAMPLERATE := $(HOMEBREW_PREFIX)/opt/libsamplerate/lib/libsamplerate.0.dylib

DYLIBS := $(LIBJACK) $(LIBSOXR) $(LIBDB) $(LIBSAMPLERATE)

.PHONY: help dev-run setup-signing check-signing build clean install

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

dev-run: ## Run in development mode
	swift run

setup-signing: ## Create or reuse the isolated project signing identity
	./scripts/setup-local-signing.sh

check-signing:
	@test "$(SIGNING_IDENTITY)" != "-" || { echo "Ad-hoc signing would invalidate permissions after updates." >&2; exit 1; }
	@./scripts/setup-local-signing.sh --check
	@security find-identity -p codesigning "$(SIGNING_KEYCHAIN)" | awk -v identity="$(SIGNING_IDENTITY)" \
		'$$2 == identity || index($$0, "\"" identity "\"") { found = 1 } END { exit !found }' \
		|| { echo 'Signing identity unavailable in the project keychain. Restore the project signing files.' >&2; exit 1; }

build: check-signing ## Build release .app bundle with a persistent signing identity
	swift build -c release

	@# Create .app bundle structure
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	mkdir -p $(APP_BUNDLE)/Contents/Frameworks

	@# Copy main executable
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/

	@# Copy scream binary
	cp scream $(APP_BUNDLE)/Contents/Resources/scream
	chmod +x $(APP_BUNDLE)/Contents/Resources/scream

	@# Copy application icon
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns

	@# Copy dylibs
	@for lib in $(DYLIBS); do \
		if [ -f "$$lib" ]; then \
			cp "$$lib" $(APP_BUNDLE)/Contents/Frameworks/; \
		else \
			echo "Warning: $$lib not found, skipping"; \
		fi \
	done

	@# Fix rpaths for scream binary
	install_name_tool -change $(LIBJACK) @executable_path/../Frameworks/libjack.0.1.0.dylib \
		$(APP_BUNDLE)/Contents/Resources/scream
	install_name_tool -change $(LIBSOXR) @executable_path/../Frameworks/libsoxr.0.dylib \
		$(APP_BUNDLE)/Contents/Resources/scream

	@# Fix rpaths for libjack (it depends on libdb and libsamplerate)
	install_name_tool -change $(LIBDB) @loader_path/libdb-5.3.dylib \
		$(APP_BUNDLE)/Contents/Frameworks/libjack.0.1.0.dylib
	install_name_tool -change $(LIBSAMPLERATE) @loader_path/libsamplerate.0.dylib \
		$(APP_BUNDLE)/Contents/Frameworks/libjack.0.1.0.dylib
	install_name_tool -id @rpath/libjack.0.1.0.dylib \
		$(APP_BUNDLE)/Contents/Frameworks/libjack.0.1.0.dylib
	install_name_tool -id @rpath/libsoxr.0.dylib \
		$(APP_BUNDLE)/Contents/Frameworks/libsoxr.0.dylib
	install_name_tool -id @rpath/libdb-5.3.dylib \
		$(APP_BUNDLE)/Contents/Frameworks/libdb-5.3.dylib
	install_name_tool -id @rpath/libsamplerate.0.dylib \
		$(APP_BUNDLE)/Contents/Frameworks/libsamplerate.0.dylib

	@# Re-sign after install_name_tool modifications
	codesign --force --keychain "$(SIGNING_KEYCHAIN)" -s "$(SIGNING_IDENTITY)" $(APP_BUNDLE)/Contents/Resources/scream
	codesign --force --keychain "$(SIGNING_KEYCHAIN)" -s "$(SIGNING_IDENTITY)" $(APP_BUNDLE)/Contents/Frameworks/*.dylib

	@# Generate Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $(BUNDLE_ID)" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundleName string $(APP_NAME)" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $(APP_NAME)" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $(APP_VERSION)" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $(APP_VERSION)" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string ScreamBar needs audio input access for Direct Routing." $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string ScreamBar uses your local network to wake computers and securely request shutdown from Host Daemon." $(APP_BUNDLE)/Contents/Info.plist

	@# Sign the completed bundle so macOS can associate TCC permissions with the app
	codesign --force --keychain "$(SIGNING_KEYCHAIN)" -s "$(SIGNING_IDENTITY)" $(APP_BUNDLE)
	codesign --verify --deep --strict $(APP_BUNDLE)

	@echo "Built $(APP_BUNDLE)"

clean: ## Clean build artifacts
	swift package clean
	rm -rf $(APP_BUNDLE)

install: build ## Install to /Applications
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"
