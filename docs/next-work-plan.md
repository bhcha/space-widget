# Space change label

2026-10-16 · Native implementation complete; revised motion confirmed by the user.

## Confirmed direction

- Show the name of the Space after a Space transition, then hide it automatically.
- Position: **top center of the display** (user selected).
- Motion, corrected by the user: a small droplet-like label emerges from the
  existing widget's name, travels diagonally upward toward the center while
  growing, then shrinks back along the same route into the widget's name.
  The motion preview retains the previously selected top-center destination.
- Provide an enable/disable option and keep the native macOS look and English UI.
- Keep the verified Space navigation behavior. Desktop slide animation is outside
  this work; the label itself provides transition feedback through travel,
  growth, and a subtle droplet deformation.
- Keep the scope small and reuse the current Space observer and label lookup.

## Implemented first version

| Item | Behavior |
| --- | --- |
| Trigger | A real change of the current ordinary Space on a display, regardless of whether it came from a gesture, Mission Control, the widget, or an AI notification |
| Text | Existing configured name plus Space number, for example `Work · Space 1`; use `Space 1` when no name is configured |
| Placement | Start and finish at the existing widget's name; expand at the top center of the same display, below its menu bar/notch safe area |
| Appearance | Dark capsule matching the widget, drawn with native layers inside its existing panel; native settings support light/dark appearance |
| Entrance | Emerge small from the widget name, travel diagonally upward on a soft curve, and grow into a readable capsule over 0.30s; slight droplet stretch during travel |
| Hold | Remain still and fully visible for 2s, with a symmetric rounded outline; every Space change resets the idle countdown, with a full readable hold after an unfinished entrance |
| Exit | After the idle countdown, shrink back along the same curve into the widget name over 0.25s, easing to rest at the origin so a late interruption can turn safely |
| Interaction | Nonactivating and click-through; keyboard input and focus stay with the user's app |
| Rapid switching | Leave an unfinished ascent untouched; at the destination, change only the text and reset the timer without any movement. During return, redirect the existing bubble from its current position, scale, and velocity with a non-bouncy spring, relax the existing tail, and renew the full 2s hold after arrival. After a completed return, begin a fresh entrance. Never queue old destinations |
| Settings | `Preferences → Appearance → Space Name Animation`, a native on/off switch, default on, plus `Preview`; persist the toggle and immediately hide the current label when disabled |
| Reduced Motion | Show and hide without movement or fading when the system requests reduced motion |

Initial launch and connecting a display establish the baseline without showing a
label. Repeated snapshots, app focus changes, label edits, and Space reordering
without changing the active Space must not retrigger it. Turning the setting off
hides any visible label immediately. First-version scope is ordinary named
Spaces: suppress the panel while a display is in a fullscreen presentation and
show the ordinary destination when returning from it.

No duration slider, position picker, new shortcut, sound, screen capture, external
dependency, or hook update is needed for the first version. Timing can be adjusted
after one visual review rather than growing the settings screen now.

## Implementation

1. `SpaceLabelTransitionTracker` consumes existing display-scoped Space updates.
   It compares stable UUIDs, falling back to runtime Space IDs. Names come from
   `ConfigManager.labelFor`; there is no extra polling loop or label mapping.
2. `SpaceLabelOverlay` is a click-through AppKit view inside each existing
   display-sized widget panel. Core Animation moves, scales, and morphs its layers.
   Departure and return use the center of the widget's fixed label slot, sharing
   `SpaceBarConstants`; this is not measurement of individual text glyphs.
   An auto-hidden widget temporarily reveals for the animation (0.25s reveal
   delay), then resumes its ordinary visibility state. The preference is unchanged.
3. Entrance, idle countdown, and return are separate. Replacement cancels the old
   dismissal and completion callbacks, leaves an active ascent unchanged, and
   updates an expanded label's text without a new movement animation. The return
   begins only when the latest idle deadline expires. Submitted movement keyframes
   and their clock allow a late switch during return to settle from the current
   position, scale, opacity, and tail even without a presentation layer. The
   current keyframe segment supplies position/scale velocity to Apple's macOS 14
   `Spring` solver (0.16s perceptual duration, zero bounce). Actual settling time
   determines the readable hold deadline; it is not a fixed 0.12s restart.
   Recovery keyframes are sampled more densely around interruption to retain
   velocity through braking. Opacity reverses toward visible immediately and
   the existing tail relaxes monotonically. Generation and deadline checks
   prevent old callbacks from dismissing the replacement.
   Fullscreen, display removal,
   screen geometry changes, and disabling cancel the overlay. AI toast queues and
   Space navigation remain independent.
