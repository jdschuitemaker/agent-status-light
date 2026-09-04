# Agent Status Light for macOS

A tiny app that lives in your Mac's menu bar (the top of your screen) and shows
you what your AI coding helpers are doing — like a traffic light for your AI
agents.

You get one dot per AI agent. Each dot changes color while the agent works, asks
you something, finishes, or runs into a problem. No need to keep checking the
terminal window.

## Reading the dots

This is what each color means:

- 🟡 **Yellow (breathing)** — the agent is busy working.
- 🟠 **Orange** — the agent is waiting for you (an approval or a choice).
- 🟢 **Green** — it finished the task successfully.
- 🔴 **Red** — something went wrong.
- ⚪ **Grey** — off / not doing anything.

Each dot shows the agent's initial (`O` for Codex, `G` for GitHub Copilot,
`>` for Cursor, `A` for Claude Code) so you know which agent it belongs to. If
you prefer, you can replace the initial with your own logo image.

## One app, many agents

Agent Status Light can show a separate dot for every AI agent you use. On the
first launch you only see Codex. If you also use GitHub Copilot, Cursor, or
Claude Code, you can add their dots:

1. Click a dot in the menu bar to open its menu.
2. Choose **Add** and pick the agent you want to show.

Every dot is independent: it shows only its own agent's status, and it can only
close itself. The app remembers which dots you added, so they come back the next
time you start it.

## What every dot's menu does

Each dot has the same menu:

- **Add ▸ agent name** — show another agent's dot.
- **Choose logo…** — use your own image (PNG, ICNS, JPEG, or TIFF) for the dot.
- **Use initial instead** — go back to the simple letter.
- **Reveal status file** — open the agent's status file in Finder.
- **Play failure sound** / **Play input-request sound** — turn sounds on or off.
- **Start at Login** — start the app automatically after you restart your Mac.
- **Close [agent] indicator** — hide this agent's dot (only its own menu can
  close it).
- **Quit Agent Status Light** — quit the app.

The first line of the menu only *shows* the agent's current status. You cannot
set a status yourself — the dots update automatically from the agents.

## Sounds

- When an agent needs your input, the dot turns orange and plays the macOS
  "Ping" sound.
- When a task fails, the dot turns red and plays a short two-note sound made by
  the app itself.

You can turn each sound on or off from any dot's menu.

## Start at Login

Choose **Start at Login** from any dot's menu and the app will start by itself
after every reboot. The first time you enable it, the app copies itself to your
Applications folder and restarts from there. Newer macOS versions may ask you to
approve it in System Settings → General → Login Items.

## Getting the app

### Option 1: Download the prebuilt app

Download `Agent-Status-Light-macOS.zip` from the
[releases page](https://github.com/jdschuitemaker/agent-status-light/releases),
unzip it, and move `Agent Status Light.app` to your Applications folder.

> The app is signed so it runs on your own Mac, but it is **not notarized by
> Apple** for public downloads. On first launch macOS may say the developer
> cannot be verified. That is expected: Control-click the app and choose
> **Open**, or go to System Settings → Privacy & Security and click
> **Open Anyway**. Apple explains it here:
> [Open a Mac app from an unidentified developer](https://support.apple.com/guide/mac/open-a-mac-app-from-an-unidentified-developer-mh40616/mac).

### Option 2: Build it yourself

Building from source avoids the warning because the app is created on your own
Mac. You need macOS 13 or newer and Xcode Command Line Tools.

```zsh
git clone https://github.com/jdschuitemaker/agent-status-light.git
cd agent-status-light/AgentStatusLight
chmod +x Scripts/*
Scripts/build-app.sh
open "dist/Agent Status Light.app"
```

## Connecting AI agents

The app watches agent activity inside a folder you choose. Sessions started in
that folder (or any subfolder) update the dot automatically; sessions outside
it do not.

Install the hooks once with:

```zsh
python3 Scripts/install-hooks.py --scope "$HOME/Development"
```

Use another folder if you prefer, for example `--scope "$HOME/Dev"` or
`--scope "$HOME/Documents"`.

Then restart your agents once so they load the new hooks. If you use a folder
other than `~/Development`, pass the same `--scope` every time you rerun the
installer.

### Which agents work

Tested and working:

- **Codex** — yellow as soon as you send a prompt, orange when it asks you
  something, green when it finishes.
- **GitHub Copilot** — works in the VS Code agent and in Copilot CLI. VS Code
  has no direct "waiting for you" event, so the app notices by the tool Copilot
  is about to use (ask-questions tools and terminal commands that need your
  approval).

Included but not yet verified:

- **Cursor** and **Claude Code** — the hooks are installed for them, and they
  should work, but we haven't been able to test them yet.

## Using it without an agent hook

You can also update a dot from any script or terminal command:

```zsh
# one time: make the helper command available
ln -sf "$PWD/Scripts/agent-status-light" ~/bin/agent-status-light
```

```zsh
agent-status-light working copilot
agent-status-light done copilot
agent-status-light error copilot
```

Replace `copilot` with `codex`, `cursor`, `claude`, or your own name. The app
stores one small status file per agent in
`~/Library/Application Support/AgentStatusLight/`.

For a complete action with automatic success/failure handling:

```zsh
agent-status-light run codex -- codex exec "your task"
```

## Handy details for curious people

- A "completed" dot turns grey again after 20 seconds of no new activity.
- Every hook event is logged (private content removed) in
  `~/Library/Application Support/AgentStatusLight/hook-events.log`, which helps
  if something does not update.
- The hooks change the status only for sessions inside your chosen folder tree,
  so work elsewhere never disturbs the dots.
- Inspired by the
  [AI Status Light reference project](https://github.com/Z060049/AI-status-light-Claude-Code-Cursor-Codex).
