# YATD — build & run the macOS app without opening Xcode.
# Run `just` with no args to list recipes.

set default-list

project := "YATD.xcodeproj"
scheme  := "YATD"
derived := "build"

# List available recipes (default).
default:
    @just --list

# Regenerate the .xcodeproj from project.yml (skips if up to date; after adding files, use regen).
generate:
    @if [ ! -d "{{project}}" ] || [ project.yml -nt "{{project}}" ]; then \
        echo "▸ xcodegen generate"; xcodegen generate; \
    else echo "▸ project up to date"; fi

# Force-regenerate the project.
regen:
    xcodegen generate

# Build the app (Debug by default; `just build Release`).
build config="Debug": generate
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{config}} \
        -derivedDataPath {{derived}} build

# Print the built .app path (used by other recipes).
app-path config="Debug":
    @echo "{{derived}}/Build/Products/{{config}}/{{scheme}}.app"

# Build, relaunch and stream stdout/stderr until the app quits or Ctrl-C (the everyday command).
run config="Debug": (build config) stop
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'pkill -x {{scheme}} || true; exit 0' INT TERM
    "$(just app-path {{config}})/Contents/MacOS/{{scheme}}"

# Build and relaunch without streaming logs (returns immediately).
launch config="Debug": (build config) stop
    open "$(just app-path {{config}})"

# Relaunch the last build without rebuilding.
reload config="Debug": stop
    open "$(just app-path {{config}})"

# Quit the running app and wait for it to exit (reopening too soon fails).
stop:
    -@pkill -x {{scheme}}; for i in $(seq 50); do pgrep -x {{scheme}} >/dev/null || break; sleep 0.1; done

# Stream the running app's unified logs.
logs:
    log stream --style compact --predicate 'process == "{{scheme}}"'

# Build Release and install into /Applications.
install: (build "Release") stop
    rm -rf /Applications/{{scheme}}.app
    cp -R "$(just app-path Release)" /Applications/
    open /Applications/{{scheme}}.app

# Run YATDCore unit tests.
test:
    cd YATDCore && swift test

# Create, complete and trash a task in a real Notion database (data source ID, or YATD_LIVE_DS).
test-live ds=env("YATD_LIVE_DS", ""):
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{ds}}" ]; then
        echo "✗ Pass a data source ID: just test-live <id> (or set YATD_LIVE_DS)" >&2
        exit 1
    fi
    cd YATDCore && YATD_LIVE_DS="{{ds}}" swift test --filter LiveNtnTests

# Save a screenshot of all displays (default: shot.png).
shot file="shot.png":
    screencapture -x {{file}}

# Remove build artifacts and the generated project.
clean:
    rm -rf {{derived}} {{project}}

# --- Release (fastlane; see .env.example) ---

# Sync Mac App Store certs & profile via fastlane match.
sync-appstore-certs:
    bundle exec fastlane mac sync_appstore_certificates

# Build the sandboxed App Store variant & upload to TestFlight (upload only).
beta:
    bundle exec fastlane mac beta upload_only:true

# Send an uploaded TestFlight build to the external group (default: latest git build number).
distribute build="":
    bundle exec fastlane mac distribute {{ if build == "" { "" } else { "build_number:" + build } }}

# Sync the Developer ID certificate via fastlane match.
sync-certs:
    bundle exec fastlane mac sync_certificates

# Build, sign, notarize and zip into build/release/YATD-<version>.zip; tags v<version>.
release:
    bundle exec fastlane mac release

# Upload YATD-<version>.zip to the v<version> GitHub release.
publish:
    bundle exec fastlane mac publish

# Open a PR on the Homebrew tap updating Casks/yatd.rb to the published release.
tap:
    bundle exec fastlane mac tap
