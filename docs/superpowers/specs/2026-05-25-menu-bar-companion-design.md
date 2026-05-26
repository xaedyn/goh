# Menu Bar Companion Design

**Goal:** define the Mac-native menu bar companion for `goh` before any UI
implementation begins.

**Status:** product direction only. This spec adds roadmap clarity; it does not
freeze a wire protocol, target name, package layout, or UI implementation.

## Product Role

The companion is a small native Mac cockpit for `goh`, not a replacement for the
CLI. It exists for users who want persistent visibility, quick control, and
completion/failure awareness while the daemon does the real work.

The daemon remains the source of truth. The companion does not download bytes,
own a queue, persist job state, or maintain a separate model. It talks to `gohd`
through the same XPC command surface and progress subscription model as `goh`
and `goh top`.

## Shape

The first version should feel like a calm, useful menu bar app:

- a quiet status-bar icon, optionally showing active state or count;
- a compact popover on click, not a full window by default;
- a daemon/status header with active count and aggregate speed;
- a quick-add row for "Add URL from Clipboard" and pasted URLs;
- a concise job list with filename, state, progress, speed, and destination;
- per-job controls for pause, resume, remove, and reveal in Finder;
- a command to open the terminal dashboard via `goh top`;
- completion, failure, auth-needed, and cellular-auto-pause notifications.

The product should feel native, restrained, and operational. It should avoid a
busy dashboard, decorative UI, or settings sprawl.

## Expected Controls

The popover should support:

- start or connect to the daemon when it is unavailable;
- add a download from clipboard or a pasted URL;
- pause and resume individual jobs;
- remove a job, with a safe path for keeping partial files when relevant;
- reveal completed files in Finder;
- open the downloads folder;
- open `goh top` in Terminal for the full terminal dashboard;
- quit the companion without stopping active daemon work.

Daemon start/stop behavior must be designed carefully around the installed
channel. A Homebrew install may need `brew services`; a future app/PKG channel
may use a different service registration path. The companion should explain the
right action for the detected install mode instead of guessing silently.

## Error States

The companion should make daemon and job failures understandable:

- daemon unavailable: show whether the daemon is missing, unloaded, or not
  responding, with the exact next action;
- protocol mismatch: tell the user the companion and daemon builds differ;
- Full Disk Access needed: route Safari-cookie import failures to clear
  permission guidance;
- cellular auto-pause: show that the job is paused by policy, not broken;
- job failure: show a short reason and keep detailed diagnostics one click away.

Error messages should use the same underlying error model as the CLI so the
terminal and companion tell the same truth.

## Boundaries

The companion should not become:

- a second download engine;
- a full-featured GUI clone of an existing download manager;
- a browser-cookie manager;
- a plugin host;
- a mandatory component for CLI-only users;
- a workaround for daemon design issues.

The right split is: daemon owns work, CLI owns scriptability, `goh top` owns
terminal monitoring, and the menu bar companion owns persistent Mac presence.

## Implementation Notes For A Future Slice

The likely implementation is a new native target, tentatively `GohBar`, using
SwiftUI for the popover and AppKit where a status item or system integration
requires it. It should reuse `GohCore` transport, command, and progress types.
If the existing progress subscription surface is enough, do not add new IPC.

The first implementation should be privately dogfooded before it becomes part
of any public install story. Packaging and launch-at-login behavior depend on
the distribution channel and should be decided in the same slice that packages
the companion.
