# Known issues

## Safety correction deployed: ambiguous host origins rejected — 2026-10-16 22:08 KST

- Receiver-v6 no longer selects a Space because the host app is foreground.
  Multiple host Spaces, empty memberships and All-Spaces windows remain unknown.
  An environment-only app match is also insufficient; capture requires a GUI
  process ancestor. This prevents guesses but does not recover the source window.
- The app accepts only the supported capture policy inherited from the actual
  prompt context. Legacy origins are diagnostic metadata only; neither a new
  Stop nor provider input can certify an old capture. Unknown, unverified and
  unavailable destinations display separate explanations and cannot navigate.
- Final suite: 125 tests, 121 passed, 4 opt-in skipped, 0 failures. Signed debug
  app running with Accessibility trusted; both hook configurations upgraded via
  the normal installer, preserving old helpers and unrelated settings. Codex
  approval and provider configuration reload remain runtime steps.
- The native Ghostty notification click check remains unverified because the
  computer-use tool denied Ghostty access for safety reasons. Manual user
  verification was requested. No bypass was attempted.
- Evidence and remaining limits: [resolution plan](agent-origin-resolution-plan.md),
  `output/qa/origin-safety-v6/`. The governance Unknown Space incident below
  remains open; this correction must not be described as complete source recovery.

## Open: `Unknown Space` in the text2sql completion toast

- Reported: 2026-10-16, during Space label animation implementation.
- Project: `text2sql`.
- User report: “hook토스트 떳는데 언논 스페이스가 또 떳어. text2sql쪽이었어.”
- Observed by the user: a hook completion toast appeared, but its destination
  was displayed as `Unknown Space` again.
- Status: recorded for investigation; not diagnosed or fixed.
- Provider, terminal/app, exact completion time, and navigation result were not
  specified in this report. Do not infer that this is the same cause as the
  earlier Space return bug.
- Follow-up: correlate the text2sql request-start and completion events with
  captured origin Space/app metadata, helper version, and Space return logs.
  Do not substitute the current Space when the original destination is unknown.

### Recurrence investigated — 2026-10-16 13:39 KST

- The user reported another `text2sql` completion showing `Unknown Space`.
- The Codex v4 spool contains a `SessionStart` at 13:37:41.392 and
  `UserPromptSubmit` at 13:37:41.448, both without `application` or `origin`.
  Its matching `Stop` deduplication key was recorded at 13:39:08.984.
  This establishes missing capture at request start, not loss of a valid
  destination during completion delivery.
- This request's session key differs from the text2sql terminal's main thread.
  The main thread has a separate 11:31:02 SessionStart with Ghostty and an origin;
  that older origin must not be copied into another request merely because the
  project name matches.
- The main text2sql thread invoked Ouroboros evaluation at 13:37:33; the
  evaluation log records `CodexCliLLMAdapter` starting at 13:37:36 and its job
  completes at 13:39:10. This timing suggests an internal evaluation completion,
  but the exact worker session linkage is not established by the saved metadata.
- The user has been asked whether the observed completion was the main Codex
  answer or an internal review/background task. Do not suppress all unknown
  events or infer a destination until this distinction is established.
- Status: capture failure localized; no hook fix applied or live fix verified.
  Evidence snapshots are local in `output/qa/text2sql-unknown-space/`.

### Wrong destination investigated — 2026-10-16 14:21 KST

- User report: clicking a `text2sql` completion navigated to `SD`.
- The saved spool's deduplication history proves UserPromptSubmit at
  **13:41:59.762** and Stop at **14:21:05.164** for the same request.
- The text2sql rollout records `compacted` at **13:58:34.461**, followed by the
  same active turn context at 13:58:34.462. The spool has a SessionStart at
  **13:58:34.482**, with SD UUID
  `C4DC8834-8FE9-4744-BE5E-F85A4C4EE5DE`. Its earlier prompt context is absent.
- v4 removed every context in a session on SessionStart, then allowed Stop to
  fall back to the SessionStart origin when no prompt remained. This explains
  how mid-turn compaction could replace a task's origin with SD. The original
  prompt's captured UUID has been erased, so it cannot be recovered from this
  spool. Do not claim that earlier capture itself was correct.
- Runtime navigation requested SD at **14:21:12.083**, then confirmed actual
  Space ID 5 at **14:21:12.656**. Existing logs lack notice IDs, so the clicked
  toast linkage is temporal evidence rather than an exact prior trace.
