APP := build/Build/Products/Release/YATD.app

.PHONY: project build run test test-live install clean sync-certs release publish

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

# --- Release (fastlane; see .env.example) ---

# Sync the Developer ID certificate via fastlane match.
sync-certs:
	bundle exec fastlane mac sync_certificates

# Build, sign, notarize and zip into build/release; tags build-<n>.
release:
	bundle exec fastlane mac release

# Upload the last release zip to a GitHub release.
publish:
	bundle exec fastlane mac publish
