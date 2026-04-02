# SpaceWidget — Current Architecture

## Scope

This document describes the product as it is currently implemented.
Older expansion plans that do not match the running app are intentionally discarded.

## Product Boundary

SpaceWidget currently provides:

- active macOS Space detection
- visible app collection for the current Space
- a single snapshot pipeline
- `state.json` export for scripts
- a full-screen transparent panel with a bottom-left SwiftUI space bar
- paging for app icons
- app activation by clicking an icon

SpaceWidget does not currently provide:

- file watching for config changes
- signal-driven reload
- menu bar integration
- accessibility permission flows
- separate action/controller modules for app commands
- a dedicated UI view model layer

## Runtime Architecture

```text
ConfigManager
    ├─ loads defaults and persisted config
    └─ provides ignored apps and space labels

SpaceMonitor + WindowListProvider
    └─ feed SpaceEngine

SpaceEngine
    ├─ owns the single @Published DockSnapshot
    ├─ reacts to active space changes
    └─ reacts to workspace app lifecycle changes

DockSnapshot subscribers
    ├─ StateWriter
    │   └─ writes ~/.config/space-dock/state.json
    └─ SpacePanelController
        └─ rebuilds SpaceBarView from the latest snapshot
```

The current UI boundary is:

- process-side collection and refresh logic ends at `SpaceEngine`
- panel/UI code depends only on `SpaceEngine.$snapshot`
- `SpaceBarView` handles direct user interaction for icon taps

This is the accepted architecture for the current version.

## Source Layout

```text
Sources/SpaceWidget/
├── App/
│   └── SpaceWidgetApp.swift
├── Config/
│   ├── ConfigManager.swift
│   ├── Logger.swift
│   ├── Migrator.swift
│   └── StateWriter.swift
├── Engine/
│   ├── CGSPrivate.swift
│   ├── SpaceEngine.swift
│   ├── SpaceMonitor.swift
│   └── WindowListProvider.swift
├── Models/
│   ├── ActiveSpace.swift
│   ├── DockItem.swift
│   └── DockSnapshot.swift
├── Panel/
│   ├── SpacePanel.swift
│   └── SpacePanelController.swift
└── Views/
    └── SpaceBarView.swift
```

## Key Responsibilities

### `ConfigManager`

- resolves the config directory
- creates default config files if missing
- loads and saves ignored apps, space labels, and app actions
- writes the active config-dir state file for helper tooling

### `SpaceMonitor`

- listens for `NSWorkspace.activeSpaceDidChangeNotification`
- resolves the current desktop Space via CGS APIs
- filters out transient or unmanaged spaces
- publishes a single `ActiveSpace`

### `WindowListProvider`

- reads the on-screen window list
- filters ignored/system apps
- deduplicates by bundle identifier
- resolves app icons
- returns up to 20 `DockItem` values

### `SpaceEngine`

- owns the single `DockSnapshot`
- captures config values on the main thread before background fetch
- schedules refreshes for:
  - active space changes
  - activated apps
  - launched apps
  - terminated apps
- drops stale snapshots before publish

### `StateWriter`

- subscribes to `SpaceEngine.$snapshot`
- debounces writes
- writes:
  - `current_space`
  - `space_id`
  - `space_label`
  - `apps`

### `SpacePanelController`

- creates the full-screen transparent panel
- subscribes to `SpaceEngine.$snapshot`
- maintains page state across updates
- resets page state when the Space changes
- auto-jumps to the page containing the focused app when needed

### `SpaceBarView`

- renders the current space number and label
- renders paged app icons
- handles swipe paging
- activates an app directly when its icon is clicked

## Current Defaults and Accepted Constants

The following are intentional product constants in the current version:

- fallback space label: `"Untitled"`
- default labels: `"1" -> "Work"`, `"2" -> "Browse"`
- max rendered items from the engine: `20`
- icons per page: `5`

These are not treated as architecture bugs unless product requirements change.

## Verification

Current baseline verification:

1. `swift build`
2. launch the app
3. confirm `spacewidget.log` records `[SPACE]`, `[FETCH]`, `[SNAPSHOT]`
4. confirm `state.json` updates on Space and app changes
5. confirm the panel updates and icon taps activate apps

## Refactoring Rule

Future refactoring should preserve the current product boundary unless the product scope itself changes.
Do not reintroduce discarded abstractions just to match older planning documents.
