# YATD — Yet Another ToDo

A macOS menu bar app that shows your **top 3 tasks for today** from a Notion database, in a panel that can float above every window and Space.

## Requirements

- macOS 15+
- [`ntn`](https://developers.notion.com) (Notion CLI), logged in: `ntn login`
- Xcode + `xcodegen` (`brew install xcodegen`) to build

## Build & run

```sh
make run       # build Release and launch
make install   # copy to /Applications
make test      # unit tests
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

`@HH:mm[-HH:mm]` time block · `!h/!m/!l` priority · `*daily/*weekdays` repeat · `~` no date

## Shortcuts

- **⌥⌘Y**: show/hide the panel (global)
- Pin button: toggle always-on-top

## Layout

- `YATDCore/`: Swift package with the models, Notion JSON coding, `Planner` (ranking/recurrence/rollover), `QuickAdd` and `NtnCLISource`. All UI-free and unit-tested.
- `YATD/`: the SwiftUI/AppKit app (`TaskStore`, floating panel, menu bar, settings).

Data access goes through the `TaskSource` protocol, so a direct REST/OAuth source can replace `ntn` later. The app is unsandboxed because it runs `ntn` as a subprocess.
