#!/usr/bin/env python3
"""Translate Claude Code lifecycle hooks into Agent Status Light states."""
import datetime as _dt
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

CLI = Path(__file__).with_name("agent-status-light")
SOURCE = sys.argv[2] if len(sys.argv) > 2 else "claude"
SCOPE_ARG = sys.argv[3] if len(sys.argv) > 3 else "/"
LOG_PATH = Path.home() / "Library/Application Support/AgentStatusLight/hook-events.log"
STATUS_DIR = Path.home() / "Library/Application Support/AgentStatusLight"
SESSIONS_DIR = STATUS_DIR / "sessions"
SESSION_ID = ""
SESSION_LABEL = ""
TERMINAL = ""
TTY = ""
TERMINAL_PID = "0"
SENSITIVE_KEYS = {
    "args", "content", "env", "message", "modified_prompt", "modifiedprompt",
    "modified_transformed_prompt", "modifiedtransformedprompt", "prompt",
    "response", "response_content", "responsecontent", "responses",
    "tool_input", "toolinput", "tool_response", "toolresponse",
    "transcript_path", "transcriptpath",
}


def scope_roots():
    """Scope argument may hold several roots separated by the OS path separator."""
    roots = [Path(part).expanduser() for part in SCOPE_ARG.split(os.pathsep) if part.strip()]
    return roots or [Path("/")]


def safe_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]", "_", value)


def session_path() -> Path:
    return SESSIONS_DIR / f"{safe_name(SOURCE)}__{safe_name(SESSION_ID)}.json"


def session_identity(payload: dict) -> tuple[str, str]:
    """Give every agent session its own key and a readable folder label."""
    sid = str(payload.get("session_id") or payload.get("sessionId")
              or payload.get("sessionID") or "").strip()
    cwd = str(payload.get("cwd") or payload.get("workspace") or "").strip()
    label = Path(cwd).name if cwd else ""
    if not sid:
        seed = cwd or label or SOURCE
        sid = "cwd-" + hashlib.sha1(seed.encode("utf-8")).hexdigest()[:12]
    if not label:
        label = SOURCE.capitalize()
    return sid, label


TERMINAL_NAMES = ("Terminal", "iTerm2", "Warp", "Alacritty", "kitty", "WezTerm",
                  "Ghostty", "Hyper", "Tabby", "Termius", "Code", "Cursor", "Windsurf")
AGENT_PROCESS_NAMES = ("codex", "claude", "cursor-agent", "cursor", "copilot", "gemini")


def process_table() -> dict:
    try:
        result = subprocess.run(["ps", "-axo", "pid=,ppid=,tty=,command="],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, check=False)
    except OSError:
        return {}
    table = {}
    for line in result.stdout.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        command = parts[3]
        exe = command.split()[0] if command.split() else ""
        table[pid] = (ppid, exe, parts[2].strip())
    return table


def process_cwd(pid: int) -> str:
    try:
        result = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, check=False)
    except OSError:
        return ""
    for line in result.stdout.splitlines():
        if line.startswith("n"):
            return line[1:]
    return ""


def ancestor_terminal(table: dict, pid: int) -> tuple[str, int]:
    seen = set()
    while pid and pid not in seen:
        seen.add(pid)
        entry = table.get(pid)
        if not entry:
            break
        ppid, comm, _ = entry
        base = os.path.basename(comm)
        if base in TERMINAL_NAMES:
            return base, pid
        pid = ppid
    return "", 0


def match_agent_pid(table: dict, cwd: str) -> int:
    """Find the running agent CLI process whose working folder is this session."""
    if not table or not cwd:
        return 0
    target = os.path.realpath(cwd)
    for pid, (_, comm, tty) in table.items():
        if not tty.startswith("tty"):
            continue
        if os.path.basename(comm) not in AGENT_PROCESS_NAMES:
            continue
        if os.path.realpath(process_cwd(pid) or "") == target:
            return pid
    return 0


def descendants_of(table: dict, root: int, max_depth: int = 2) -> set:
    """PIDs below the agent process (a running tool shows up here)."""
    if not root:
        return set()
    children: dict = {}
    for pid, (ppid, _, _) in table.items():
        children.setdefault(ppid, []).append(pid)
    found = set()
    frontier = [root]
    for _ in range(max_depth):
        following = []
        for node in frontier:
            for kid in children.get(node, []):
                if kid not in found:
                    found.add(kid)
                    following.append(kid)
        frontier = following
    return found


