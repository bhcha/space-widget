# Agent origin resolution: Claude review and decision

Date: 2026-10-16. Status: **safety correction deployed; governance source identity
remains unresolved**. The original review below was analysis only. The user
subsequently authorized implementation; its outcome is recorded here.

## Implementation outcome — 22:08 KST

- Removed foreground state from Space selection. Every enumerated host window
  must have exactly one usable membership, all on the same Space.
- Claude's implementation review identified another unsafe inference: an
  environment-only host match. Capture now requires actual GUI process ancestry;
  an environment hint can display the app name but yields `unverified_host` and
  no destination. A regression test covers stale detached-terminal environment.
- Receiver-v6 stamps `single_host_space_v1` on its local capture. The matched
  prompt context carries that evidence through Stop. Legacy queued events and
  contexts remain readable but cannot authorize navigation without the policy;
  a new Stop or provider payload cannot retroactively certify them.
- Missing capture, unverified capture, and unavailable Space have distinct
  diagnostics and English explanations. Click and shortcut remain disabled when
  no verified destination exists.
- Final full suite: **125 tests, 121 passed, 4 opt-in tests skipped, 0 failures**.
  The final debug build passed and its SpaceWidgetDev signature verified.
- Running app restarted as PID **93756**, with Accessibility trusted. Both
  default provider configurations now reference `receiver-v6`; its bytes match
  the signed app. Previous v4/v5 bytes and unrelated provider settings were
  verified unchanged. Configuration backups were created by the normal installer.
  Codex still needs approval of the new hook definitions; old sessions must
  reload hooks and a new request must capture its origin.
- **Native Ghostty notification click verification is incomplete.** Computer Use
  rejected `cua.getApp("Ghostty")` for safety reasons. No alternate-control bypass
  was attempted. Manual user verification was requested; no successful result
  has been reported for this test yet.

Evidence: `output/qa/origin-safety-v6/` contains the final test/build logs,
installation hashes/config comparison, deployment metadata, and actual Claude
review. This deploy prevents unsupported guesses; it does not identify a source
terminal among several Ghostty Spaces, so Unknown will be more frequent.

## What failed

The governance prompt at 21:27:40 had a valid process ancestry ending in Ghostty,
but Ghostty had windows on four different Spaces and Chrome was foreground.
Capture returned `ambiguous_host_windows`. Its completion at 21:28:17 matched
that exact request and retained the missing origin. This was a source-capture
failure, not a failed Space switch or lost completion event.

