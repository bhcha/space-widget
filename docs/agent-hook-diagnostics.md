# Agent hook destination diagnostics

The app and receiver-v6 append metadata to
`~/.config/space-dock/agent-hooks.jsonl`. The journal survives restarts, rotates
to `.jsonl.1`, and is bounded to 2 MiB per file. Files use mode 0600. Writers
share a lock with a maximum 20 ms wait; diagnostics are best effort and must
never block the coding agent. This journal is independent of `spacewidget.log`,
which is truncated at process startup.

No prompt, response, transcript path, full working directory, raw session/turn
ID, window title or environment dump is logged. Project basenames, application
bundle IDs, process/window IDs and Space UUIDs are included. Session, request
and event identities are hashes, for correlation rather than display.

## Follow a completion

```bash
python3 scripts/trace-agent-hooks.py --project text2sql
python3 scripts/trace-agent-hooks.py --trace <event-trace-prefix> --json
```

The script includes the matched request capture using `context_trace`.

| Stage | Evidence |
| --- | --- |
| `receiver.started/parsed/finished` | Invocation ID, helper version, accepted input metadata and outcome |
| `capture.completed` | Parent PIDs, ancestor/environment host selection, foreground PID/UUID, window IDs and memberships, capture reason |
| `context.staged` | Request snapshot staged inside the spool transaction |
| `context.resolved` | Exact turn/no-turn match, matched capture trace/age, or why no destination was selected |
| `transport.committed` | The transaction was written successfully; staged records alone do not prove this |
| `app.received/destination/delivered` | Event consumed, live destination resolution, notice ID and project title |
| `destination.resolved` | Captured/current display, UUID match count and live Space map, including display migration |
| `destination.rejected` | A captured origin lacks the supported capture policy (`unverified_capture`) |
| `toast.queued/displayed/activated` | Queue versus visible notification, exact notice ID, click versus shortcut |
| `toast.activation_ignored` | Stale click, missing destination or in-flight activation |
| `navigation.requested/observed/finished` | UUID → runtime Space ID mapping, actual observed UUID changes and final result |
| `toast.navigation_finished/dismissed` | Action result and dismissal/timeout |

`trace` joins a single event through helper, app, toast and navigation.
`request` joins a prompt and Stop carrying the same provider turn ID.
`context_trace` points to the exact request capture used by Stop, including
providers without turn IDs. `notice` distinguishes individual displayed toasts.
`origin_capture_policy=single_host_space_v1` identifies the v6 capture rule.
Stop inherits this field from the matched prompt; it cannot certify a legacy
capture. Provider payloads cannot supply it. Missing/unsupported policy prevents
navigation even if a historical UUID still resolves.
Raw navigation observations use UUIDs because Mission Control can reorder
ordinals. Compare with `space_labels.json` to interpret user labels.
Destination resolution follows a unique UUID across live displays. A captured
display ID is historical metadata: monitor changes must not make the same
desktop unavailable. Duplicate live UUIDs remain ambiguous.

## Context rules

- Stop never captures the current desktop.
- An exact matching prompt is preferred. Providers without a turn ID can use
  the most recent compatible prompt, never an older no-ID prompt behind a newer
  identified request.
- SessionStart alone cannot authorize navigation. Missing request capture stays
  unknown (`session_start_rejected` or `no_prompt_match`).
- SessionStart preserves identified request contexts. A `source: compact` also
  preserves no-ID prompt context. Other starts clear no-ID context to avoid
  reusing a prior session location.
- Unknown capture on a new request replaces that request's stale location.
- Contexts remain bounded to 128 entries/24 hours. Unsupported/detached GUI
  ancestry can still produce Unknown Space; project names are not destinations.
- A known terminal host remains unknown when its windows span multiple Spaces
  or include unusable memberships, even if that app is foreground. Foreground
  metadata is diagnostic only; it cannot identify the terminal that emitted the
  hook. Every enumerated host window must share one navigable Space to produce
  `single_host_space`. Exact-turn matching cannot recover missing source identity;
  this remains open for the governance/Ghostty 1.3.1 report.
- `host_match=environment` is only an app-name hint. Without an actual GUI
  process ancestor, capture returns `unverified_host` and no origin, even if
  the hinted app has only one Space. Detached shells may retain stale terminal
  environment values after reattachment.
- The app distinguishes `missing_capture`, `unverified_capture` (legacy or
  unsupported policy), and `space_unavailable`. All produce a non-navigable
  notice with the corresponding explanation.

Codex documents that automatic compaction can emit SessionStart in the middle
of a turn: [OpenAI hook lifecycle](https://learn.chatgpt.com/docs/hooks#sessionstart).
The local v4 implementation incorrectly deleted active request snapshots on
every SessionStart; v5 corrects this.

## Validation and reproduction

Automated coverage includes overlapping projects, click/shortcut correlation,
stale toast callbacks, wrong completion-time foreground, mid-turn compaction,
missing prompt capture, out-of-order turns, journal persistence/rotation,
concurrent writes and content exclusion.

An optional native test switches to a specified UUID and back twice. Only run
it when real desktop movement is intended; it requires existing Accessibility
permission and never requests it:

```bash
SPACEWIDGET_QA_TARGET_UUID=<destination-uuid> \
SPACEWIDGET_QA_TRACE_PATH=/absolute/path/native-trace.jsonl \
swift test --filter HookDiagnosticsTests.testOptInNativeRoundTripRecordsActualArrival
```

For the full live path, submit a new request from the project's Space, move to a
different Space, then click its completion toast or press the configured Go
shortcut. Inspect the new prompt/Stop `request`, matched `context_trace`, notice
ID and final actual UUID together. A successful switch to a wrong captured UUID
is a capture/correlation failure, not proof of correct project navigation.

Helper upgrades use a new immutable command path. Previous helpers are preserved;
Codex requires approval of the new receiver-v6 definitions. Old sessions may need to reload their
hook configuration. An execution receipt alone does not establish Codex trust.
An already-running older receiver can drop the new optional policy field when
rewriting the shared spool during an upgrade. The new app treats that as
unverified, never as a reason to guess. Reloading the hooks and submitting a new
request is required to establish new capture evidence.
