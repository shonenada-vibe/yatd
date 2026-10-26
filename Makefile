APP := build/Build/Products/Release/YATD.app

.PHONY: project build run test test-live install clean

project:
	xcodegen generate

build: project
	xcodebuild -project YATD.xcodeproj -scheme YATD -configuration Release -derivedDataPath build build

run: build
	pkill -x YATD || true
	open $(APP)

test:
	cd YATDCore && swift test

# Creates, completes and trashes a task in a real database: make test-live DS=<data source id>
test-live:
	cd YATDCore && YATD_LIVE_DS=$(DS) swift test --filter LiveNtnTests

install: build
	pkill -x YATD || true
	rm -rf /Applications/YATD.app
	cp -R $(APP) /Applications/
	open /Applications/YATD.app

clean:
	rm -rf build YATD.xcodeproj