See [incident evidence](known-issues.md#open-governance-unknown-space-with-ghostty-in-the-background--2026-10-16-2128-kst).
The separate compaction-context and monitor-migration fixes do not fix this case.

There is another correctness risk in `AgentSpaceCapture.select`: the foreground
Space wins if any host window occupies it. For a background request from terminal
A while another Ghostty terminal B is foreground, that rule can record B. The
code establishes this counterexample; the governance incident does not establish
that this particular wrong selection occurred in production.

## What the upstream evidence establishes

| Evidence | Established scope | Does not establish |
| --- | --- | --- |
| Installed Ghostty 1.3.1 scripting dictionary and v1.3.1 source | Terminal UUID, name, working directory and focus commands exist; terminal PID/TTY properties are absent | A reliable association from the hook's process to one terminal |
| [Ghostty PR #11922](https://github.com/ghostty-org/ghostty/pull/11922) | PID/TTY properties were merged into upstream main on April 20, 2026; the contributor reports comparing returned values with process metadata | Availability in installed 1.3.1, enterprise production validation, or SpaceWidget integration |
| [Ghostty download page](https://ghostty.org/download) and [release notes](https://ghostty.org/docs/install/release-notes) | Both list 1.3.1 as the latest stable version when checked | A released stable upgrade containing the new properties |
| [Anthropic terminal documentation](https://code.claude.com/docs/en/terminal-config#get-a-terminal-bell-or-notification) | Claude Code has built-in desktop notifications specifically supporting Ghostty; delivery depends on its notification timing/away conditions | Every Stop hook producing an immediate alert, SpaceWidget's presentation, or its shortcut |
| [Ghostty v1.3.1 notification source](https://github.com/ghostty-org/ghostty/blob/v1.3.1/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift#L1676-L1732) and [click routing](https://github.com/ghostty-org/ghostty/blob/v1.3.1/macos/Sources/Ghostty/Ghostty.App.swift#L2219-L2235) | Native notifications store their emitting terminal's UUID; a click looks up that surface and brings its window forward | A live cross-Space test in this environment, or a public bridge exporting that UUID to SpaceWidget |
| [OpenAI TUI documentation](https://learn.chatgpt.com/docs/config-file/config-advanced#tui-options) | Codex supports terminal notifications using `auto`, `osc9`, or `bel` | End-to-end Ghostty/SpaceWidget routing in this installation |

Upstream main checked: `b3dc3d794513c11633e7c3347935693957744e83`.
PR merge commit: `afdae7293abfdf5daa684dc50c35420b61a1d575`.
Local versions: Ghostty 1.3.1, Claude Code 2.1.301, Codex CLI 0.163.0.
The governance Claude process had controlling terminal `ttys001`; knowing that
does not by itself identify its Ghostty terminal in the installed version.

The user's evidence standard is not met for the complete custom integration:
we found no qualifying recognized-company deployment of an external hook
resolving Ghostty's exact macOS Space and driving a separate app's toast and
shortcut. A merged upstream feature is not such a deployment. Do not describe a
combination of these components as a validated architecture.

## Prioritized plan

### 1. Correct unsafe selection before claiming more coverage

Implemented narrow correction: do not allow foreground state to select one Space
when the host has multiple candidate Spaces or unusable window memberships.
Keep the existing conservative single-host-Space case. Add regression coverage
where an A request arrives while B is foreground; the ambiguous input must
return unknown, never B solely because B is foreground.

This reduces incorrect destinations and will increase Unknown notices. It does
not recover the missing identity and must not be presented as the root fix.

For missing capture, English explanation:
`Could not determine the Space where this task started.`
Do not label every failure as a background request: foreground capture can also
be ambiguous. Preserve distinct reasons for unavailable Space, permission
failure, and navigation failure. Record identity evidence and failure stages,
not prompt text, terminal titles, or full environment dumps.

This correction was implemented after the review and explicit user instruction.
It uses a new immutable receiver-v6 path and the normal installation/trust flow;
approved receiver-v5 files were not modified in place.

### 2. Verify the existing native notification option separately

The documented Claude Code-to-Ghostty notification feature is an existing
product option. Verify its actual click behavior on this Mac before treating it
as a usable interim return path. Do not introduce a new escape-sequence helper,
parse another app's notification database, or advertise this as SpaceWidget's
feature. Codex needs its own verification; its documented OSC 9 setting alone
does not prove this installation's behavior.

The native option does not provide SpaceWidget's custom toast, project/Space
format, Ctrl+Option+G, or desktop-app coverage. It focuses a currently live
terminal; after the window moves, that differs from returning to the Space
captured when work started. Notification suppression, removal after focus,
terminal closure, and Ghostty restart can also end its usefulness.

### 3. Keep the full custom feature pending the missing evidence

Ghostty has already implemented the first missing API upstream; it is incorrect
to say that Ghostty can never expose this information. Track stable availability
of PID/TTY properties. Do not install a prerelease or custom build as part of
this investigation.

Even when those properties ship, our own integration still requires evidence
for source-process identity, terminal lifetime/reuse, and mapping the scripting
window identity to the Space used in the toast. A terminal focus command alone
does not provide that Space label. The upstream window's opaque UUID is not
established as a CGWindowID. These are remaining requirements, not an approved
experimental design or a proven implementation plan.

Project names, cwd, window titles, the last session location, and whichever
window is currently foreground do not establish source identity. Do not add
them as fallback destinations. Do not restore manual window connection.

## Acceptance criteria for an eventual full fix

- Submit from a known Space while Chrome is foreground and Ghostty spans several
  Spaces: identify the actual source or explicitly fail; never choose a different
  Space from foreground state.
- Repeat while another Ghostty window is foreground and with two sessions in
  the same project. Project equality must not merge their origins.
- Move a terminal between requests, resume a session elsewhere, restart the
  terminal, and compact a conversation: stale process/terminal identities must
  not silently carry forward.
- Preserve the current start-Space semantics. Moving a window after capture
  must not silently redefine the destination. A deleted/unresolvable Space is
  unavailable; a unique surviving UUID on another monitor resolves there.
- Click and Ctrl+Option+G act on the same displayed notice and verify the same
  intended destination. Test real source capture, not only synthetic events
  with an already supplied UUID.
- Report incorrect destinations and unknown origins separately. Passing several
  navigation tests is not proof that source capture is correct.

No live native-notification click was verified. The implementation tests and
build are recorded above; prior native navigation tests remain evidence for
switching only, not correct multi-window source identity.

## Review record

The installed Claude Code CLI was consulted through the read-only
`paseo-advisor` skill in three completed rounds (all returned success with no
permission denials). Actual advisor responses and fetched upstream source are
saved under `output/qa/claude-origin-review/`. The final round agreed that the
foreground counterexample justifies rejecting that inference without waiting
for another user-visible wrong navigation. Temporary prompts/diff context were
removed after review; response records were retained.

We corrected two unsupported inferences during review: a scheduled-task file in
this repository does not explain the governance request, and following a moved
window is not an established replacement for the current start-Space behavior.
Whether the governance user switched to Chrome immediately after submitting or
the request arrived through a queue/automation remains unknown.
