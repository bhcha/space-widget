# AI agent hook installation (AC 3)

Open SpaceWidget preferences → **AI Agents**. Rescan is read-only. **Install Hooks**
explicitly installs into the displayed configuration directory; **Remove Hooks** removes
only this configuration's SpaceWidget commands. No application startup or scan
installs hooks. Installation requires a supported CLI or a detected desktop app, with no
configuration-location detection errors. Desktop-only setup remains an explicit
user action: detecting the app does not establish its local Code/hook capability,
and installation does not promote it to connected before a real callback.

## Configuration and helper ownership

- Codex: `<CODEX_HOME>/hooks.json`, default `~/.codex/hooks.json`.
- Claude Code: `<CLAUDE_CONFIG_DIR>/settings.json`, default `~/.claude/settings.json`.
- The detection model supplies the selected absolute configuration directory.
  Project, managed, and session override settings are not edited.
- Existing Codex `config.toml` is never rewritten. Inline hooks remain untouched;
  Codex supports merging JSON and inline sources and may warn when both exist.
- Only SessionStart, UserPromptSubmit, and Stop command handlers are added. Existing keys, event
  groups, matcher metadata, and unrelated handlers survive. JSON formatting may
  change. A repeat install with the same effective contents leaves original bytes
  unchanged and creates no additional backup.
- Removal matches the exact SpaceWidget helper command, not a substring or a
  generic hook name. User handlers appended to the same group are preserved.
  User-edited commands no longer match ownership and are deliberately retained.
- Every changed existing config is first backed up byte-for-byte alongside it as
  `<filename>.spacewidget-backup-<UUID>` (0600). The UI displays the latest backup.
- Updates use a same-directory exclusive temporary file, fsync, and rename;
  config file permissions survive. A directory lock serializes SpaceWidget
  writers, and a precommit byte comparison rejects detected external edits.
  Other editors do not participate in the advisory lock; simultaneous external
  edits should be avoided. This is not a filesystem-wide transaction.
- Invalid/oversized JSON, incompatible hook shapes, symlink configuration paths,
  and foreign helper directories fail without replacing the config. macOS's
  root system `/var` and `/tmp` aliases are allowed.
- The explicitly installed helper is a private durable copy of the native
  executable at `spacewidget-hooks/receiver-v4`, with an integrity digest.
  It does not depend on the checkout remaining present. The helper exits before
  ordinary app startup, configuration migration, or Accessibility prompting.
- A missing helper can be restored only with bytes matching its recorded digest.
  Existing installation evidence without a digest fails closed; deleting the
  receiver or its support directory cannot authorize different code at the same
  command path. The initial digest is saved before the helper is published.
- Reinstall does **not** silently replace code behind an already approved
  command. The explicit v1/v2/v3 → v4 update uses a new versioned command path, which
  causes Codex to require approval again. The previous helper and its digest
  are verified before migration and retained for any in-flight invocation. A modified helper fails integrity
  checking; uninstall still removes its hook references.
- Uninstall retains the inert helper and backups instead of recursively deleting
  potentially user-modified directories or disrupting in-flight helpers.

## Readiness and trust

States distinguish installable, update available, installing, failure, uninstalled, approval
pending, installed/awaiting execution, and connected. `connected` currently
means an execution receipt was observed for this exact config and helper digest;
it does not mean a response succeeded or that notification/Space navigation was
verified. Changed settings invalidate the receipt. Uninstall clears it so a
subsequent install cannot reuse an earlier connection.

**Codex approval is checked in Codex.** The official hook contract requires approval
of each exact definition hash. This implementation never writes Codex trust,
invokes a bypass, or interprets successful execution as approval (execution can
also occur with a user-supplied bypass flag). No verified read-only adapter for
the installed runtime's effective exact-hash trust state is available here, so
even an execution receipt does not promote Codex to connected. Review all three
SpaceWidget hooks in Codex `/hooks`; SpaceWidget displays “Installed · Check approval in Codex” and explains
that it cannot query approval state. This label remains after approval; a real
notification can verify delivery. This is a remaining integration limitation, not
an assertion that approval was denied.

The installation health receiver accepts bounded input (256 KiB, one-second
read deadline), verifies event/session fields, and stores only config/helper
hashes. It never opens transcript paths or persists prompts, transcripts, or the
incoming JSON. Invalid, recursive, and subagent invocations cannot confirm
connection. Commands use shell single-quote escaping, a two-second agent timeout,
suppressed helper output, and nonblocking failure semantics. The Codex wrapper
always returns the neutral JSON object `{}` required by its successful-output
contract, including when the helper fails or is missing. Claude commands and
direct helper invocations remain silent. No continuation or decision field is
emitted. Event delivery and origin navigation are documented separately.

## Verification

All hook/config writes in tests use temporary fixtures. Tests cover both agents'
custom directories, unrelated settings, repeat-install idempotency, mixed group
removal, original-byte backups, atomic reader snapshots, external edits,
competing writers, malformed config, symlinks, foreign paths, quoted shell
invocation, helper errors/missing helpers, helper integrity, native executable
invocation, stale receipts/reinstallation, rejected inputs, read-only startup,
and explicit lifecycle actions. Live installation is recorded separately in
[task Space return](agent-origin-navigation.md); provider approval remains a user
action and is never established by these tests.

Run with a process-local Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Official schema and trust references checked 2026-10-16:
[Codex hooks](https://learn.chatgpt.com/docs/hooks) and
[Claude Code hooks](https://code.claude.com/docs/en/hooks).
These document provider hook support, not production validation of the combined
SpaceWidget hook/Space architecture.
