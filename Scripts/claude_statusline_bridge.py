#!/usr/bin/env python3
"""Cache Claude Code rate_limits and preserve the user's existing statusLine."""
import argparse
import json
import math
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def cache(data, cache_file):
    if len(data) > 1_048_576:
        raise ValueError("statusLine JSON exceeds 1 MiB")
    payload = json.loads(data)
    limits = payload.get("rate_limits")
    if limits is None:
        return  # No new reading: keep its original timestamp, so it expires normally.
    if not isinstance(limits, dict):
        raise ValueError("rate_limits must be an object")
    windows = {}
    for key in ("five_hour", "seven_day"):
        window = limits.get(key)
        if window is None:
            continue
        if not isinstance(window, dict):
            raise ValueError("rate limit window must be an object")
        used, reset = window.get("used_percentage"), window.get("resets_at")
        if (type(used) not in (int, float) or not math.isfinite(used) or not 0 <= used <= 100
                or type(reset) not in (int, float) or not math.isfinite(reset) or reset <= 0):
            raise ValueError("invalid rate limit window")
        windows[key] = {"used_percentage": used, "resets_at": reset}
    atomic_write(cache_file, json.dumps({"updated_at": time.time(), "rate_limits": windows}).encode())


def settings_write(path, settings, original):
    # Refuse to overwrite a concurrent settings edit; each successful change has an exact byte backup.
    if (path.read_bytes() if path.exists() else None) != original:
        raise RuntimeError("settings.json changed during installation; retry")
    backup = path.with_name(path.name + ".codexbar-statusline." + str(time.time_ns()) + ".bak")
    if original is not None:
        atomic_write(backup, original)
    atomic_write(path, (json.dumps(settings, indent=2, ensure_ascii=False) + "\n").encode())
    return backup if original is not None else None


def configure(action, home_dir):
    settings_path = home_dir / ".claude/settings.json"
    original = settings_path.read_bytes() if settings_path.exists() else None
    settings = json.loads(original) if original is not None else {}
    if not isinstance(settings, dict):
        raise ValueError("settings.json must be a JSON object")
    directory = home_dir / ".codexbar/statusline"
    state_path = directory / "installation.json"
    executable = directory / "bridge.py"
    command = " ".join(shlex.quote(part) for part in
                       (sys.executable, str(executable), "run", "--home", str(home_dir)))
    current = settings.get("statusLine")
    current_command = current.get("command") if isinstance(current, dict) else None
    if action == "install":
        if state_path.exists():
            state = json.loads(state_path.read_bytes())
            if current_command == state["command"]:
                print("CodexBar statusLine bridge is already installed.")
                return
            raise RuntimeError("An installation already exists; uninstall it before reinstalling")
        previous = settings.get("statusLine")
        if previous is not None and (not isinstance(previous, dict)
                                     or previous.get("type", "command") != "command"
                                     or not isinstance(previous.get("command"), str)):
            raise ValueError("Existing statusLine is not a command; settings were left untouched")
        atomic_write(executable, Path(__file__).resolve().read_bytes())
        state = {"command": command, "previous": previous}
        atomic_write(state_path, json.dumps(state).encode())
        settings["statusLine"] = {**(previous or {}), "type": "command", "command": command}
        try:
            backup = settings_write(settings_path, settings, original)
        except Exception:
            state_path.unlink()
            raise
    else:
        if not state_path.exists():
            print("CodexBar statusLine bridge is not installed.")
            return
        state = json.loads(state_path.read_bytes())
        if current_command != state["command"]:
            raise RuntimeError("statusLine changed since installation; restore from the backup manually")
        if state["previous"] is None:
            settings.pop("statusLine", None)
        else:
            settings["statusLine"] = state["previous"]
        backup = settings_write(settings_path, settings, original)
        state_path.unlink()
    print(f"CodexBar statusLine bridge {action} complete. Backup: {backup or 'settings did not exist'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "uninstall", "cache", "run"))
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--cache-file", type=Path)
    args = parser.parse_args()
    if args.action in ("install", "uninstall"):
        configure(args.action, args.home.expanduser().resolve())
        return 0
    data = sys.stdin.buffer.read()
    try:
        cache(data, args.cache_file or args.home / ".codexbar/claude-statusline.json")
    except (ValueError, OSError, AttributeError, OverflowError):
        pass  # Feed drift must never break the user's statusLine command.
    if args.action == "run":
        state = json.loads((args.home / ".codexbar/statusline/installation.json").read_bytes())
        previous = state.get("previous")
        if previous:
            return subprocess.run(previous["command"], shell=True, executable="/bin/sh", input=data).returncode
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, RuntimeError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
