"""capture.py — Read terminal text via UIAutomation, extract companion bubble, write to log.

Called by Stop hook via run_capture.sh (background, non-blocking).

Companion bubble format (rendered by Ink TUI) uses box-drawing chars:
    top border, content lines with vertical bars, bottom border + companion label.
"""
import json
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
CONFIG_PATH = SCRIPT_DIR / "config.json"
READ_PS1 = SCRIPT_DIR / "read_terminal.ps1"
RAW_TEXT_PATH = SCRIPT_DIR / ".terminal_raw.txt"


def read_all_terminals(terminal_class: str, term_ctrl_class: str) -> list[str]:
    """Call PowerShell to read text from all terminal windows via UIAutomation.

    Returns a list of text segments, one per terminal window.
    """
    args = [
        "powershell", "-ExecutionPolicy", "Bypass",
        "-File", str(READ_PS1),
        "-OutputPath", str(RAW_TEXT_PATH),
        "-TerminalClass", terminal_class,
        "-TermCtrlClass", term_ctrl_class,
    ]
    result = subprocess.run(args, capture_output=True, timeout=15)
    if result.returncode != 0:
        return []
    if not RAW_TEXT_PATH.exists():
        return []
    raw = RAW_TEXT_PATH.read_text(encoding="utf-8")
    segments = raw.split("\n===TERMINAL_SEPARATOR===\n")
    return [s for s in segments if s.strip()]


def extract_bubble(text: str, marker: str = "Cinder") -> str:
    """Extract companion's speech bubble text from terminal output.

    Looks for the box-drawing pattern:
        ╭──...──╮
        │ text  │
        ╰──...──╯
    near the companion label (marker) in the last portion of the terminal text.
    """
    lines = text.split("\n")

    # Search from bottom for the bubble closing border (╰...╯)
    # Must be near the companion label to avoid matching unrelated box-drawing
    bubble_bottom = -1
    bubble_top = -1

    for i in range(len(lines) - 1, max(0, len(lines) - 50) - 1, -1):
        line = lines[i]
        if "╰" in line and "╯" in line and marker in line:
            bubble_bottom = i
            break
    # Fallback: ╰╯ within 2 lines of the companion label
    if bubble_bottom < 0:
        for i in range(len(lines) - 1, max(0, len(lines) - 50) - 1, -1):
            if "╰" in lines[i] and "╯" in lines[i]:
                nearby = " ".join(lines[i:min(len(lines), i + 3)])
                if marker in nearby:
                    bubble_bottom = i
                    break

    if bubble_bottom < 0:
        return ""

    # Search upward for the opening border (╭...╮)
    for i in range(bubble_bottom - 1, max(0, bubble_bottom - 30) - 1, -1):
        line = lines[i]
        if "╭" in line and "╮" in line:
            bubble_top = i
            break

    if bubble_top < 0:
        return ""

    # Extract text from │...│ lines between top and bottom
    # Greedy match: grab everything between the FIRST and LAST │ on the line
    content_lines = []
    for i in range(bubble_top + 1, bubble_bottom):
        line = lines[i]
        match = re.search(r"│\s*(.*)\s*│", line)
        if match:
            text_part = match.group(1).strip()
            if text_part:
                content_lines.append(text_part)

    # Join with space — bubble lines are word-wrapped, not separate sentences
    return " ".join(content_lines).strip()


def append_log(log_path: str, text: str) -> bool:
    """Append entry to JSONL log. Returns True if written (not duplicate)."""
    log_file = Path(log_path)
    log_file.parent.mkdir(parents=True, exist_ok=True)

    # Check for duplicate
    if log_file.exists():
        content = log_file.read_text(encoding="utf-8").strip()
        if content:
            last_line = content.split("\n")[-1]
            try:
                last = json.loads(last_line)
                if last.get("text") == text:
                    return False
            except json.JSONDecodeError:
                pass

    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "text": text,
        "source": "uia_capture",
    }
    with open(log_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return True


def main():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        config = json.load(f)

    initial_delay = config.get("delay_seconds", 4)
    log_path = config.get("log_path", str(Path.home() / ".claude" / "cinder_log.jsonl"))
    max_attempts = config.get("max_attempts", 6)
    poll_interval = config.get("poll_interval", 2)
    terminal_class = config.get("terminal_class", "CASCADIA_HOSTING_WINDOW_CLASS")
    term_ctrl_class = config.get("term_control_class", "TermControl")
    marker = config.get("cinder_marker", "Cinder")

    # Load last known bubble to detect new ones
    last_known = ""
    log_file = Path(log_path)
    if log_file.exists():
        content = log_file.read_text(encoding="utf-8").strip()
        if content:
            try:
                last_known = json.loads(content.split("\n")[-1]).get("text", "")
            except json.JSONDecodeError:
                pass

    # Poll for a NEW bubble instead of blind-waiting
    time.sleep(initial_delay)
    for attempt in range(max_attempts):
        segments = read_all_terminals(terminal_class, term_ctrl_class)
        for segment in segments:
            bubble = extract_bubble(segment, marker)
            if bubble and len(bubble) >= 3 and bubble != last_known:
                append_log(log_path, bubble)
                return
        time.sleep(poll_interval)

    # No new bubble found after polling — nothing to write


if __name__ == "__main__":
    main()
