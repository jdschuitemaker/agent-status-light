#!/usr/bin/env python3
"""Install idempotent, Development-scoped agent status hooks."""
import json
import os
import shutil
import argparse
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CLI = ROOT / "agent-status-light"
CLAUDE = ROOT / "claude-hook.py"
MARKER = "agent-status-light"

parser = argparse.ArgumentParser(
    description="Install Agent Status Light hooks for one directory tree."
)
parser.add_argument(
    "--scope",
    default=os.environ.get("AGENT_STATUS_LIGHT_SCOPE_ROOT", str(Path.home() / "Development")),
    help="directory tree whose agent sessions should update the light (default: ~/Development)",
)
args = parser.parse_args()
SCOPE_ROOT = Path(args.scope).expanduser().resolve()
if not SCOPE_ROOT.is_dir():
    raise SystemExit(f"Scope directory does not exist: {SCOPE_ROOT}")

def command(*parts: str) -> str:
    import shlex
    return " ".join(shlex.quote(str(p)) for p in parts) + f"  # {MARKER}"

def load(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except json.JSONDecodeError:
        raise SystemExit(f"Refusing to overwrite invalid JSON: {path}")

def backup(path: Path) -> None:
    if path.exists():
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        shutil.copy2(path, path.with_name(path.name + f".bak.{stamp}"))

def add_hook(items: list, entry: dict) -> list:
    if not any(MARKER in json.dumps(item) for item in items):
        items.append(entry)
    return items

def set_hook(items: list, entry: dict) -> list:
    """Replace only this integration's old hook, retaining other hooks."""
    return [item for item in items if MARKER not in json.dumps(item)] + [entry]

def write(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    backup(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n")
    os.replace(tmp, path)

def configure_codex_sandbox(path: Path) -> None:
    """Permit only the status-file directory in Codex's user-level sandbox."""
    text = path.read_text() if path.exists() else ""
    if "[sandbox_workspace_write]" in text or "sandbox_mode" in text:
        return
    backup(path)
    status_dir = Path.home() / "Library/Application Support/AgentStatusLight"
    addition = (
        "\n# Agent Status Light: allow its shared local status file from any Codex workspace.\n"
        'sandbox_mode = "workspace-write"\n\n'
        "[sandbox_workspace_write]\n"
        f"writable_roots = [{json.dumps(str(status_dir))}]\n"
    )
    path.write_text(text.rstrip() + "\n" + addition)

def codex_hook(action: str) -> dict:
    """Return the three-level hook shape required by current Codex releases."""
    return {
        "matcher": "",
        "hooks": [{
            "type": "command",
            "command": command("/usr/bin/env", "python3", CLAUDE, action, "codex", SCOPE_ROOT),
        }],
    }

def copilot_hook(event: str) -> dict:
    """Return a GitHub Copilot CLI v1 user-hook entry."""
    command_text = command("/usr/bin/env", "python3", CLAUDE, event, "copilot", SCOPE_ROOT)
    return {
        "type": "command",
        "bash": command_text,
        "timeoutSec": 30,
    }

home = Path.home()
claude = load(home / ".claude/settings.json")
hooks = claude.setdefault("hooks", {})
hooks["PreToolUse"] = set_hook(hooks.get("PreToolUse", []), {
    "matcher": "", "hooks": [{"type": "command", "command": command("/usr/bin/env", "python3", CLAUDE, "pre", "claude", SCOPE_ROOT)}]
})
hooks["Stop"] = set_hook(hooks.get("Stop", []), {
    "matcher": "", "hooks": [{"type": "command", "command": command("/usr/bin/env", "python3", CLAUDE, "stop", "claude", SCOPE_ROOT)}]
})
hooks["PostToolUse"] = set_hook(hooks.get("PostToolUse", []), {
    "matcher": "", "hooks": [{"type": "command", "command": command("/usr/bin/env", "python3", CLAUDE, "post", "claude", SCOPE_ROOT)}]
})
write(home / ".claude/settings.json", claude)

cursor = load(home / ".cursor/hooks.json")
hooks = cursor.setdefault("hooks", {})
hooks["beforeSubmitPrompt"] = set_hook(hooks.get("beforeSubmitPrompt", []), {
    "command": command("/usr/bin/env", "python3", CLAUDE, "pre", "cursor", SCOPE_ROOT)
})
hooks["stop"] = set_hook(hooks.get("stop", []), {
    "command": command("/usr/bin/env", "python3", CLAUDE, "stop", "cursor", SCOPE_ROOT)
})
write(home / ".cursor/hooks.json", cursor)

codex = load(home / ".codex/hooks.json")
hooks = codex.setdefault("hooks", {})
for event, action in {
    "SessionStart": "pre",
    "UserPromptSubmit": "pre",
    "PreToolUse": "pre",
    "PermissionRequest": "permission-request",
    "PostToolUse": "post",
    "Stop": "stop",
    "SessionEnd": "session-end",
}.items():
    hooks[event] = set_hook(hooks.get(event, []), codex_hook(action))
write(home / ".codex/hooks.json", codex)
configure_codex_sandbox(home / ".codex/config.toml")

copilot_path = home / ".copilot/hooks/agent-status-light.json"
copilot = load(copilot_path)
copilot["version"] = 1
copilot_hooks = copilot.setdefault("hooks", {})
for event, action in {
    "sessionStart": "sessionStart",
    "sessionEnd": "sessionEnd",
    "userPromptSubmitted": "userPromptSubmitted",
    "preToolUse": "preToolUse",
    "postToolUse": "postToolUse",
    "permissionRequest": "permissionRequest",
    "agentStop": "agentStop",
    "errorOccurred": "errorOccurred",
}.items():
    copilot_hooks[event] = set_hook(copilot_hooks.get(event, []), copilot_hook(action))
write(copilot_path, copilot)
print(f"Installed Agent Status Light hooks for Claude Code, Cursor, Codex, and Copilot CLI under {SCOPE_ROOT}.")
