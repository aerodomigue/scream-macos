APP_NAME := ScreamBar
BUNDLE_ID := com.screambar.app
BUILD_DIR := .build/release
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := /Applications

HOMEBREW_PREFIX := /opt/homebrew

LIBJACK := $(HOMEBREW_PREFIX)/opt/jack/lib/libjack.0.1.0.dylib
LIBSOXR := $(HOMEBREW_PREFIX)/opt/libsoxr/lib/libsoxr.0.dylib
LIBDB := $(HOMEBREW_PREFIX)/opt/berkeley-db@5/lib/libdb-5.3.dylib
LIBSAMPLERATE := $(HOMEBREW_PREFIX)/opt/libsamplerate/lib/libsamplerate.0.dylib

DYLIBS := $(LIBJACK) $(LIBSOXR) $(LIBDB) $(LIBSAMPLERATE)

.PHONY: help dev-run build clean install

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

dev-run: ## Run in development mode
	swift run

build: ## Build release .app bundle
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
	codesign --force -s - $(APP_BUNDLE)/Contents/Resources/scream
	codesign --force -s - $(APP_BUNDLE)/Contents/Frameworks/*.dylib

	@# Generate Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $(BUNDLE_ID)" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundleName string $(APP_NAME)" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $(APP_NAME)" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1.0.0" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0.0" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" $(APP_BUNDLE)/Contents/Info.plist

	@echo "Built $(APP_BUNDLE)"

clean: ## Clean build artifacts
	swift package clean
	rm -rf $(APP_BUNDLE)

install: build ## Install to /Applications
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"
