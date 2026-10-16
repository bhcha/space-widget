# Next work: Space change label

2026-10-16 · Planning only; implementation has not started.

## Confirmed direction

- Show the name of the Space after a Space transition, then hide it automatically.
- Position: **top center of the display** (user selected).
- Provide an enable/disable option and keep the native macOS look and English UI.
- Keep the verified Space navigation behavior. Desktop slide animation is outside
  this work; the label itself provides transition feedback with a short fade.
- Keep the scope small and reuse the current Space observer and label lookup.

## Proposed first version

| Item | Behavior |
| --- | --- |
| Trigger | A real change of the current ordinary Space on a display, regardless of whether it came from a gesture, Mission Control, the widget, or an AI notification |
| Text | Existing configured name plus Space number, for example `Work · Space 1`; use `Space 1` when no name is configured |
| Placement | Top center of the display that changed, below its menu bar/notch safe area |
| Appearance | Small native material panel with rounded corners; light/dark appearance follows macOS |
| Timing | Proposed default: 0.15s fade in, 1.2s visible, 0.15s fade out |
| Interaction | Nonactivating and click-through; keyboard input and focus stay with the user's app |
| Rapid switching | Replace the previous label with the latest Space and restart the hide timer; never queue old destinations |
| Settings | `Preferences → Appearance → Show Space Name on Switch`, default on, plus `Preview`; persist the toggle |
| Reduced Motion | Show and hide without the fade when the system requests reduced motion |

Initial launch and connecting a display establish the baseline without showing a
label. Repeated snapshots, app focus changes, label edits, and Space reordering
without changing the active Space must not retrigger it. Turning the setting off
hides any visible label immediately. First-version scope is ordinary named
Spaces: suppress the panel while a display is in a fullscreen presentation and
show the ordinary destination when returning from it.

No duration slider, position picker, new shortcut, sound, screen capture, external
dependency, or hook update is needed for the first version. Timing can be adjusted
after one visual review rather than growing the settings screen now.

## Implementation sequence

1. Add a small display-scoped label controller. Consume the existing Space change
   information and resolve names through `ConfigManager.labelFor`; avoid another
   Space polling loop or separate label mapping. Compare stable Space UUIDs, with
   current-run Space IDs as the fallback when a UUID is unavailable.
2. Present one reusable nonactivating panel per changed display. Replace pending
   fade/hide work on a new transition and release panels when displays disconnect.
   Keep this separate from the AI completion-toast queue.
3. Add the native Appearance settings section and preview. The preview shows a
   sample label without switching Spaces or modifying agent hooks.
4. Verify transition filtering and cancellation in tests, inspect light/dark
   rendering, then manually check gesture/widget/AI-toast navigation and rapid
   switching. Confirm that app focus and typing remain unchanged.

Existing integration points:

- `Sources/SpaceWidget/Engine/SpaceMonitor.swift`: display-scoped Space changes and
  fullscreen state.
- `Sources/SpaceWidget/Config/ConfigManager.swift`: the existing Space names.
- `Sources/SpaceWidget/App/SpaceWidgetApp.swift`: controller lifetime and startup.
- `Sources/SpaceWidget/Views/PreferencesView.swift`: native settings tabs.
- `Sources/SpaceWidget/Agents/AgentToastPresenter.swift`: existing local panel
  pattern to inspect; its completion queue and navigation stay independent.

## Acceptance criteria

- One label appears for a real Space change and shows the same name as the widget.
- A rapid A → B → C sequence ends with C; an old timer cannot hide C prematurely.
- Launch, display attachment, duplicate events, and a rename do not produce false
  transition notifications.
- The panel remains within the correct display's safe area and does not take
  focus, intercept clicks, or appear over fullscreen presentations.
- Disabling survives restart and immediately removes a visible panel.
- Native light/dark and reduced-motion behavior are checked. Existing AI hooks,
  customizable Control + Option + G, and verified Space return still work.

## Following item: Claude / Codex question popup

This remains a **feasibility investigation**, not an implementation commitment.
Investigate Claude Code CLI, Codex CLI, and each desktop app separately. For each,
record the official event/API for receiving a user question, the interface for
sending an answer, request/session correlation, supported version, and limitations.

Only propose implementation scope after both receiving a question and returning
its answer to the same session are supported by evidence. If either half is
unconfirmed, record it as unconfirmed. Hook completion events alone do not establish
interactive question/answer support. Do not fill gaps with guessed integrations.
