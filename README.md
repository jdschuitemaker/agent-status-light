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

### Several sessions of the same agent

If you have two Codex windows open, you still see one Codex dot — but its menu
now has a **Sessions** section listing each window by folder name with its own
status. The dot itself shows the most important state of all sessions: orange
if any session needs you, then red, then yellow, then green.

Click a session to bring its window to the front, so you can answer the prompt
that turned the dot orange. Terminal and iTerm2 jump to the exact tab; other
terminal apps are brought to the front.

The first time you click a session, macOS asks whether Agent Status Light may
control your terminal app. Allow it once — if you decline, clicking still brings
the app forward, but it cannot select the right tab. You can change this later in
System Settings → Privacy & Security → Automation.

Session entries disappear again when their session ends.

## What every dot's menu does

Each dot has the same menu:

- **Add ▸ agent name** — show another agent's dot.
- **Sessions** — list the running sessions of this agent (shown when there is
  more than one); click one to activate its window (macOS asks for permission
  the first time).
- **Choose logo…** — use your own image (PNG, ICNS, JPEG, or TIFF) for the dot.
- **Use initial instead** — go back to the simple letter.
- **Reveal status file** — open the agent's status file in Finder.
- **Play failure sound** / **Play input-request sound** — turn sounds on or off.
- **Input sound volume** — set the input-request cue to 25%, 50%, 75%, or
  100% (50% by default).
- **Alert for Copilot tool approvals** — on by default; turn it off when you let
  Copilot run terminal commands and read files without asking.
- **Start at Login** — start the app automatically after you restart your Mac.
- **Close [agent] indicator** — hide this agent's dot (only its own menu can
  close it).
- **Quit Agent Status Light** — quit the app.

The first line of the menu only *shows* the agent's current status. You cannot
set a status yourself — the dots update automatically from the agents.

## Sounds

- When an agent needs your input, the dot turns orange and plays a short
  two-note "uh-oh" cue rebuilt from measurements of the classic ICQ
  incoming-message alert: about 0.45 s long, a short high "uh", a tiny gap,
  then a lower, longer "oh". It is an electronic recreation, not a spoken
  voice.
- When a task fails, the dot turns red and plays a short two-note sound made by
  the app itself.

You can turn each sound on or off from any dot's menu, and set the input cue's
volume there too.

The input cue waits about a second and a half before it plays, and its dot
stays yellow during that moment. That short confirmation is what keeps tools
the agent resolves by itself (auto-approved commands, quick approvals) silent.

## Start at Login

Choose **Start at Login** from any dot's menu and the app will start by itself
after every reboot. The first time you enable it, the app copies itself to your
Applications folder and restarts from there. Newer macOS versions may ask you to
approve it in System Settings → General → Login Items.

## Why a dot can hide on a MacBook with a notch

The menu bar on a notched MacBook has a camera cutout in the middle. When the
menu bar is crowded, macOS pushes extra icons into that cutout area, where they
are not visible. This is macOS behaviour — the dot still exists, it is just
hidden behind the notch.

The easiest fix is to hide a few other apps' menu-bar icons (System Settings →
Menu Bar → "Allow in the Menu Bar"). You can also make *all* menu-bar icons
tighter, which gives everything more room:

```zsh
defaults -currentHost write -globalDomain NSStatusItemSpacing -int 2
defaults -currentHost write -globalDomain NSStatusItemSelectionPadding -int 2
killall ControlCenter
```

That spacing change affects every app's menu-bar icons, not just Agent Status
Light. To restore Apple's wider spacing later:

```zsh
defaults -currentHost delete -globalDomain NSStatusItemSpacing
defaults -currentHost delete -globalDomain NSStatusItemSelectionPadding
killall ControlCenter
```

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

If macOS still refuses to open it, you can clear the download flag once:

```zsh
xattr -d com.apple.quarantine "/Applications/Agent Status Light.app"
```

The app itself only draws the dots; the hooks that feed it live in the source
code. Click the green **Code** button on the
[repository page](https://github.com/jdschuitemaker/agent-status-light) →
**Download ZIP**, unzip it, and use its `Scripts` folder for the “Connecting AI
agents” step below.

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

Install the hooks once and you are done. By default they cover **every folder**
on your Mac, so the dots work wherever you start an agent — Development,
Downloads, Desktop, an external drive, anywhere:

```zsh
python3 Scripts/install-hooks.py
```

Then restart your agents once so they load the new hooks. An agent that is
already running keeps the old hooks until it is restarted.

If you would rather only watch certain folders (so the dots stay quiet while you
work elsewhere), list them separated by `:`:

```zsh
python3 Scripts/install-hooks.py --scope "$HOME/Development:$HOME/Downloads"
```

Rerun the installer with the same `--scope` whenever you want to change it.

### Which agents work

Tested and working:

- **Codex** — yellow as soon as you send a prompt, orange when it asks you
  something, green when it finishes.
- **GitHub Copilot** — works in the VS Code agent and in Copilot CLI. VS Code
  has no direct "waiting for you" event for its own chat agent, so the app turns
  orange when Copilot asks you a question with its ask-questions tool, and it
  turns orange a few seconds later if a terminal command or an out-of-folder
  file read is still waiting for your approval. Quick auto-run commands finish
  before that and never alert. If you enable Copilot's "run without asking"
  mode for a chat, turn off **Alert for Copilot tool approvals** so long
  auto-run commands do not cause false alerts. Copilot CLI sessions alert
  through their own notification hook.

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
- Every session writes its own small file under
  `~/Library/Application Support/AgentStatusLight/sessions/`. The file is
  removed when the session ends, and ignored after 24 hours if an agent exits
  without saying goodbye.
- Every hook event is logged (private content removed) in
  `~/Library/Application Support/AgentStatusLight/hook-events.log`, which helps
  if something does not update.
- By default the hooks report every agent session anywhere on your Mac. Install
  with `--scope` if you want to limit which folders may change the dots.
- Inspired by the
  [AI Status Light reference project](https://github.com/Z060049/AI-status-light-Claude-Code-Cursor-Codex).
