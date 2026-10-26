# YATD — Yet Another ToDo

A macOS menu bar app that shows your **top 3 tasks for today** from a Notion database, in a panel that can float above every window and Space.

## Requirements

- macOS 15+
- [`ntn`](https://developers.notion.com) (Notion CLI), logged in: `ntn login`, or a Notion integration token (see below)
- Xcode + `xcodegen` (`brew install xcodegen`) to build

## Install

```sh
brew install --cask shonenada/tap/yatd
```

## Build & run

```sh
just run        # build Debug, launch, stream logs (Ctrl-C quits)
just install    # build Release into /Applications
just test       # unit tests
```

On first launch, click **Create “YATD” page in Notion**, or paste an existing database URL. The app creates a `YATD` page with an inline **Tasks** database:

| Property | Type | Meaning |
|---|---|---|
| Name | title | the task |
| Done | checkbox | completed |
| Date | date | day it's due; add a time (and end) to put it on the schedule |
| Priority | select | High / Medium / Low |
| Repeat | select | Daily / Weekdays |
| Order | number | manual tie-break |
| Started | date & time | when you pressed ▶ on a one-time task |
| Finished | date & time | when you ticked off a one-time task |

Databases created by older versions get `Started`/`Finished` added automatically on the next sync.

## Connecting to Notion

- **ntn CLI** (default for builds from source): reuses `ntn login`. Needs no setup beyond the CLI.
- **Integration token** (always used by the TestFlight / App Store build, optional elsewhere in Settings):
  1. Create an internal integration at https://www.notion.so/profile/integrations and copy its token.
  2. In Notion, open the page that holds (or will hold) YATD → ••• → Connections → add the integration.
  3. Paste the token in YATD. It's stored in Keychain. Then pick the database it finds, or paste that page's URL to create YATD inside it. Integrations can't create workspace-level pages.

## Releasing

The regular build runs `ntn` as a subprocess, so it isn't sandboxed. The **`AppStore`** build configuration is sandboxed (network client only) and uses the integration token instead, which is what TestFlight requires.

```sh
bundle install                 # once; fastlane goes to vendor/bundle
cp .env.example .env           # fill in ASC key, match repo, optional GITHUB_TOKEN
```

**TestFlight** (sandboxed `AppStore` build):

```sh
just sync-appstore-certs       # once: Mac App Store distribution + installer certs, profile
just beta                      # build .pkg → upload to TestFlight, tag build-<n>
just distribute [build]        # send an uploaded build to the external "Public" group
```

The app record must exist in App Store Connect first (＋ → New App → macOS, bundle ID `com.shonenada.yatd`). The API can't create it.

**Homebrew** (Developer ID, notarized):

```sh
just sync-certs                # once: create/fetch the Developer ID certificate via match
just release                   # build → sign → notarize → staple → build/release/YATD-<version>.zip, tag v<version>
just publish                   # push the tag, attach the zip to the v<version> GitHub release
just tap                       # open a PR on shonenada/homebrew-tap updating Casks/yatd.rb
```

Each release needs a new `MARKETING_VERSION` in `project.yml`. `just tap` hashes the zip users will actually download, renders `packaging/homebrew/yatd.rb.erb`, refreshes the tap README and opens the PR. Once it's merged:

```sh
brew install --cask shonenada/tap/yatd
```

The version comes from `MARKETING_VERSION` in `project.yml`; the build number defaults to the git commit count. Regenerate the icon with `swift scripts/make-icon.swift`.

## How the top 3 is picked

Open tasks are ranked by bucket, then priority, then Order, then creation time:

1. **In progress**: one-time tasks you've started
2. **Now**: timed today and started, or starting within the hour
3. **Overdue**: dated before today
4. **Today**: all-day today
5. **Later**: timed later today
6. **Someday**: no date

The first three show; the rest is "+N more".

## Daily schedule

- **Rollover:** the day starts at 04:00 (configurable). One-off tasks from past days show as *Overdue*. Undone recurring tasks move forward to today.
- **Recurring:** completing a `Daily`/`Weekdays` task creates the next occurrence, keeping its time block.
- **Timeline:** the second tab lists today's time-blocked tasks and highlights the current one. Optional notifications fire at each start time.

## Projects

Each project is its own Notion page with a tasks database, created inside your YATD page. Your first database is the first project.

- **Create:** Settings → Projects → New project (or "New Project…" in the panel's title menu). Existing YATD databases can be added from the same tab.
- **Switch:** click the panel's title. Choose **Auto (by schedule)**, or tick projects by hand. With several active, Top 3 ranks across them and each card names its project.
- **Schedule:** Settings → Schedule. Rules like *Weekdays 09:00–18:00 → Work, Side Project* and *Every day 21:00–02:00 → Home*. The first matching rule wins, and outside every rule all projects show. A rule ending before it starts runs past midnight. The panel switches on its own when a rule starts or ends.
- **Quick add** goes to the first active project. Add `#name` to pick one, for example `Fix login #side !h`.

**Shared between Macs:** the project list, schedule rules and day-start hour live in a collapsed **YATD settings** toggle on your YATD page, as JSON. Every Mac reads it on each sync and writes its own changes back after a 2-second pause. On a new Mac, connecting any YATD database brings in the rest. A Mac's first sync merges its local projects and rules into the shared ones. Later, if two Macs edit at once, the latest local edit wins. Panel position, opacity, the connection method and projects picked by hand stay per Mac. You can edit the JSON in Notion; invalid JSON is replaced on the next save.

## Time tracking (one-time tasks)

Press ▶ on a task to record **Started**; ticking it off records **Finished**. The row then shows the start–finish range and its duration. Reopening a task clears Finished and keeps Started. Recurring tasks don't record times.

## Using more than one Mac

Tasks live in Notion; each Mac syncs every minute. On a new Mac, log in with `ntn login`. The setup screen then lists any YATD-shaped database already in your workspace, so connect to that instead of creating another. Settings (panel position, day start hour, reminders) stay on each Mac.

If two Macs complete the same recurring task, only one next copy is created. The app checks Notion first, and trashes any duplicate copy that slips through on the next sync.

## Quick add

Type in the panel's field (focus it from the menu bar → *Add Task…*):

```
Standup @10:00-10:15 !h *weekdays
Write report !m
Someday idea ~
```

`@HH:mm[-HH:mm]` time block · `!h/!m/!l` priority · `*daily/*weekdays` repeat · `~` no date · `#project` target project

## Shortcuts

- **⌥⌘Y**: show/hide the panel (global)
- Pin button: toggle always-on-top

## Layout

- `YATDCore/`: Swift package with the models, Notion JSON coding, `Planner` (ranking/recurrence/rollover), `QuickAdd` and `NtnCLISource`. All UI-free and unit-tested.
- `YATD/`: the SwiftUI/AppKit app (`TaskStore`, floating panel, menu bar, settings).

Data access goes through the `TaskSource` protocol, so a direct REST/OAuth source can replace `ntn` later. The app is unsandboxed because it runs `ntn` as a subprocess.