- Fix: receiver-v5 retains identified request contexts across SessionStart,
  handles explicit compaction for no-ID prompts, and removes SessionStart-only
  navigation fallback. An unknown source stays unknown rather than redirecting.
- Added persistent metadata-only tracing across capture, correlation, delivery,
  toast selection and actual arrival. See [diagnostic guide](agent-hook-diagnostics.md).
- Validation: full 117-test run passed (2 opt-in tests skipped); the added native
  round-trip test then passed against the actual text2sql UUID
  `29B36BD5-AC99-46CF-8BD7-8AF81CA567EE`: two arrivals and two returns to studio,
  all confirmed by stable UUID observations. This tests native navigation;
  a fresh real text2sql completion is still needed to verify its entire hook path.
- Deployment: signed debug app restarted at 14:49:20, Accessibility trusted;
  default Codex and Claude installations upgraded to receiver-v5 with config
  backups and unchanged receiver-v4 binaries. Codex command trust was not edited.
- Status: diagnosed path fixed and deployed; awaiting a fresh user completion
  trace. The separate detached/background Unknown Space report remains open.
- Evidence: `output/qa/text2sql-unknown-space/20261016-143309/`,
  `full-tests.log`, `native-test.log`, `native-roundtrip.jsonl`, and
  `installed-helper-result.json`. The helper fixture ran outside watched
  configurations, did not generate a production toast, and correctly remained
  unknown without GUI ancestry; it verifies delivery/correlation, not capture.
- Follow-up verification: the installed v5 binary also handled a real subprocess
  sequence `SessionStart → UserPromptSubmit → SessionStart(compact) → Stop`
  with exact-turn context retained (`installed-helper-compaction-result.json`).
  The final diagnostic suite passed 5 tests, with its native-only test skipped
  in the ordinary run; that native test passed separately as described above.
  Wrong-arrival coverage asserts both the requested text2sql UUID and observed
  SD UUID with a failure result. Release build and code-signature verification
  passed; both installed v5 helpers match the signed running build, and both
  v4 helpers still match their original integrity records.

## Open: governance Unknown Space with Ghostty in the background — 2026-10-16 21:28 KST

- User confirmed that this recurrence was **governance**, not text2sql.
- At **21:14:04.847**, an earlier governance prompt captured
  `C8E3EFE3-BF58-B901-4283-350445142C65` with `host_foreground`; its completion
  resolved successfully at 21:18:13.646.
- At **21:27:40.421**, the new prompt's `capture.completed` records
  `ambiguous_host_windows`, `foreground_pid=37471`, `host_pid=7856`, and no
  origin. Read-only process inspection identifies these as **Google Chrome**
  and **Ghostty**, respectively. Ghostty had 12 enumerated windows: four with
  distinct navigable Space memberships and eight without a usable membership.
- Host resolution itself succeeded through actual process ancestry:
  helper → Claude (PID 18392) → shell → login → Ghostty. The failure is selecting
  the originating window/Space within that host while another app is foreground.
- At **21:28:17.304**, Stop matched this exact prompt (`exact_turn`), preserving
  its unknown origin. At **21:28:17.639**, the app reports `missing_capture` and
  displays the unknown notice. This is not compaction overwriting a valid origin,
  loss during transport, or an attempted navigation failing.
- The active Claude process environment contained TERM_PROGRAM=ghostty and
  version 1.3.1, but none of the checked terminal/surface identity variables
  (`GHOSTTY_SURFACE_ID`, `GHOSTTY_SESSION_ID`, `ITERM_SESSION_ID`,
  `TERM_SESSION_ID`, `TMUX_PANE`). No other environment values were printed.
