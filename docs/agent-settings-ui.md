# AI Agents preferences

Open the SpaceWidget menu bar menu → **Preferences… → AI Agents** (the last tab).
The screen uses the same native macOS styling as the other preference tabs:
20-point padding, headline/subheadline text, a standard GroupBox, bordered
buttons, and checkbox controls. The shortcut row reuses ShortcutRecorderView
and the existing clear/restore pattern. There are no custom colored agent cards
or oversized headings. All built-in labels, status/error messages, help, and
notification preview text are English; user-provided project names are preserved.
Runtime paths, versions, support details, and backups remain in disclosures.
The earlier mockup is preserved as a historical artifact.

- **Install Hooks / Update Hooks / Retry** is enabled for a supported CLI or a detected desktop app with no detection
  issues and no active scan/install. Desktop capability remains unknown until
  verified; ordinary Claude Chat is not a hook target. Merely opening settings cannot install hooks.
- **Installing...** uses indeterminate native progress; no fabricated percentage or
  installation stages are displayed.
- **Approval Help** explains Codex `/hooks` and SessionStart/UserPromptSubmit/Stop approval. It never
  sets connected state. The current installer cannot independently observe Codex's
  approval hash and therefore keeps “Check approval in Codex” visible even after an execution receipt,
  with an explanation that approving in Codex does not clear this observation limit.
- **Installed · Waiting for a hook in a new session** asks for a new local Code session and rescan.
  **Connected** only reflects the existing installation model's observed readiness.
- **Remove Hooks** is available for installed/pending/failed states, including recovery
  from a partially failed installation. Errors remain visible with retry and
  inspection controls. Configuration backups are exposed in the disclosure.
- Preview is a local test toast, not proof of hook execution or origin mapping.
  Turning off notifications disables preview and sound controls without erasing
  the saved sound preference. Stop means response ended, not task success.
- Claude ordinary Chat does not support Code hooks. Desktop detection alone does
  not establish Code capability. OpenAI is Codex's provider, not another agent.

## Current task Space return (2026-10-16)

**Go to Space** uses the saved request Space UUID and display identifier.
The toast shows the destination number, such as **Go to Space 1**. The default
remains **⌃⌥G**, configurable and registered only while an actionable toast is
visible. A known app without a known Space cannot enable navigation. No window
picker is added. App activation was removed after a live test selected another
Ghostty window; successful app activation does not establish Space arrival.

The existing v4 helpers already capture both Space and app metadata, so this
navigation fix requires no hook migration or new Codex approval.

## Superseded app return attempt (2026-10-16)

This attempt activated the source app using the PeonPing Ghostty path's
AppKit operation. **Go to App** retains the configurable **⌃⌥G** default and
visible-toast-only registration. A captured app is sufficient for navigation;
missing Space metadata does not disable the action. macOS chooses the existing
window when an app has windows on multiple Spaces. No window picker is added.

The v4 helper captures app identity at request start. Existing v1/v2/v3 hooks
offer **Update Hooks**; the new command identity requires Codex approval again.
Opening preferences still cannot install or update hooks. Native light/dark
settings and an actionable toast were rendered under
`output/qa/agent-app-return`; these are test fixtures, not live app screenshots.

## Earlier Space return verification (2026-10-16)

The window picker and manual association were removed at the user's request.
Toasts now show project → done → agent/Space, matching PeonPing's default
project/status hierarchy. **Go to Space** provides a recorder and enable
checkbox, defaults to **⌃⌥G (Control + Option + G)**, and is reserved only while an actionable toast
is visible. Existing installed v1 hooks offer **Update Hooks** to add prompt-time
Space capture and the versioned v2 helper; Codex requires approval of the new
commands. Opening preferences still cannot install or update hooks.

Native SwiftUI settings captures use fixture agents at 580×660 in light/dark,
plus a full-height capture in `output/qa/ai-agent-settings-v2`. They are renders
of the real view in a test host, not screenshots of the live preferences window.
The previous `output/qa/ai-agent-settings` images and mockup predate this change.

Verification: `swift test` passed all 73 tests with zero failures;
`make verify-build` passed the release build using the per-command Xcode toolchain.
The revised settings and actionable project toast were visually reviewed.
Real hook approval/callback and live cross-Space movement are not established
by the fixture tests. No live agent settings are changed by verification.

The updated debug application was restarted after verification. Read-only runtime
inspection found existing v1 SpaceWidget hooks for both Codex and Claude Code.
Those live configurations were left unchanged: use **Update Hooks** to install
the v2 capture helper and UserPromptSubmit hook, then review the new Codex hook
commands in `/hooks`. The updated app alone cannot upgrade immutable v1 helpers.

## Native appearance and English copy (2026-10-16)

Related existing tests passed: 54 tests across settings, detection, hook installation,
notification presentation, navigation, and shortcuts. The four settings tests were
rerun after the final native-background rendering adjustment and passed. Native
light/dark snapshots at 580×660 were visually reviewed at
`output/qa/ai-agent-settings-native/settings-light.png` and `settings-dark.png`.
All controls fit at that size with collapsed support details. The snapshots use
fixture agents in a native test host; they do not install hooks.

The release build passed after the appearance update. The debug app was restarted
successfully, with Accessibility trusted=true reported in the startup log.

Default shortcut updated to Control + Option + G (Go). A visible toast temporarily
takes priority over the matching window shortcut; dismissal restores it. The
release build and 15 relevant settings, queue, shortcut, and native Carbon routing
tests passed. The updated debug application was restarted.