4. `Preferences → Appearance` provides the persisted toggle and Preview. Preview
   displays the current Space name without switching Spaces or modifying hooks.
   Reduced Motion uses the same 2s idle countdown, without movement.
5. `SpaceMonitor` reads current Space metadata immediately on the existing
   `activeSpaceDidChangeNotification`. Its former 100ms debounce becomes a
   trailing reconciliation read, with unchanged state suppressed. This removes
   the app's added wait while retaining a retry for settling metadata; it cannot
   anticipate a gesture or undo an exit completed before macOS notifies us.

## Verification and visual feedback

- Initial implementation: `swift test` passed (101 tests, 2 opt-in native tests
  skipped, 0 failures), and `make verify-build` passed. The updated debug app
  reported Accessibility trusted.
- Automated coverage includes transition filtering, per-display baselines,
  fullscreen return, settings persistence, interruption/cancellation, animation
  route and timing, click-through, safe area, reduced motion, and native rendering.
- Light/dark settings and the native label were rendered and visually inspected.
- The running debug app logged labels on real Space transitions. The user saw
  the animation and reported a dent at the lower-left edge of the expanded label.
  The resting curve was corrected to a circular capsule end; the tail now only
  deforms during travel. A regression test checks the held animation outline
  against capsule geometry, including that corner. The user confirmed the fix.
- Follow-up: the user requested reuse, then reported that repeated movement was
  distracting and asked for a fresh hold on each switch and faster travel.
  Runtime logs showed switches about 1.7–2.6s apart, often hitting the old 1.2s
  hold's return phase. The implementation now keeps the expanded bubble static
  and renews a separate idle timer, initially 3s and shortened to 2s by the user
  after the timing research. Travel was shortened from 0.52s/0.45s to
  0.30s/0.25s for entrance/return.
- Tests replay the observed switching intervals, verify unchanged ascent animation,
  reject stale/early/duplicate dismissal callbacks, and cover reduced motion and
  a late return interruption. A real-clock test crosses the original deadline
  after a replacement and checks that only the latest deadline dismisses the label.
  Runtime `SPACELABEL` modes are `new`, `continue-ascent`, `reuse-held`, `redirect`,
  reduced-motion `static`, and the separately scheduled `return`.
- Verification after the timer/speed correction: 106 tests, 2 opt-in native
  tests skipped, 0 failures; all 17 label tests (including the real timer test)
  passed. Release build passed. The updated debug app was restarted for review.
- After the user selected a 2s hold, all 17 label tests and the release build
  passed again. The running debug app was updated; entrance/return remain
  0.30s/0.25s, and each Space transition renews the hold.