- Ghostty's installed scripting dictionary exposes terminal ID, name and working
  directory but no PID/TTY property. Its [official AppleScript documentation](https://ghostty.org/docs/features/applescript)
  describes those properties. This does not establish a reliable association
  between this hook process and one window. No new association mechanism has
  been implemented or validated. Never infer an exact origin from a project
  basename, the last session location, or the currently focused Ghostty window.
- **Status: cause confirmed; not fixed.** The current capture implementation
  cannot reliably identify this background Ghostty request's source Space.
  Whether the user switched to Chrome immediately after submitting or submitted
  through another input route is not established by these logs.
- Event trace: `c0bfa7b2049e5e051762048e76de5e32590b300fb3138f6c27632d6f6b3a4c27`.
  Matched capture: `bae8ccc1c3a5640c93f7f7096eab5756656f3e29f8716297dab256a7430e0665`.
- Evidence snapshot: `output/qa/text2sql-unknown-space/20261016-212922-recurrence/`.
- Follow-up Claude review: [origin resolution decision and plan](agent-origin-resolution-plan.md).
  Ghostty's upstream PR #11922 adds terminal PID/TTY properties, but the installed
  and currently listed stable version 1.3.1 does not include them. Native
  Ghostty notification routing was confirmed in source; neither a live native
  notification round trip nor SpaceWidget integration was validated by this review.

### text2sql recurrence and settings notice — 2026-10-17 09:58 KST

- The user reported another Unknown Space notification. Trace
  `c7e806ef1b10` (Claude, text2sql) Stop at **09:58:06.249** matched its prompt
  `61141d8fc263` (`exact_turn`) and was displayed with `destination_uuid=none`.
- The prompt at **09:57:43.788** ran receiver-v6 (`helper_version=6`). Host
  resolution succeeded by ancestry (`host_match=ancestor`, Ghostty PID 7856), and
  Ghostty was also the foreground app on the text2sql Space
  `29B36BD5-AC99-46CF-8BD7-8AF81CA567EE`. Capture still returned
  `ambiguous_host_windows`: 12 Ghostty windows, four on distinct Spaces
  (governance, SD, text2sql, space-widget) and eight without usable membership.
- This is the intended v6 behavior, not a transport or compaction loss: v6 no
  longer selects the foreground Space. It shows the documented cost — Unknown
  appears even when the request plausibly came from the foreground window.
- Codex was still running **receiver-v5**: trace `b7589494ec5f` (space-widget,
  09:58:35) recorded `helper_version=5`, `host_match=environment` and
  `capture_reason=host_foreground`. The v6 hook definitions are not yet active
  in that Codex session (approval or hook reload pending).
- Terminal comparison (read-only scripting dictionaries on this Mac): Ghostty
  1.3.1 exposes terminal ID, name and working directory but no TTY/PID.
  Terminal.app 2.15 exposes a tab `tty` property. iTerm2 is not installed and
  was not checked. Mapping a TTY to a window and then a Space was not implemented
  or tested for either app; whether the scripting window ID equals the
  CGWindowID is unverified. tmux/screen would hide the terminal's own TTY.
- Settings notice added under `AI Agents → Notifications`: "Some terminals cannot
  report which window started a task. In Ghostty, when its windows are on more
  than one Space, the notification shows Unknown Space and cannot return to it."
  Only Ghostty is named because only Ghostty was verified. Xcode-toolchain debug
  build and full suite passed (125 tests, 4 opt-in skipped, 0 failures). The
  running app was not restarted, so the notice is not yet visible.
- Status: unchanged — cause confirmed, not fixed. Options under consideration:
  keep v6 as is, or narrowly accept the host's key window at submit time.
  No decision has been made.

## Fixed in app: saved Space moved to a different display — 2026-10-16 evening

- Separate text2sql completions at **20:20:24** and **21:07:00** matched their
  prompts exactly and retained Space UUID `29B36BD5-AC99-46CF-8BD7-8AF81CA567EE`,
  but reported `space_unavailable`. The saved display changed between
  `A2A82799-331A-4C9C-9A10-7BD26954AF16` and
  `37D8832A-2D66-02CA-B9F7-8F30A301B230` across the recorded prompts.
- A live read-only snapshot confirms that the text2sql UUID now belongs to the
  first display; the second display is also connected but contains a different
  desktop. Requiring the captured display ID as well as the UUID incorrectly
  rejects a Space that has migrated between displays.
- App resolution now finds a unique UUID among live displays and uses its
  current display for the notice, switch and arrival verification. Multiple
  matching UUIDs and disappeared Spaces remain unavailable. A display change
  during a switch fails verification rather than confirming the old display.
- New `destination.resolved` diagnostics record the captured and current display,
  UUID match count and live Space map. This change is app-side; installed v5
  receiver commands and their approval state do not need modification.
- Automated tests cover display migration, duplicate UUIDs across displays,
  changed display during navigation and querying the correct live display.
  A read-only native test replayed the old captured display against the actual
  current text2sql UUID and resolved it successfully. It did not move the screen.
- This correction does **not** fix the governance missing-capture case above.
- Validation/deployment: full suite 122 tests, 118 passed and 4 opt-in tests
  skipped; read-only live migration test passed separately. Signed debug app
  restarted as PID 42933. The v5 hook helpers and command approvals were left
  unchanged. Evidence and build/test logs are in the recurrence snapshot folder.
