"""inject.py — UserPromptSubmit hook: inject unseen Cinder messages as additionalContext.

Reads cinder_log.jsonl for entries newer than the watermark file and within the
absolute age ceiling, then writes them to stdout as plain text. Claude Code's
hook contract treats stdout (exit 0) as context to inject into the next prompt.

Watermark file (cinder_log.jsonl.watermark) tracks the timestamp of the last
entry that was injected, so each entry is delivered exactly once even if the
user has been idle for a while.
"""
import json
import sys
import os
from datetime import datetime, timezone, timedelta

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")


def parse_ts(ts_str):
    """Parse an ISO timestamp, defaulting naive timestamps to UTC. Returns None on failure."""
    try:
        ts = datetime.fromisoformat(ts_str)
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        return ts
    except (ValueError, TypeError):
        return None


def format_relative(delta):
    """Format a timedelta as 'just now', 'X min ago', 'X hr ago'."""
    seconds = int(delta.total_seconds())
    if seconds < 30:
        return "just now"
    if seconds < 90:
        return "1 min ago"
    if seconds < 3600:
        return f"{seconds // 60} min ago"
    if seconds < 7200:
        return "1 hr ago"
    return f"{seconds // 3600} hr ago"


def read_watermark(watermark_path):
    """Return the watermark datetime, or None if missing/invalid."""
    if not os.path.exists(watermark_path):
        return None
    try:
        with open(watermark_path, "r", encoding="utf-8") as f:
            content = f.read().strip()
    except Exception:
        return None
    if not content:
        return None
    return parse_ts(content)


def write_watermark(watermark_path, ts):
    """Persist watermark timestamp. Best-effort: failures are silent."""
    try:
        with open(watermark_path, "w", encoding="utf-8") as f:
            f.write(ts.isoformat() + "\n")
    except Exception:
        pass


def read_log_entries(log_path):
    """Return a list of {'text', 'ts'} dicts from the log, skipping malformed lines."""
    entries = []
    try:
        with open(log_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                text = (entry.get("text") or "").strip()
                ts_str = entry.get("timestamp") or ""
                if not text or not ts_str:
                    continue
                ts = parse_ts(ts_str)
                if ts is None:
                    continue
                entries.append({"text": text, "ts": ts})
    except Exception:
        pass
    return entries


def main():
    # Force UTF-8 stdout — on Windows, Python defaults to the system code page
    # (e.g. CP950) which corrupts non-ASCII Cinder text the harness expects as UTF-8.
    try:
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    except Exception:
        pass

    # Consume stdin (hook input event) so Claude Code's writer doesn't block.
    try:
        sys.stdin.read()
    except Exception:
        pass

    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            config = json.load(f)
    except Exception:
        return

    log_path = config.get("log_path")
    if not log_path or not os.path.exists(log_path):
        return

    max_age = config.get("inject_max_age_seconds", 28800)  # 8 hours
    max_entries = config.get("inject_max_entries", 30)
    watermark_path = log_path + ".watermark"

    entries = read_log_entries(log_path)
    if not entries:
        return

    now = datetime.now(timezone.utc)
    age_cutoff = now - timedelta(seconds=max_age)
    watermark = read_watermark(watermark_path)

    fresh = [
        e for e in entries
        if e["ts"] >= age_cutoff and (watermark is None or e["ts"] > watermark)
    ]
    if not fresh:
        return

    # Cap to the most recent N entries to avoid spam after long absences.
    # When we truncate, emit a meta-marker so Claude knows context is incomplete
    # and the dropped entries are gone for good (watermark advances past them).
    total_fresh = len(fresh)
    if total_fresh > max_entries:
        fresh = fresh[-max_entries:]
        truncated = total_fresh - max_entries
        oldest_kept_age = format_relative(now - fresh[0]["ts"])
        marker = (
            f"[cinder-capture] {truncated} earlier Cinder messages within the "
            f"{max_age}s window were truncated to fit inject_max_entries={max_entries}; "
            f"oldest shown is {oldest_kept_age}. Earlier context is unrecoverable."
        )
        lines = [marker]
    else:
        lines = []

    lines.extend(
        f"[Cinder] ({format_relative(now - e['ts'])}) {e['text']}"
        for e in fresh
    )
    sys.stdout.write("\n".join(lines) + "\n")
    sys.stdout.flush()

    write_watermark(watermark_path, fresh[-1]["ts"])


if __name__ == "__main__":
    main()
