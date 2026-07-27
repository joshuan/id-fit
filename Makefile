DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

XCODEBUILD := xcodebuild -project IdFit.xcodeproj -scheme IdFit -derivedDataPath build

.PHONY: gen build run test clean

gen:
	xcodegen generate

build: gen
	$(XCODEBUILD) -configuration Debug build

run: build
	open build/Build/Products/Debug/IdFit.app

test: gen
	$(XCODEBUILD) test

clean:
	rm -rf build IdFit.xcodeproj
