# Agent response notifications

**Preferences → AI Agents → Notifications** controls response toasts, optional macOS Glass
sound, preview, and the configurable navigation shortcut (default **⌃⌥G (Control + Option + G)**).
No Warcraft audio assets are bundled.

## Display

The display follows PeonPing's default Stop notification:

- Title: project name, with a small blue indicator.
- Body: `done` (the agent's response ended; it does not certify task success).
- Supporting metadata: agent name, source app, and request Space when known.
- Action: **Go to Space 1** (the captured Space's current number), plus the registered shortcut.
  A known app without a known Space is not actionable; app activation can select
  the wrong project window when an app has windows on multiple Spaces.

Session IDs remain internal correlation/dedup keys and never appear in the toast.
Project labels use `CLAUDE_SESSION_NAME`, a local `.peon-label` first line, the Git
origin repository name, then the working directory's final component. Labels
are limited to 50 characters; Korean is preserved and control/bidi formatting
characters are removed. Git worktree common directories are supported. Repository
metadata is read locally with bounded regular-file reads. No git subprocess,
project script, transcript, prompt, assistant response, full path, or remote URL
is retained. PeonPing's optional scripts/templates/rename state are not executed
or imported. Unknown project labels explicitly show **Unknown project**.

Reference checked 2026-10-16:
[PeonPing source](https://github.com/PeonPing/peon-ping/blob/main/peon.sh),
project resolution and Stop → notification_message(status) code. This borrows the
presentation, not a claim that PeonPing validates SpaceWidget's navigation.

## Transport

The app polls each configured agent's `spacewidget-hooks/events-v1.json` once per
second away from the main thread. CODEX_HOME / CLAUDE_CONFIG_DIR match detection.
The spool retains at most 64 events and 512 dedup entries, with private permissions,
atomic writes, nonblocking locks, bounded input and output, and no network delivery.
Stored metadata includes provider, hashed config source, session, event, optional
turn/prompt ID, receipt time, project label, optional display/Space UUID, and
optional source app bundle ID, PID, and display name. Old spool files decode
without inventing a location or app.

`SessionStart` and `UserPromptSubmit` record the app and optional Space; only
`Stop` produces a completion toast. Stop uses the saved request context rather
than sampling the current foreground app. See [task Space return](agent-origin-navigation.md).
Recursive Stop and explicit subagent IDs are rejected. `agent_type` alone can
identify a primary named Claude agent and is accepted. Provider turn IDs enable
24-hour bounded retry suppression; without them, suppression is limited to two
seconds. This remains best-effort local delivery, not an exactly-once guarantee.

Events from before the app started require the existing explicit **Show Pending**
or **Discard Pending** choice. The visible toast and up to 128 pending toasts form a
FIFO. Each is shown for 10 seconds. Dismiss, timeout, or successful navigation
advances the queue; overflow discards the oldest pending item. Disabling
notifications clears the current and pending notices. Preview never navigates.

Tests use temporary agent configurations, isolated preferences, mocked navigation,
and native rendering. They do not install live hooks or establish real provider
approval, audible output, or cross-Space navigation.
