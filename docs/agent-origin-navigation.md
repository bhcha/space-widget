# Automatic task Space return (2026-10-16)

Clicking a completion toast or pressing its shortcut returns to the ordinary
Space captured when the request started. The destination is its stable UUID and
display identifier, resolved against the current Space list. No app activation,
window raising, window picker, or manual session association is used.

The app-activation attempt was removed after the user's live test brought forward
another Ghostty window. `[APPRETURN] activation confirmed` at 08:48:33 proved only
app focus, not the requested Space. Source-app identity remains display metadata.

## Capture and delivery

The v6 helper captures the source application's bundle ID, PID, and display name
during `SessionStart` and `UserPromptSubmit`. It follows process ancestry to a
running GUI app. The v3 read-only `sysctl(KERN_PROC_PID)` fallback is retained:
`proc_pidinfo` alone cannot read the parent of the root-owned `/usr/bin/login`
in the reproduced Ghostty terminal chain. If ancestry cannot identify an app,
known terminal environment metadata can identify one unique running app for
display only; it cannot authorize Space capture. The
helper never guesses from the provider, project path, or completion-time focus.

Space UUID and display ID are captured only for an actual GUI process ancestor
when every enumerated host window belongs to the same single ordinary Space.
The host being foreground cannot distinguish different terminal windows.
The receiver marks this capture `single_host_space_v1`; the app rejects legacy
origins without that policy instead of reusing an older foreground guess.
Missing, ambiguous, fullscreen, or disconnected Space information prevents
navigation; a known app alone cannot identify the destination. No Accessibility prompt or window UI is opened.
Desktop app detection alone does not establish that it emits supported hooks;
remote or detached sessions may have no identifiable local source app.

The locked spool retains up to 128 request contexts for 24 hours, keyed by
provider/configuration/session and turn. `Stop` carries the saved app and Space
even after a start event was drained or the main app restarted. It never captures
the foreground app again. A new request with unknown context clears the old
target. SessionStart alone is never a fallback destination. Identified prompt
contexts survive SessionStart during compaction; no-ID prompts survive an
explicit `compact` start only. Without provider turn IDs only the latest
compatible prompt context is available. Stop inherits the capture policy from
that context and cannot certify an older capture itself.

## Navigation and shortcut

`AgentOriginNavigation` resolves the unique captured UUID across current live displays and
requests `SpaceSwitcher` to move there. It then reads the current Space ID up to
40 times at 50ms intervals and requires nine consecutive matching observations
(about 400ms) before reporting success. Posting an event, briefly reaching the
target and bouncing back, or activating the correct app cannot count as arrival.
Deleted Spaces and duplicate UUIDs never fall back to another destination.
A surviving Space that migrated to another display retains its UUID; navigation
uses that current display instead of rejecting it because the saved display changed.
The current Space needs no synthetic input; unavailable Accessibility permission
prevents an actual switch. The verification logs use `[SPACERETURN]` with target,
current Space ID, display, and the original UUID.

The existing dock-swipe path omitted the IOHID payload required by the macOS 27
implementation in WhichSpace. `MacOS27DockSwipe` now builds began/changed/ended
phases, embeds that payload, and accounts for the natural-scrolling direction.
Earlier macOS versions keep the previous event path. System settings and disabled
Mission Control shortcuts are not modified. The shared switcher still requires
the target to be on the active display for gestures; a mismatch is not replaced
with app activation. Synthetic input remains subject to macOS gesture settings.

Reference: [WhichSpace revision 81f9518](https://github.com/gechr/WhichSpace/blob/81f951820208a32bcf03e062fb496f50d6e61df8/WhichSpace/SpaceSwitcher.swift).
The adapted code retains the upstream MIT notice in the application resources.
This is a compatibility repair of the existing mechanism, not a claim of official
Apple support or famous-company production validation.

**Preferences → AI Agents → Go to Space** defaults to **⌃⌥G (Control + Option + G)**.
The recorder permits a different modified key combination. A toast shows its
numbered destination, such as **Go to Space 1**. The shortcut is registered only
while an actionable toast is visible, and temporarily takes priority over the
same SpaceWidget window shortcut. Click and shortcut use the same captured
notice; FIFO and stale callback checks keep queued notifications separate.
Preview and unknown-Space notices cannot navigate. A failed transition shows an
error instead of claiming success or selecting another Ghostty window.

## Initial navigation repair: installation and verification (historical)

The installed v4 helpers already capture Space UUID and app metadata. This fix
changes the main application's navigation and does not replace helper binaries,
change their command identities, or require another Codex approval. Previous
configuration backups and immutable helpers remain intact.

The focused 16-test run passed, including native macOS 27 CGEvent serialization
and round-trip preservation of the IOHID field and all phases, natural-scrolling
direction, read-only live terminal capture, known-app/unknown-Space rejection,
wrong-Space and bounce failures, and click/shortcut FIFO behavior. The navigation
tests use a mock Space backend and do not move the user's desktop. Native event
serialization tests do not post input. Live cross-Space movement remains a
separate user-triggered check; it must be reported from actual transition logs.

The full suite then executed 89 tests with one opt-in test skipped and zero
failures; the release build passed. The initial screenshot export attempt had
two failures because its destination directory had not been created. After
creating that directory the full run, including both image exports, passed.
The native settings and numbered destination toast were visually reviewed at
`output/qa/exact-space-return`. The tested debug application was restarted with
Accessibility trusted, retaining the installed v4 helper commands unchanged.

Before committing, an isolated copy of the exact Git index passed
`make verify-test` (80 tests, two opt-in native tests skipped, zero failures) and
`make verify-build`. This verifies the committed files independently of local
uncommitted changes.

## Live cross-Space verification — passed

The user tested the installed debug app twice and confirmed that both attempts
returned to the original Space 1. These used manually generated completion
events through the installed v4 receiver, reusing the isolated test request's
captured origin. They verify real toast/shortcut navigation, rather than a new
provider-generated response or the mock navigation backend.

- 08:57:24 KST: current Space ID 366 → target ID 3, one gesture step;
  native verification matched ID 3, followed by stable `[SPACERETURN] confirmed`.
- 08:58:03 KST: current Space ID 5 → target ID 3, two gesture steps;
  native verification and stable destination confirmation both passed again.

Both resolved the same original UUID on its captured display. Filtered local
evidence is in `output/qa/exact-space-return/live-navigation.log` (not committed,
because it contains machine-specific identifiers). No app activation was used.

## Earlier failure evidence

A real Claude request at 08:12:57 KST captured Space 1 through receiver-v3. At
08:13:29 the old navigation requested Space 2 → Space 1, but logged
`dockSwipe ... switched=false`, `Ctrl+1 not enabled`, and `no switch path available`.
Accessibility trust was true on macOS 27.0.1. The temporary PeonPing-style app
activation later succeeded at app focus but selected the wrong Ghostty window.
This fix restores the original requirement to return to the recorded Space.
