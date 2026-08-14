# SpaceWidget — AI working notes

## Runtime artifacts

| Path | Purpose |
|------|---------|
| `~/.config/space-dock/spacewidget.log` | Main runtime log. Truncated on each launch. |
| `~/.config/space-dock/space_labels.json` | Persisted space labels (v3 schema with `uuid` field). |
| `~/.config/space-dock/state.json` | Latest snapshot for the main display (current space, label, apps). |
| `~/.config/space-dock/shortcuts.json` | User-customized hotkey bindings. |
| `~/.config/space-dock/templates.json` | Saved layout templates. |
| `~/Library/Preferences/com.apple.spaces.plist` | macOS source of truth for space → uuid mapping. Read with `defaults read com.apple.spaces` or `plutil -convert json -o -`. |

## Log tags worth knowing

`grep '\[TAG\]' ~/.config/space-dock/spacewidget.log` to filter.

| Tag | When it fires |
|-----|---------------|
| `[EVENT]` | NSWorkspace notifications, debouncing |
| `[SPACE]` | Per-display active space detection (id, ordinal, label) |
| `[FETCH]` / `[SNAPSHOT]` | Dock snapshot capture |
| `[PANEL]` | Panel/screen lifecycle (display add/remove) |
| `[LABEL]` | **Diagnostic** for label resolution drift — see below |
| `[HOTKEY]` | Hotkey registration failures only |
| `[CLICKDIAG]` | **Diagnostic** for panel click routing (post-HDMI-unplug fall-through). Fires at panel creation (+1s resample) and, via a global left-click monitor, on any click near a bar that the window server routed to another app — includes a CGWindowList z-order dump. Permanently enabled. |

### `[LABEL]` log subtypes

- `tier0 fallback match=uuid|spaceID|ordinal …` — single-display dead-display fallback fired. `match=ordinal` is the legacy path and indicates the dead entry has neither uuid nor matching spaceID; investigate if you see this for a space the user expects to follow correctly.
- `tier1 uuid xdisplay …` — UUID matched an entry stored under a different display. Normal during display reconnect; persistent appearance suggests rebind is not migrating entries.
- `rebind step0 uuid=… …` — entry migrated by UUID across displays.
- `rebind step1 sid=… …` — legacy entry on same display being stamped with UUID for the first time.
- `rebind step2 ord=… …` — sentinel/dead spaceID rebind by ordinal (legacy path).
- `prune uuid=… …` — entry removed because its space no longer exists in any live display's space list. Only fires for UUID-bearing entries on a currently-connected display; dead-display and `__main__` sentinel entries are never pruned.
- `edit strategy=uuid|spaceID|deadDisplay|ordinal|sentinel|insert …` — which match strategy `updateSpaceLabel()` chose, with the prior entry state for diff.

## Label-resolution architecture

Identifier stability ranking (most → least):
1. **UUID** — survives reboot, display reconnect, macOS reorder.
2. **spaceID** — stable within a session; reset on reboot/logout.
3. **displayID** — changes when display is unplugged.
4. **ordinal** — changes whenever macOS reorders.

`labelFor()` priority:
1. Tier 0: dead-display fallback (single-display mode, dead display has more labels) — internal priority `uuid > spaceID > ordinal`. Skipped if same display has a uuid- or spaceID-matched explicit label.
2. Tier 1: global UUID match across all entries.
3. Tier 2: spaceID match on same display (or `__main__` sentinel).
4. Tier 3: ordinal match for sentinel-only legacy entries.

`updateSpaceLabel()` mirrors the same priority for symmetry; dead-display write-back preserves the dead `displayID`/`spaceID` so labels survive display reconnect.

`rebindAllOrdinals()` runs on every space change. Step 0 migrates by UUID across displays; Steps 1–2 stamp UUIDs onto legacy v2 entries the first time they're seen. After the rebind steps, a prune pass removes UUID-bearing entries whose UUID is absent from every live space, gated to currently-connected displays so dead-display fallback and `__main__` sentinels are preserved; spaceID-only entries are never pruned because spaceIDs are reassigned on reboot.

## Building & running

```bash
swift build
.build/debug/SpaceWidget   # NOT the .app bundle — that has separate AX permissions and may be stale
```

The `.app` bundle and the direct binary are treated as **separate apps** by macOS for Accessibility permission. If the user reports shortcuts not working after a macOS upgrade, suspect AX permission revocation; restart the binary so macOS re-prompts.

## macOS-specific gotchas

- **Electron apps (Claude, Obsidian) need `AXManualAccessibility = true`** on macOS 26+ to expose their AX tree. Set in `CGSPrivate.swift::ensureAXEnabled()`, called from any code path that creates an `AXUIElementCreateApplication` for a possibly-Electron app.
- `CGSCopyManagedDisplaySpaces` may return more displays than `NSScreen.screens` (it includes recently-disconnected displays). Use `liveDisplayIDs` (sourced from NSScreen) to gate dead-display fallback.
- macOS Mission Control's "Automatically rearrange Spaces based on most recent use" (`defaults read com.apple.dock mru-spaces`) reorders ordinals on every focus change. The UUID-based identification handles this; older ordinal-only logic did not.
- The `.app` bundle and the direct binary have **separate** AX permissions in System Settings.

## When investigating "labels swapped" reports

1. `cat ~/.config/space-dock/space_labels.json` — what's saved
2. `defaults read com.apple.spaces | head -100` — current uuid ↔ spaceID mapping per display
3. `grep LABEL ~/.config/space-dock/spacewidget.log | tail -50` — recent drift events
4. `grep PANEL ~/.config/space-dock/spacewidget.log | tail -20` — recent display connect/disconnect
5. Compare the spaceID/uuid in the saved labels against the live plist mapping to spot mismatches