def chain_context(table: dict) -> tuple[str, str, str]:
    tty = ""
    pid = os.getpid()
    seen = set()
    while pid and pid not in seen:
        seen.add(pid)
        entry = table.get(pid)
        if not entry:
            break
        ppid, comm, proc_tty = entry
        if not tty and proc_tty and proc_tty != "??":
            tty = proc_tty
        base = os.path.basename(comm)
        if base in TERMINAL_NAMES:
            return base, tty, str(pid)
        pid = ppid
    return "", tty, "0"


def process_context(payload: dict) -> tuple[str, str, str]:
    """Find the terminal window hosting this session: match the session's
    working folder against the running agent processes, then walk up to the
    terminal app that owns that process."""
    table = process_table()
    cwd = str(payload.get("cwd") or "").strip()
    owner = match_agent_pid(table, cwd)
    if owner:
        terminal, term_pid = ancestor_terminal(table, owner)
        return terminal, table[owner][2], str(term_pid)
    return chain_context(table)


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


def status_nonce(path: Path) -> str:
    """Every status write carries a fresh nonce, so a later event can be told
    apart from the write that preceded it even inside the same second."""
    try:
        record = json.loads(path.read_text())
        return str(record.get("nonce") or "")
    except (OSError, json.JSONDecodeError):
        return ""


def schedule_terminal_watch() -> None:
    """Confirm a possible wait with a delayed re-check. Permission hooks fire
    even for tools the agent then runs without the user (Codex auto-approves,
    Copilot auto-runs), so do not alert on the event itself: keep working and
    look again a few seconds later. Only a still-pending request turns the
    light orange."""
    set_state("working")
    target = status_nonce(session_path() if SESSION_ID
                          else STATUS_DIR / f"status.{SOURCE}.json")
    if not target:
        return
    table = process_table()
    owner = match_agent_pid(table, str(payload.get("cwd") or ""))
    baseline = ",".join(str(pid) for pid in descendants_of(table, owner))
    helper = [sys.executable, str(Path(__file__).resolve()),
              "watch-awaiting", SOURCE, SCOPE_ARG, target, SESSION_ID, SESSION_LABEL,
              TERMINAL, TTY, TERMINAL_PID, str(owner), baseline]
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
    cwd = Path.cwd().resolve()
    for root in scope_roots():
        try:
            cwd.relative_to(root.resolve())
            return True
        except (OSError, ValueError):
            continue
    return False

def set_state(state: str) -> None:
    subprocess.run([str(CLI), state, SOURCE, SESSION_ID, SESSION_LABEL,
                    TERMINAL, TTY, TERMINAL_PID], stdin=subprocess.DEVNULL,
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
    SESSION_ID = sys.argv[5] if len(sys.argv) > 5 else ""
    SESSION_LABEL = sys.argv[6] if len(sys.argv) > 6 else ""
    TERMINAL = sys.argv[7] if len(sys.argv) > 7 else ""
    TTY = sys.argv[8] if len(sys.argv) > 8 else ""
    TERMINAL_PID = sys.argv[9] if len(sys.argv) > 9 else "0"
    owner = int(sys.argv[10]) if len(sys.argv) > 10 and sys.argv[10].isdigit() else 0
    baseline = {int(value) for value in sys.argv[11].split(",")
                if value.strip().isdigit()} if len(sys.argv) > 11 else set()
    time.sleep(1.0)
    path = session_path() if SESSION_ID else STATUS_DIR / f"status.{SOURCE}.json"
    resolved = not target or status_nonce(path) != target
    if not resolved and owner:
        table = process_table()
        started = {pid for pid in descendants_of(table, owner) if pid not in baseline}
        if started:
            resolved = True
    log_event("awaiting-check", {"session_id": SESSION_ID,
                                 "decision": "resolved" if resolved else "input-required"})
    if not resolved:
        set_state("awaiting-input")
    raise SystemExit(0)

SESSION_ID, SESSION_LABEL = session_identity(payload)
TERMINAL, TTY, TERMINAL_PID = process_context(payload)
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
    # Codex asks permission for every tool, including ones it then runs without
    # the user, so confirm the wait instead of alerting immediately.
    schedule_terminal_watch()
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
