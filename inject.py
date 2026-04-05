"""inject.py — UserPromptSubmit hook: read latest Cinder message and inject as additionalContext."""
import json
import sys
import os
from datetime import datetime, timezone

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")

def main():
    # Read stdin first (hook input) — must consume it
    try:
        sys.stdin.read()
    except Exception:
        pass

    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        config = json.load(f)

    log_path = config["log_path"]
    max_age = config.get("inject_max_age_seconds", 120)

    if not os.path.exists(log_path):
        return

    last_line = ""
    with open(log_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                last_line = line

    if not last_line:
        return

    try:
        entry = json.loads(last_line)
    except json.JSONDecodeError:
        return

    text = entry.get("text", "").strip()
    timestamp_str = entry.get("timestamp", "")

    if not text:
        return

    try:
        ts = datetime.fromisoformat(timestamp_str)
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        age = (datetime.now(timezone.utc) - ts).total_seconds()
        if age > max_age:
            return
    except (ValueError, TypeError):
        return

    # Output additionalContext — use print + flush to ensure delivery
    output = json.dumps({"additionalContext": f"[Cinder] {text}"}, ensure_ascii=True)
    sys.stdout.write(output)
    sys.stdout.flush()


if __name__ == "__main__":
    main()
