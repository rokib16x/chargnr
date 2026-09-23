.PHONY: build test app run clean

build:
	swift build

test:
	swift test

app:
	xcodegen generate
	xcodebuild -project chargnr.xcodeproj -scheme chargnr -configuration Debug \
		-derivedDataPath build build -quiet

run: app
	open build/Build/Products/Debug/chargnr.app

clean:
	rm -rf .build build chargnr.xcodeproj
