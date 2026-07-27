DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

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

# Release build, ad-hoc signed, ready to copy to /Applications.
package: gen
	$(XCODEBUILD) -configuration Release build
	rm -rf dist
	mkdir -p dist
	cp -R build/Build/Products/Release/IdFit.app dist/IdFit.app
	codesign --force --sign - dist/IdFit.app
	cd dist && zip -qry IdFit.zip IdFit.app
	@echo "packaged: dist/IdFit.app and dist/IdFit.zip"

clean:
	rm -rf build dist IdFit.xcodeproj
