# Agent Status Light for macOS

A native macOS menu-bar equivalent of the ESP32 traffic light from the
[AI Status Light reference project](https://github.com/Z060049/AI-status-light-Claude-Code-Cursor-Codex):

- yellow, breathing dot: agent is working
- green dot: task completed
- red dot: tool call failed
- gray dot: off / idle

When the light changes to red, it plays an original two-note descending alert.
Use **Play failure sound** in the menu-bar app to toggle it. The sound is
synthesized locally by the app and is not an ICQ audio recording.

To preview the red sound manually while the app is running:

```zsh
Scripts/agent-status-light error preview
```

Clear the preview afterward with `Scripts/agent-status-light off preview`.

When Codex requests user input—for example, an approval—the light turns orange
and plays the macOS **Ping** system sound. Use **Play input-request sound** to
toggle that alert independently. The orange state is driven by Codex's
`PermissionRequest` hook and has been tested only with Codex.

> **Compatibility:** This project has been tested only with Codex. Claude Code,
> Cursor, and GitHub Copilot CLI hook configuration is included, but those
> integrations have not yet been tested.

## First-time installation from GitHub

**Requirements:** macOS 13 or later, Python 3, and Xcode Command Line Tools
(`xcode-select --install`) for Swift. Keep the downloaded project in a stable
location after installing: the agent hooks refer to its scripts by absolute path.

1. Download the project using **Code → Download ZIP** on GitHub, extract it, and
   open Terminal in the `AgentStatusLight` directory (the directory containing
   `Package.swift`). Or clone the repository:

   ```zsh
   git clone <repository-url>
   cd <repository-folder>/AgentStatusLight
   ```

2. Build and start the menu-bar app:

   ```zsh
   chmod +x Scripts/*
   Scripts/build-app.sh
   open "dist/Agent Status Light.app"
   ```

3. Choose the folder tree where automatic agent activity should control the
   light, then install the global hooks. For example:

   ```zsh
   python3 Scripts/install-hooks.py --scope "$HOME/Development"
   # or: python3 Scripts/install-hooks.py --scope "$HOME/Dev"
   # or: python3 Scripts/install-hooks.py --scope "$HOME/Documents"
   ```

   The selected folder must already exist. The installer backs up existing hook
   configuration, enables only the narrow status-file write permission for
   Codex, and leaves unrelated hooks unchanged.

4. Restart Codex, Claude Code, Cursor, and Copilot CLI. In Codex, ensure hooks are enabled
   with `codex features enable hooks`; if it asks you to trust the newly added
   hooks, trust them once. There are no per-project status-light prompts after
   that.

   For Codex, the light turns yellow on `UserPromptSubmit` (as soon as you send
   a prompt) and green on `Stop` (when Codex finishes the turn). It is not driven
   by an instruction that runs before the response is displayed.

The app now watches the selected folder tree. A session started in that folder
or a subfolder changes the light automatically; sessions elsewhere do not. The
menu-bar app can remain open while you work in any project.

GitHub Copilot support applies to **Copilot CLI**, which provides user-level
hooks under `~/.copilot/hooks/`. The VS Code Copilot extension does not currently
expose the same lifecycle-hook API, so it cannot be integrated automatically by
this installer.

## Build and run manually

```zsh
cd AgentStatusLight
chmod +x Scripts/*
Scripts/build-app.sh
open "dist/Agent Status Light.app"
```

The app has no Dock icon and keeps running in the menu bar. Use its menu to set a state manually or quit it.

## Drive it from an agent or hook

Install the companion command somewhere on your `PATH` (for example, `~/bin`):

```zsh
ln -sf "$PWD/Scripts/agent-status-light" ~/bin/agent-status-light
agent-status-light working codex
agent-status-light done codex
agent-status-light error codex
agent-status-light off
```

The command atomically writes `~/Library/Application Support/AgentStatusLight/status.json`; the menu-bar app notices changes within a second. The optional second argument is recorded as the event source, so the same command is suitable for Claude Code, Cursor, Codex, or a custom workflow. Once installed on your `PATH`, you can invoke it from any folder.

For a hook integration, invoke `agent-status-light working <agent>` before tool work, `done` after success, and `error` when a tool invocation fails.

For command-based integrations, the `run` form wraps a complete agent action
and maps its exit status automatically:

```zsh
agent-status-light run claude -- claude-code your-task
agent-status-light run cursor -- cursor-agent your-task
agent-status-light run codex -- codex exec "your task"
```

Agent-specific hooks can call the same state commands: use `working` on the
agent's pre-action event, `done` on success, and `error` on failure. The app
polls the shared status file and animates yellow while the state is working.

## Configuration details

The installer configures user-level hooks for Claude Code, Cursor, Codex, and
Copilot CLI.
They apply to every session, but the status light changes only when that session's
current directory is in the selected folder or one of its subfolders. Work outside
that tree does not affect the light. This makes the project portable: each person
selects the folder where they keep their agent-assisted work.

For a `~/Development` tree, run the installer once:

```zsh
python3 Scripts/install-hooks.py
```

Existing hook configuration is backed up and preserved. The installer also adds
only `~/Library/Application Support/AgentStatusLight` as an extra writable root
to Codex's user-level sandbox configuration. This lets the status hook update its
single shared file without prompting for permission in each project; it does not
grant broader filesystem access.

Restart Claude Code, Cursor, and Codex after installation so they reload their hooks.
For Codex, ensure the `hooks` feature is enabled with `codex features enable hooks`.

For a different folder, pass `--scope` (the folder must already exist):

```zsh
python3 Scripts/install-hooks.py --scope "$HOME/Dev"
python3 Scripts/install-hooks.py --scope "$HOME/Documents"
```

`AGENT_STATUS_LIGHT_SCOPE_ROOT` is also supported for scripted installations.

The latest installation replaces only this project's previous hooks, so rerunning
the command is how to change the active folder later. The status-light command
itself remains usable from any folder; this scope applies only to automatic agent
lifecycle updates.

## Codex interactive fallback

This repository's `AGENTS.md` provides a fallback for interactive Codex UI
sessions. For Codex CLI sessions, the installer registers lifecycle hooks in
`~/.codex/hooks.json` when the `hooks` feature is enabled. Prefer the global
hooks above, so individual projects do not need status-light instructions.
