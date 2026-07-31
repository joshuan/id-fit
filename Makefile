DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

# What `make package` stamps into the bundle. CI passes the release tag and the
# workflow run number; a local package keeps the placeholder version.
VERSION ?= 1.0
BUILD ?= 1

# "-" is ad-hoc signing, which is all a machine without a Developer ID can do.
# CI overrides both when the signing secrets are present.
SIGN_IDENTITY ?= -
CODESIGN_FLAGS ?= --options runtime

XCODEBUILD := xcodebuild -project IdFit.xcodeproj -scheme IdFit -derivedDataPath build

.PHONY: gen build run test icon package clean

gen:
	xcodegen generate

build: gen
	$(XCODEBUILD) -configuration Debug build

run: build
	open build/Build/Products/Debug/IdFit.app

test: gen
	$(XCODEBUILD) test

# Regenerates the app icon; only needed when the artwork changes.
icon:
	swift Tools/make-icon.swift Sources/IdFit/Resources

# Release build, signed, ready to copy to /Applications.
package: gen
	$(XCODEBUILD) -configuration Release \
		MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD) build
	rm -rf dist
	mkdir -p dist
	cp -R build/Build/Products/Release/IdFit.app dist/IdFit.app
	codesign --force $(CODESIGN_FLAGS) --sign "$(SIGN_IDENTITY)" dist/IdFit.app
	# ditto, not zip: it is the only archive format Apple's notary service
	# accepts, and it keeps the signature intact.
	ditto -c -k --keepParent dist/IdFit.app dist/IdFit.zip
	@echo "packaged: dist/IdFit.app and dist/IdFit.zip ($(VERSION) build $(BUILD))"

clean:
	rm -rf build dist IdFit.xcodeproj
