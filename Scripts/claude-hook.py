#!/usr/bin/env python3
"""Translate Claude Code lifecycle hooks into Agent Status Light states."""
import json
import os
import subprocess
import sys
from pathlib import Path

CLI = Path(__file__).with_name("agent-status-light")
SOURCE = sys.argv[2] if len(sys.argv) > 2 else "claude"
SCOPE_ROOT = Path(sys.argv[3]).expanduser() if len(sys.argv) > 3 else Path.home() / "Development"

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

if event == "pre":
    set_state("working")
elif event == "stop":
    set_state("done")
elif event == "session-end":
    set_state("off")
elif event == "post":
    response = payload.get("tool_response") or {}
    failed = (response.get("is_error") is True or
              response.get("success") is False or
              bool(response.get("error")))
    if failed:
        set_state("error")
