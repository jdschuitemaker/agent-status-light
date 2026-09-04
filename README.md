# Agent Status Light for macOS

A native macOS menu-bar equivalent of the ESP32 traffic light from the
[AI Status Light reference project](https://github.com/Z060049/AI-status-light-Claude-Code-Cursor-Codex):

- bright yellow, breathing dot: agent is working
- orange dot: agent is waiting for your approval or answer
- green dot: task completed
- red dot: tool call failed
- gray dot: off / idle

Each indicator is a colored dot with the agent's initial centered inside it
unless you configure a custom logo: `O` for Codex, `G` for GitHub Copilot,
`>` for Cursor, and `A` for Claude Code. The initial is white on colored dots
and black on the gray/off dot so it stays readable.

When the light changes to red, it plays an original two-note descending alert.
Use **Play failure sound** in the menu-bar app to toggle it. The sound is
synthesized locally by the app and is not an ICQ audio recording.

To preview the red sound manually while the app is running:

```zsh
Scripts/agent-status-light error preview
```

Clear the preview afterward with `Scripts/agent-status-light off preview`.

When an agent asks for your input—an approval, or a choice between options—the
light turns orange and plays the macOS **Ping** system sound. Use
**Play input-request sound** to toggle that alert independently. The orange
state is driven by Codex's `PermissionRequest` hook, and for GitHub Copilot's
VS Code agent by its `PreToolUse` events (ask-questions tools and terminal
commands that need your approval). Copilot CLI reports the same waits through
its `notification` hook.

> **Compatibility:** Tested with Codex and GitHub Copilot (both the VS Code
> agent and Copilot CLI). Claude Code and Cursor hook configuration is included,
> but those integrations have not yet been verified.

## Downloading a prebuilt app

GitHub releases include `Agent-Status-Light-macOS.zip`, a ready-to-run build of
the menu-bar app. The app is ad-hoc signed for local development but is **not
notarized by Apple**, so the first launch on a Mac that downloads it may show a
Gatekeeper warning ("cannot be opened because the developer cannot be
verified"). That is expected. To open it, Control-click the app and choose
**Open** from the shortcut menu, or open System Settings → Privacy & Security
and click **Open Anyway**. Apple explains the steps here:
[Open a Mac app from an unidentified developer](https://support.apple.com/guide/mac/open-a-mac-app-from-an-unidentified-developer-mh40616/mac).

Building from source with `Scripts/build-app.sh` avoids the warning because the
app is created on your own Mac.

## First-time installation from GitHub

**Requirements:** macOS 13 or later, Python 3, and Xcode Command Line Tools
(`xcode-select --install`) for Swift. Keep the downloaded project in a stable
location after installing: the agent hooks refer to its scripts by absolute path.

1. Download the project using **Code → Download ZIP** on GitHub, extract it, and
   open Terminal in the `AgentStatusLight` directory (the directory containing
   `Package.swift`). Or clone the repository:

   ```zsh
   git clone https://github.com/jdschuitemaker/agent-status-light.git
   cd agent-status-light/AgentStatusLight
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

The menu bar starts with one Codex indicator. To watch another agent, open an
indicator's menu and choose **Add** ▸ the agent's name (GitHub Copilot, Cursor,
or Claude Code). Each indicator reads its own status file; the **Add** submenu
lists only agents that are not already shown, and the set of shown indicators is
remembered between launches.

Every indicator has the same menu:

- a read-only header showing the agent name and current state — the app never
  lets you set a status manually; states come from agent lifecycle hooks
- **Add** ▸ agent name — show another agent's indicator
- **Choose logo…** — use a PNG, ICNS, JPEG, or TIFF image instead of the initial
- **Use initial instead** — return to the fallback initial
- **Reveal status file** — open the agent's status file in Finder
- **Play failure sound** and **Play input-request sound** — toggle the red and
  orange alerts independently
- **Start at Login** — launch automatically after reboot
- **Close [agent] indicator** — remove just this indicator (disabled when it is
  the only one; no icon can close another)
- **Quit Agent Status Light** — quit the app

The first time you enable **Start at Login**, the app copies itself to
`/Applications`, relaunches from there, and registers as a login item; newer
macOS versions may ask you to approve it under System Settings → General →
Login Items. Unchecking it stops auto-launching. Closing an indicator or
quitting the app later does not change the login-item setting.

GitHub Copilot integration uses user-level hooks under `~/.copilot/hooks/`,
shared by Copilot CLI and VS Code. The VS Code Copilot extension does not expose
a dedicated waiting-for-input event for its own chat agents, so the status
light infers the wait from `PreToolUse` tool names: ask-questions tools
(`vscode_askQuestions`) always turn the light orange, and terminal tools
(`run_in_terminal`) turn it orange unless the exact command is on VS Code's
`chat.tools.terminal.autoApprove` list. Copilot CLI's `notification` hook covers
the same waits when the CLI engine itself prompts (including Copilot CLI
sessions in VS Code); benign notifications leave the current state untouched.
The matching `PostToolUse` or `Stop` event moves the light back to working or
completed. Every hook invocation is recorded (sensitive fields stripped) in
`~/Library/Application Support/AgentStatusLight/hook-events.log` to make
lifecycle issues easy to diagnose.

## Build and run manually

```zsh
cd AgentStatusLight
chmod +x Scripts/*
Scripts/build-app.sh
open "dist/Agent Status Light.app"
```

The app has no Dock icon and keeps running in the menu bar. Use an indicator's
menu to add or remove indicators, choose logos and sounds, enable Start at
Login, or quit the app.

## Drive it from an agent or hook

Install the companion command somewhere on your `PATH` (for example, `~/bin`):

```zsh
ln -sf "$PWD/Scripts/agent-status-light" ~/bin/agent-status-light
agent-status-light working codex
agent-status-light done codex
agent-status-light error codex
agent-status-light off
```

The command atomically writes
`~/Library/Application Support/AgentStatusLight/status.<agent>.json`; each
indicator polls its own file and notices changes within a second. The second
argument selects the agent (the default is `cli`), so the same command is
suitable for Claude Code, Cursor, Codex, GitHub Copilot, or a custom workflow.
Once installed on your `PATH`, you can invoke it from any folder.

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
polls the per-agent status files and animates yellow while the state is
working.

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
per-agent status files without prompting for permission in each project; it does
not grant broader filesystem access.

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
