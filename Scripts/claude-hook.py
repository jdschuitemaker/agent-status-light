#!/usr/bin/env python3
"""Translate Claude Code lifecycle hooks into Agent Status Light states."""
import datetime as _dt
import json
import os
import subprocess
import sys
import time
from pathlib import Path

CLI = Path(__file__).with_name("agent-status-light")
SOURCE = sys.argv[2] if len(sys.argv) > 2 else "claude"
SCOPE_ROOT = Path(sys.argv[3]).expanduser() if len(sys.argv) > 3 else Path.home() / "Development"
LOG_PATH = Path.home() / "Library/Application Support/AgentStatusLight/hook-events.log"
STATUS_DIR = Path.home() / "Library/Application Support/AgentStatusLight"
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


def vscode_pre_tool_waits_for_user(payload: dict) -> bool:
    """VS Code's own agent does not emit a waiting-for-input hook. Infer it
    only from tools that genuinely ask the user something. Terminal tools are
    excluded: auto-run command cards look identical to permission prompts, so
    guessing there causes false input alerts."""
    tool = str(payload.get("tool_name") or "").lower()
    if tool in ("vscode_askquestions", "vscode_askuser", "askuser",
                "ask_user", "question", "askquestions") or tool.startswith("vscode_ask"):
        return True
    return False


def is_terminal_tool(payload: dict) -> bool:
    tool = str(payload.get("tool_name") or "").lower()
    return tool in ("run_in_terminal", "bash", "terminal", "exec_command")


def is_external_file_read(payload: dict) -> bool:
    """VS Code asks before a read tool touches a file outside the session
    folder. Detect that case so the delayed approval check can run."""
    tool = str(payload.get("tool_name") or "").lower()
    if tool not in ("read_file", "readfile", "read_text_file", "readtextfile",
                    "read_file_range", "readfilerange"):
        return False
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return False
    target = ""
    for key in ("file_path", "filePath", "path", "absolutePath", "absolute_path"):
        value = tool_input.get(key)
        if isinstance(value, str) and value.strip():
            target = value.strip()
            break
    if not target:
        return False
    try:
        requested = Path(target).expanduser()
        if not requested.is_absolute():
            requested = Path(payload.get("cwd") or ".").resolve() / requested
        workspace = Path(payload.get("cwd") or "").resolve()
        return not requested.resolve().is_relative_to(workspace)
    except (OSError, ValueError):
        return False


def status_timestamp() -> str:
    try:
        record = json.loads((STATUS_DIR / f"status.{SOURCE}.json").read_text())
        return str(record.get("updatedAt") or "")
    except (OSError, json.JSONDecodeError):
        return ""


def schedule_terminal_watch() -> None:
    """A permission-gated terminal command may sit waiting for the user while
    VS Code emits no event. Ensure a fresh working baseline, then check a few
    seconds later: if nothing updated the status file, the tool is still
    waiting and we turn the light orange."""
    set_state("working")
    target = status_timestamp()
    if not target:
        return
    helper = [sys.executable, str(Path(__file__).resolve()),
              "watch-awaiting", SOURCE, str(SCOPE_ROOT), target]
    subprocess.Popen(helper, stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


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


def copilot_tool_alerts_enabled() -> bool:
    """Menu preference: 'Alert for Copilot tool approvals'. On by default."""
    try:
        result = subprocess.run(
            ["defaults", "read", "local.agentstatuslight", "copilotToolAlerts"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, check=False)
        if result.returncode != 0:
            return True
        return result.stdout.strip().lower() not in ("0", "false", "no")
    except OSError:
        return True


event = sys.argv[1] if len(sys.argv) > 1 else ""
if not is_in_scope():
    raise SystemExit(0)

payload = {}
try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, EOFError):
    pass

if event == "watch-awaiting":
    # Background helper spawned by schedule_terminal_watch.
    target = sys.argv[4] if len(sys.argv) > 4 else ""
    time.sleep(3)
    if target and status_timestamp() == target:
        set_state("awaiting-input")
    raise SystemExit(0)

log_event(event, payload)

# Normalize names from all supported surfaces: Codex, Cursor, Claude Code,
# GitHub Copilot CLI (camelCase), and VS Code Copilot (PascalCase).
key = event.lower().replace("_", "").replace("-", "")

if key == "pretooluse" and SOURCE == "copilot":
    # VS Code native chat: no permission/notification hook exists, so infer
    # the wait from the tool. Ask-questions tools always wait. Terminal tools
    # may wait for approval, so schedule a delayed check instead of assuming;
    # the matching PostToolUse (or agentStop) cancels it by updating the file.
    if vscode_pre_tool_waits_for_user(payload):
        set_state("awaiting-input")
    elif copilot_tool_alerts_enabled() and (is_terminal_tool(payload) or is_external_file_read(payload)):
        schedule_terminal_watch()
    else:
        set_state("working")
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