- Interruption follow-up: runtime logs showed a return at 10:57:31.048, a system
  notification at 31.341, and presentation at 31.447. The 0.25s return had already
  elapsed, so a fresh entrance was expected. Separately, in-flight recovery
  preserved position but restarted velocity. The approved correction now carries
  position/scale velocity through a non-bouncy spring, eases the return to rest,
  and reads metadata immediately on notification. This applies the interruption
  principle described in Apple's [iPhone X interface discussion](https://developer.apple.com/videos/play/wwdc2018/803/)
  and [spring animation guidance](https://developer.apple.com/videos/play/wwdc2023/10158/);
  these sources do not validate this complete macOS Space overlay integration.
- Focused verification: all 22 label/monitor tests pass. Coverage includes
  position and velocity continuity, 18 interruption timing/display-size cases,
  no renewed tail kick or fade-out during recovery, repeated updates during
  recovery, a full 2s hold after arrival, completed-return re-entry, immediate
  notification handling, unchanged-state suppression, and delayed metadata retry.
- Final interruption verification: the full suite ran 111 tests with 2 opt-in
  native tests skipped and 0 failures; release build passed. The debug binary
  was signed with `SpaceWidgetDev` and restarted (PID 75450); startup reported
  Accessibility trusted and the display panel was created. The user subsequently
  confirmed the revised motion during live Space switching. Logs before restart are
  preserved at `output/qa/space-label/pre-redirect-restart.log`.
- Before proceeding to toast stacking, the user requested a visible on/off option.
  The existing persistent setting is now presented as a native switch named
  `Space Name Animation` in Appearance. Turning it off cancels current movement
  and timers; turning it on allows the next Space change to show the label.
  Preview remains disabled while the setting is off.
- On/off UI verification: all 19 label tests and the release build passed.
  The native Appearance screen was rendered and inspected with the explicit
  `Space Name Animation` switch; existing persistence/cancellation logic remains.
- Gesture/widget/AI-toast routes, multiple physical displays, and rapid switching
  still need a complete manual interaction pass. Native frame-rate performance
  has not been measured. See [known issues](known-issues.md) for the separately
  reported text2sql hook destination issue; this feature does not fix it.

Existing integration points:

- `Sources/SpaceWidget/Engine/SpaceMonitor.swift`: display-scoped Space changes and
  fullscreen state.
- `Sources/SpaceWidget/Config/ConfigManager.swift`: the existing Space names.
- `Sources/SpaceWidget/App/SpaceWidgetApp.swift`: controller lifetime and startup.
- `Sources/SpaceWidget/Views/PreferencesView.swift`: native settings tabs.
- `Sources/SpaceWidget/Agents/AgentToastPresenter.swift`: existing local panel
  pattern to inspect; its completion queue and navigation stay independent.
- `Sources/SpaceWidget/Views/SpaceBarView.swift` and
  `Sources/SpaceWidget/Panel/SpacePanelController.swift`: widget label geometry
  and visibility to inspect before implementing the animation anchor.

## Motion preview

`output/mockups/space-label-droplet.html` demonstrates the requested path and
droplet growth. Replay, slow motion, path visibility, and timeline scrubbing are
preview controls only. Durations and shape are proposals for visual review,
not final native implementation settings.

### Feasibility review — 2026-10-16

The required drawing and animation capabilities are available in Apple's public
macOS APIs. Core Animation documents curved position paths, transforms, opacity,
and simultaneous property animation. `CAShapeLayer.path` supports explicit shape
animation; interpolated paths must retain the same segment/control-point count.
That supports the preview's capsule-to-droplet deformation at the API level.

Repository inspection found that `SpacePanelController.addPanelContext` already
creates a display-sized transparent panel and hosting view. `SpacePanel` is
nonactivating and cannot become key/main. The widget's label is our own view, and
Space changes are already observed per display. These are relevant existing
integration points, not an end-to-end native implementation test.

At the time of this feasibility review, remaining work included resolving the label anchor, handling
the widget's auto-hidden state, preventing repeated snapshot updates from
restarting the effect, cancelling obsolete animation on rapid Space changes, and
checking click-through, fullscreen suppression, and display changes. No native
code was changed or prototype launched as part of that review. The implementation
and verification notes above describe the subsequent work.

Apple's shipping macOS Dock has window-minimization animations. That is evidence
for that product behavior only. An identical production implementation combining
this widget label, droplet path, and cross-Space trigger was not established;
the complete feature is not claimed to be production-validated.

Official references:

- [Core Animation: animating layer content](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CreatingBasicAnimations/CreatingBasicAnimations.html)
- [CAShapeLayer.path](https://developer.apple.com/documentation/quartzcore/cashapelayer/path)
- [macOS Desktop & Dock settings](https://support.apple.com/guide/mac-help/change-desktop-dock-settings-mchlp1119/mac)

## Acceptance criteria

- One label appears for a real Space change and shows the same name as the widget.
- The label visibly leaves the widget name, grows along the diagonal path, and
  shrinks back into that same name; it must not appear from an unrelated screen
  edge or simply fade at the destination. Interruption must not cause a jump.
- A rapid A → B → C sequence ends with C; an old timer cannot hide C prematurely.
- Launch, display attachment, duplicate events, and a rename do not produce false
  transition notifications.
- The panel remains within the correct display's safe area and does not take
  focus, intercept clicks, or appear over fullscreen presentations.
- Disabling survives restart and immediately removes a visible panel.
- Native light/dark and reduced-motion behavior are checked. Existing AI hooks,
  customizable Control + Option + G, and verified Space return still work.

## Earlier item: Toast stacking (superseded by the capsule deck below)

Requested 2026-10-16; recorded for future implementation.

- Multiple visible toasts must not overlap.
- Place the newest toast at the top and move earlier toasts below it.
- When a toast disappears, close the gap while preserving newest-first order.
- Each toast must retain its own content and destination after repositioning;
  clicking an older toast must still navigate to that toast's original Space.
- Verify consecutive arrivals and dismissal while several toasts are visible.

### Decisions and first implementation — 2026-10-18

- User decisions: show at most **3** toasts at once and queue the rest
  (bounded FIFO, 128); the **Control + Option + G** shortcut acts on the newest
  (top) toast that can navigate. Only that toast shows the shortcut hint.
- `AgentToastPresenter` now keeps one panel, timer and destination per visible
  toast (newest first). A new toast appears in the top slot and older ones slide
  down (0.2s, no movement with Reduce Motion). Dismissal closes the gap; the
  oldest waiting toast then enters on top, since it arrived after every visible one.
- Clicking any visible toast navigates to its own Space; only one navigation runs
  at a time. A failed navigation replaces that toast in its slot with the failure
  message. Slots are 390×170 with 10pt spacing from the top-right of the main
  screen's visible frame.
- Automated: 127 tests, 4 opt-in skipped, 0 failures, including stack order,
  overflow queueing, gap closing, non-overlapping slot geometry, final panel
  frames after repositioning, per-toast timeout, clearing when notifications are
  turned off, older-toast click navigation and newest-target shortcut.
- Not yet checked: the stack with real hook completions in the running app, and
  visual review of the slide animation.

## Current item: Notification capsules merged with the Space label

Decided 2026-10-18 from an HTML mockup review. Replaces the top-right toast stack
above; the queue, per-toast timers, per-toast destinations and the shortcut rules
stay.

| Item | Decision |
| --- | --- |
| Shape | Notifications take the Space label's look: dark capsule (white 0.14, 96%), 0.7pt white 18% outline, fully rounded ends. Both are **380×62pt** |
| Position | Same anchor as the Space label today (top center, about 207pt below the top of a 1080pt display) |
| State | A colored dot and bold state word on the left: Done green, navigation failure and Unknown Space orange, Preview grey. Needs input blue is reserved for the question popup work |
| Text | Line 1: project and state. Line 2: agent · app · Space, or the reason it cannot navigate |
| Several at once | **Overlapping deck**: newest in front, each older card 12pt lower, 5% smaller and fainter. At most 3 cards, the rest wait (`+N more`) |
| Clicking | Any visible part of any card, front or back, navigates straight to that card's Space. Hovering 0.6s fans the deck out into a list |
| Space label | Keeps its droplet entrance from the widget and return to it. New size 380×62, single line with the Space name (`Space N` when unnamed). The number moves into a layer-stack icon (from the app icon) on the left: the destination layer slides out, rises onto the stack and shows the Space number |
| Toast entrance | Plain appearance in the deck; no droplet motion |

Overlap rules:

1. A Space change while cards are visible: the Space label becomes the front card
   of the same deck; the notification cards step back one card and come forward
   again when it leaves. Their back edges stay clickable (the label is click-through).
2. A notification that arrives while the Space label is showing: the sound plays at
   once; the card waits directly behind the label and comes forward when it leaves.
   The label keeps its normal 2s hold.
3. While the Space label is in front, notification timers pause.
4. Arriving at a finished task's Space by any route (gesture, Mission Control,
   widget) dismisses that task's Done card.

Implementation notes: the Space label stays inside the widget panel; notification
panels sit one window level below it so the label always draws in front.

### First implementation — 2026-10-18

- `AgentToastPresenter`: deck geometry from `SpaceLabelOverlay.destination`, one
  panel per card at `floating - 1`, depth drawn in SwiftUI (scale from the top edge,
  fade). Hover is tracked with an always-active tracking area, so it works while
  SpaceWidget is not the active app. `setSpaceLabelInFront` pauses and resumes
  per-card timers; `spaceDidBecomeActive(uuid:)` dismisses arrived cards (reason
  `arrived`), skipping a card that is mid-navigation.
- `SpacePanelController` reports the label's visibility on `NSScreen.main` (the
  deck's display) and every active Space change.
- `SpaceLabelOverlay`: 380×62, single-line name (19pt), `SpaceStackIcon` on the left.
  On a new entrance the icon plays as the bubble settles; on a later switch it plays
  at once. Reduced Motion swaps layers without movement.
- Automated: 131 tests, 4 opt-in skipped, 0 failures. New: deck anchor and fan-out
  geometry, panel level below the widget, label-in-front pause and resume, arrival
  dismissal, card appearance, icon rise order. Rendered card and label checked as
  images.
- Not yet checked in the running app: hover fan-out, clicking a back card's edge,
  the icon motion, and the deck during real hook completions.

## Following item: Claude / Codex question popup

This remains a **feasibility investigation**, not an implementation commitment.
Investigate Claude Code CLI, Codex CLI, and each desktop app separately. For each,
record the official event/API for receiving a user question, the interface for
sending an answer, request/session correlation, supported version, and limitations.

Only propose implementation scope after both receiving a question and returning
its answer to the same session are supported by evidence. If either half is
unconfirmed, record it as unconfirmed. Hook completion events alone do not establish
interactive question/answer support. Do not fill gaps with guessed integrations.
