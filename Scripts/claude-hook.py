#!/usr/bin/env python3
"""Translate Claude Code lifecycle hooks into Agent Status Light states."""
import datetime as _dt
import json
import os
import subprocess
import sys
from pathlib import Path

CLI = Path(__file__).with_name("agent-status-light")
SOURCE = sys.argv[2] if len(sys.argv) > 2 else "claude"
SCOPE_ROOT = Path(sys.argv[3]).expanduser() if len(sys.argv) > 3 else Path.home() / "Development"
LOG_PATH = Path.home() / "Library/Application Support/AgentStatusLight/hook-events.log"
VSCODE_SETTINGS_PATHS = [
    Path.home() / "Library/Application Support/Code - Insiders/User/settings.json",
    Path.home() / "Library/Application Support/Code/User/settings.json",
]
SENSITIVE_KEYS = {
    "args", "content", "env", "message", "modified_prompt", "modifiedprompt",
    "modified_transformed_prompt", "modifiedtransformedprompt", "prompt",
    "response", "response_content", "responsecontent", "responses",
    "tool_input", "toolinput", "tool_response", "toolresponse",
    "transcript_path", "transcriptpath",
}


def scrub(value, depth=0):
    """Keep payload structure but remove sensitive fields for the log."""
    if isinstance(value, dict):
        return {key: scrub(item, depth + 1) for key, item in value.items()
                if key.lower() not in SENSITIVE_KEYS}
    if isinstance(value, list):
        return [scrub(item, depth + 1) for item in value]
    if isinstance(value, str):
        return value if len(value) <= 200 else value[:200] + "..."
    return value


def load_auto_approved_commands() -> set:
    """Return exact terminal commands VS Code may run without asking."""
    approved = set()
    for path in VSCODE_SETTINGS_PATHS:
        try:
            settings = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        # VS Code stores settings with dotted keys at the top level.
        auto = (settings or {}).get("chat.tools.terminal.autoApprove")
        if not isinstance(auto, dict):
            auto = (((settings or {}).get("chat") or {}).get("tools") or {})
            auto = (auto.get("terminal") or {}).get("autoApprove") or {}
        for rule, enabled in auto.items():
            if enabled:
                approved.add(str(rule).strip())
    return approved


def command_is_auto_approved(payload: dict) -> bool:
    """Heuristic for VS Code's PreToolUse: does this terminal command run
    without an approval prompt? VS Code auto-approves only exact commands
    listed in chat.tools.terminal.autoApprove."""
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return False
    command = str(tool_input.get("command")
                  or tool_input.get("cmd") or "").strip()
    if not command:
        return False
    approved = load_auto_approved_commands()
    return any(command == rule or command.startswith(rule + " ")
               for rule in approved if rule)


def vscode_pre_tool_waits_for_user(payload: dict) -> bool:
    """VS Code's own agent does not emit a waiting-for-input hook. Infer it
    from the tool being invoked: askQuestions-style tools always wait for an
    answer, and terminal tools wait for approval unless auto-approved."""
    tool = str(payload.get("tool_name") or "").lower()
    if tool in ("vscode_askquestions", "vscode_askuser", "askuser",
                "ask_user", "question", "askquestions") or tool.startswith("vscode_ask"):
        return True
    if tool in ("run_in_terminal", "bash", "terminal", "exec_command"):
        return not command_is_auto_approved(payload)
    return False


def log_event(event: str, payload: dict) -> None:
    """Append a compact record of every hook invocation for diagnostics."""
    try:
        stamp = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        extra = ""
        notification_type = payload.get("notification_type") or payload.get("notificationType")
        if notification_type:
            extra = f" notification_type={notification_type}"
        summary = json.dumps(scrub(payload), ensure_ascii=True, sort_keys=True,
                             separators=(",", ":"))
        if len(summary) > 600:
            summary = summary[:600] + "..."
        line = f"{stamp} event={event}{extra} payload={summary}\n"
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a") as handle:
            handle.write(line)
        if LOG_PATH.stat().st_size > 2_000_000:
            LOG_PATH.rename(LOG_PATH.with_suffix(".log.old"))
    except Exception:
        # Diagnostics must never break a lifecycle hook.
        pass

def is_in_scope() -> bool:
    try:
        Path.cwd().resolve().relative_to(SCOPE_ROOT.resolve())
        return True
    except ValueError:
        return False

def set_state(state: str) -> None:
    subprocess.run([str(CLI), state, SOURCE], stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   check=False)

event = sys.argv[1] if len(sys.argv) > 1 else ""
if not is_in_scope():
    raise SystemExit(0)

payload = {}
try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, EOFError):
    pass
log_event(event, payload)

# Normalize names from all supported surfaces: Codex, Cursor, Claude Code,
# GitHub Copilot CLI (camelCase), and VS Code Copilot (PascalCase).
key = event.lower().replace("_", "").replace("-", "")

if (key == "pretooluse" and SOURCE == "copilot"
        and vscode_pre_tool_waits_for_user(payload)):
    # VS Code native chat: no permission/notification hook exists, so detect
    # the wait from the tool that is about to ask the user something. The
    # matching PostToolUse (or agentStop) moves the light back afterwards.
    set_state("awaiting-input")
elif key in ("pre", "sessionstart", "userpromptsubmit", "userpromptsubmitted",
             "pretooluse", "subagentstart"):
    set_state("working")
elif key in ("stop", "agentstop"):
    set_state("done")
elif key in ("permissionrequest", "permission-request"):
    set_state("awaiting-input")
elif key == "notification":
    notification_type = str(payload.get("notification_type")
                            or payload.get("notificationType") or "").lower()
    if notification_type in ("permission_prompt", "permission", "elicitation",
                             "elicitation_dialog"):
        # The agent is waiting for the user to approve a tool or answer a
        # question. The next hook (tool progress, prompt, or agent stop) will
        # move the light back to working/completed.
        set_state("awaiting-input")
    # Benign notifications (shell completion, background agent idle, etc.)
    # intentionally leave the current state untouched.
elif key in ("sessionend", "session-end"):
    set_state("off")
elif key == "erroroccurred":
    set_state("error")
elif key == "posttooluse" or event in ("post",):
    response = payload.get("tool_response") or {}
    if isinstance(response, dict):
        failed = (response.get("is_error") is True or
                  response.get("isError") is True or
                  response.get("success") is False or
                  bool(response.get("error")))
    else:
        # Codex may provide tool output as a string. Never let a malformed or
        # unexpected hook payload make the lifecycle hook itself fail.
        failed = (payload.get("is_error") is True or
                  payload.get("isError") is True or
                  payload.get("success") is False or
                  bool(payload.get("error")))
    if failed:
        set_state("error")
    else:
        # A successful tool call means the agent is still working. This also
        # covers a permission-gated call: after the user approves and the tool
        # completes, return from orange to the yellow breathing state.
        set_state("working")
