fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac sync_certificates

```sh
[bundle exec] fastlane mac sync_certificates
```

Sync the Developer ID Application certificate via match

### mac sync_appstore_certificates

```sh
[bundle exec] fastlane mac sync_appstore_certificates
```

Sync Mac App Store distribution + installer certificates and the provisioning profile via match

### mac beta

```sh
[bundle exec] fastlane mac beta
```

Build the sandboxed App Store variant and upload it to TestFlight; pass upload_only:true to skip external distribution

### mac distribute

```sh
[bundle exec] fastlane mac distribute
```

Distribute an already-uploaded TestFlight build to the external group

### mac build

```sh
[bundle exec] fastlane mac build
```

Build a Developer ID signed YATD.app into build/release (not notarized)

### mac release

```sh
[bundle exec] fastlane mac release
```

Build, sign, notarize and zip a release; tags the commit and optionally publishes a GitHub release

### mac publish

```sh
[bundle exec] fastlane mac publish
```

Upload YATD-<version>.zip to the v<version> GitHub release (GITHUB_RELEASE_DRAFT=1 for a draft)

### mac tap

```sh
[bundle exec] fastlane mac tap
```

Open a PR on the Homebrew tap updating Casks/yatd.rb to the published release

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
