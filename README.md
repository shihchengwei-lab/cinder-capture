# cinder-capture: Make Claude Code's Companion More Than Decoration

**Languages:** **English** · [繁體中文](README.zh-TW.md)

## The Problem

Claude Code ships with a companion — a little goose named Cinder. While you talk to Claude, Cinder shows comments in a speech bubble next to the input box.

The catch: **Cinder spends your tokens calling the API to generate those responses, but the text is "burn after reading" — never written to any file, never added to the conversation context.** If you want Claude to know what Cinder said, you have to screenshot it and paraphrase it yourself.

This README documents how we solved that.

## Why It's Worth Doing

The companion isn't just decoration. In real usage, we recorded Cinder correcting the main model 11 turns in a row with zero false positives — actual logic errors, structural anti-patterns, and direction drift. Not random pet noise. You already paid for those tokens, but every correction disappears the moment the screen scrolls.

## TL;DR

We get every Cinder bubble auto-archived, and via a `UserPromptSubmit` hook the latest entries get auto-injected into Claude's context as `[Cinder] ...` lines on your next prompt. You no longer need to play telephone, and Claude doesn't need to remember to `tail` the log every turn.

**Stack:** Windows UIAutomation + Claude Code Stop Hook + UserPromptSubmit Hook

**Limitation:** Windows Terminal only (not macOS Terminal, not Claude Code Desktop app). macOS users would need to port this to the Accessibility API.

---

## What We Tried (and Why It Failed)

Before landing on a working approach, we ruled out a long list of paths:

| Approach | Result | Reason |
|------|------|------|
| PowerShell `Start-Transcript` | ❌ | Only captures PowerShell's own stdout |
| `script -c claude` | ❌ | Claude Desktop doesn't run inside a shell |
| `NODE_OPTIONS=--require` injection | ❌ | The SEA binary ignores it entirely |
| Monkey-patch `fetch`/`undici` | ❌ | Same — can't inject |
| Edit hidden fields in `.claude.json` | ❌ | The app only reads name/personality/species/hatchedAt |
| Patch the Electron `app.asar` | ❌ | asar integrity check + the OnlyLoadAppFromAsar fuse |
| Chrome DevTools Protocol | ❌ | Ed25519 signature verification — needs Anthropic's private key |
| UI Automation (Electron app) | ❌ | The Cinder bubble isn't in the accessibility tree |
| Read the JSONL conversation log | ❌ | Only contains `companion_intro`, not the actual response text |
| ~~UserPromptSubmit hook injecting `additionalContext`~~ | ~~❌~~ → ✅ | ~~`additionalContext` doesn't apply to command-type hooks~~ — **early misjudgement, later confirmed to work, see Step 7** |

**The core bottleneck:** Cinder's responses live in only two places — the encrypted HTTPS API response and the screen pixels. Every node in between sits inside the sealed binary.

---

## The Working Approach: UIAutomation + Stop Hook

### Key Insight

**Windows Terminal's `TermControl` element supports the UIAutomation TextPattern** — meaning you can read all the plain text in the terminal, including the contents of Cinder's bubble.

Earlier UI Automation attempts against the Electron app failed because the Cinder bubble in Electron isn't in the accessibility tree. Windows Terminal, however, has a complete accessibility implementation, and the terminal text really is in the tree.

### What the Cinder Bubble Looks Like in Practice

In the terminal text, Cinder's bubble looks like this:

```
                                          ╭────────────────────────────╮
                                          │ bubble text goes here,     │    \^^^/
                                          │ can span multiple lines    │      (✦>
                                          ╰────────────────────────────╯    Cinder
```

Framed by `╭╮╰╯`, content wrapped in `│`. Regex parsing is straightforward.

---

## Architecture

```
Claude finishes a response
  → Stop hook fires (async, non-blocking)
  → capture.py waits, then starts polling (waiting for Cinder to render the bubble)
  → PowerShell UIAutomation reads the full text of every Terminal window's TermControl
  → Python parses the ╭│╰ bubble frame and extracts the text
  → Deduplicate and append to ~/.claude/cinder_log.jsonl

You send your next prompt
  → UserPromptSubmit hook triggers inject.py
  → Read every entry in cinder_log.jsonl after the watermark
  → Drop anything older than 8 hours (absolute ceiling, cross-session safety net)
  → Write each entry to stdout as [Cinder] (relative time) ...
  → Update the watermark file so each entry is injected exactly once
  → The harness treats stdout as additionalContext and folds it into the prompt
  → Claude naturally sees Cinder's accumulated context this turn
```

---

## Quick Verify — Check Whether Your Environment Can Run It

After cloning, one command checks every prerequisite:

```powershell
git clone https://github.com/shihchengwei-lab/cinder-capture.git
cd cinder-capture
powershell -ExecutionPolicy Bypass -File verify.ps1
```

You should see something like:

```
=== cinder-capture environment check ===

  [PASS] Windows OS
  [PASS] Python 3.x
  [PASS] UIAutomation assemblies
  [PASS] Windows Terminal running
  [PASS] TermControl TextPattern readable    83408 chars in buffer
  [PASS] Cinder companion detected           Label + bubble border found
  [PASS] Claude Code CLI
  [PASS] Bash available

=== Result ===
  9 passed, 0 failed, 0 warnings

  Ready to use cinder-capture!
```

**Only proceed if everything passes.** If anything FAILs, fix that first.

### Prerequisites

- Windows 10/11
- Windows Terminal (not legacy cmd.exe or ConHost)
- Python 3.x (on PATH)
- Claude Code CLI (with the companion feature)
- Bash (Git Bash is fine)

---

## Installation

### 1. Clone or create the `cinder-capture/` directory

```bash
git clone https://github.com/shihchengwei-lab/cinder-capture.git
cd cinder-capture
```

### 2. `config.json` — configuration

Copy `config.example.json` to `config.json` and edit `log_path`:

```json
{
  "delay_seconds": 4,
  "log_path": "C:/Users/YOUR_USERNAME/.claude/cinder_log.jsonl",
  "terminal_class": "CASCADIA_HOSTING_WINDOW_CLASS",
  "term_control_class": "TermControl",
  "cinder_marker": "Cinder",
  "inject_max_age_seconds": 28800,
  "inject_max_entries": 30
}
```

Replace `YOUR_USERNAME` with your Windows username. If your companion isn't named Cinder, change `cinder_marker` to its name.

`inject_max_age_seconds` is the **absolute ceiling** — Cinder messages older than this are treated as cross-session leftovers and dropped. The default of 8 hours (28800 seconds) corresponds to "the upper bound of one work session"; setting it too short means you'll lose messages whenever you switch tabs to scroll YouTube or step out for a while. `inject_max_entries` caps how many entries can be injected at once. The default of 30 corresponds to "unlikely to accumulate more than that within 8 hours, but small enough not to flood the context in one shot." When the actual number of fresh entries exceeds this cap, `inject.py` prepends a `[cinder-capture]` meta marker line telling Claude "N entries were dropped, here's what's left" — so context loss isn't silent.

### 3. `read_terminal.ps1` — PowerShell UIAutomation reader

```powershell
# Read the TermControl text from every Terminal window.
# Multiple windows are joined with ===TERMINAL_SEPARATOR===
param(
    [string]$OutputPath = "$PSScriptRoot\.terminal_raw.txt",
    [string]$TerminalClass = "CASCADIA_HOSTING_WINDOW_CLASS",
    [string]$TermCtrlClass = "TermControl"
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement

# Find ALL Windows Terminal windows
$termCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty, $TerminalClass
)
$allTerminals = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $termCond)
if ($allTerminals.Count -eq 0) { exit 1 }

$allTexts = @()

foreach ($terminal in $allTerminals) {
    $ctrlCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty, $TermCtrlClass
    )
    $allControls = $terminal.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants, $ctrlCond
    )
    if ($allControls.Count -eq 0) { continue }

    # Pick the active tab (not offscreen)
    $termControl = $null
    foreach ($ctrl in $allControls) {
        if (-not $ctrl.Current.IsOffscreen) {
            $termControl = $ctrl
            break
        }
    }
    if (-not $termControl) { $termControl = $allControls[0] }

    try {
        $textPattern = $termControl.GetCurrentPattern(
            [System.Windows.Automation.TextPattern]::Pattern
        )
        $fullText = $textPattern.DocumentRange.GetText(-1)
        if ($fullText) {
            $allTexts += $fullText
        }
    } catch {
        continue
    }
}

if ($allTexts.Count -eq 0) { exit 1 }

$output = $allTexts -join "`n===TERMINAL_SEPARATOR===`n"
[System.IO.File]::WriteAllText($OutputPath, $output, [System.Text.Encoding]::UTF8)
exit 0
```

### 4. `capture.py` — main capture logic

```python
"""capture.py — Read terminal text via UIAutomation, extract companion bubble, write to log."""
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
    """Read text from all terminal windows. Returns one segment per window."""
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
    """Extract companion's speech bubble text from terminal output."""
    lines = text.split("\n")
    bubble_bottom = -1
    bubble_top = -1

    # Search from bottom for the bubble closing border near companion label
    for i in range(len(lines) - 1, max(0, len(lines) - 50) - 1, -1):
        if "\u2570" in lines[i] and "\u256f" in lines[i] and marker in lines[i]:
            bubble_bottom = i
            break
    # Fallback: closing border within 2 lines of label
    if bubble_bottom < 0:
        for i in range(len(lines) - 1, max(0, len(lines) - 50) - 1, -1):
            if "\u2570" in lines[i] and "\u256f" in lines[i]:
                nearby = " ".join(lines[i:min(len(lines), i + 3)])
                if marker in nearby:
                    bubble_bottom = i
                    break

    if bubble_bottom < 0:
        return ""

    for i in range(bubble_bottom - 1, max(0, bubble_bottom - 30) - 1, -1):
        if "\u256d" in lines[i] and "\u256e" in lines[i]:
            bubble_top = i
            break
    if bubble_top < 0:
        return ""

    content_lines = []
    for i in range(bubble_top + 1, bubble_bottom):
        match = re.search(r"\u2502\s*(.*)\s*\u2502", lines[i])
        if match:
            text_part = match.group(1).strip()
            if text_part:
                content_lines.append(text_part)

    return " ".join(content_lines).strip()


def append_log(log_path: str, text: str) -> bool:
    """Append entry to JSONL log. Returns True if written (not duplicate)."""
    log_file = Path(log_path)
    log_file.parent.mkdir(parents=True, exist_ok=True)
    if log_file.exists():
        content = log_file.read_text(encoding="utf-8").strip()
        if content:
            try:
                last = json.loads(content.split("\n")[-1])
                if last.get("text") == text:
                    return False
            except json.JSONDecodeError:
                pass

    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "text": text, "source": "uia_capture",
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


if __name__ == "__main__":
    main()
```

### 5. `run_capture.sh` — hook wrapper

```bash
#!/bin/bash
python "C:/Users/YOUR_USERNAME/cinder-capture/capture.py" > /dev/null 2>&1 &
disown
exit 0
```

Remember to `chmod +x run_capture.sh` and replace the path.

> ⚠️ **Do not remove the `> /dev/null 2>&1 &` or the `disown`.** If a Stop hook child process keeps stdout connected to Claude's terminal, its output is treated as a new conversation message and shoved back into the session — triggering another Stop event → infinite loop. The redirect + disown is a loop guard, not decoration.

### 6. Configure the Stop hook

Add this to the `hooks` section of `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash C:/Users/YOUR_USERNAME/cinder-capture/run_capture.sh",
            "async": true
          }
        ]
      }
    ]
  }
}
```

### 7. Configure auto-injection (recommended)

Add a `UserPromptSubmit` hook to the `hooks` section of `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python C:/Users/YOUR_USERNAME/cinder-capture/inject.py",
            "timeout": 5000
          }
        ]
      }
    ]
  }
}
```

`inject.py` (included in the repo) runs every time you press Enter to send a prompt and:

1. Reads the watermark file (`cinder_log.jsonl.watermark`) to know what was injected last time
2. Pulls every entry whose timestamp is **newer than the watermark** AND **within the last 8 hours** (`inject_max_age_seconds`, default 28800)
3. Keeps the last N entries (`inject_max_entries`, default 30). If more than N accumulated, it prepends a `[cinder-capture]` meta marker telling Claude how many were dropped, the relative time of the oldest one kept, and that the dropped context is unrecoverable
4. Writes each entry to stdout as `[Cinder] (relative time) <bubble text>`, e.g.:
   ```
   [cinder-capture] 12 earlier Cinder messages within the 28800s window were truncated to fit inject_max_entries=30; oldest shown is 6 hr ago. Earlier context is unrecoverable.
   [Cinder] (6 hr ago) Honk — that default of 999 is just stubbornness.
   [Cinder] (5 min ago) Honk — if you won't drop the default, slap NOT NULL on it.
   [Cinder] (just now) Honk — that orphan function is still playing dead.
   ```
5. Advances the watermark to the latest entry's timestamp so nothing gets re-injected next turn
6. The Claude Code harness treats the entire stdout as `additionalContext` and folds it into the prompt

This turn, Claude naturally sees Cinder's **accumulated context** — not just the last bubble, but everything Cinder said since the last injection. Multi-turn arguments (like "stubborn default → NOT NULL safety net → orphan function playing dead") keep their causal chain intact.

> 💡 An earlier version of this repo wrongly believed that "`additionalContext` doesn't apply to command-type hooks." Empirically: a command-type UserPromptSubmit hook only needs to write plain text to stdout and exit 0, and the harness will inject it as context. See the "Add context to the conversation" example in the [official Claude Code hook docs](https://code.claude.com/docs/en/hooks.md).

### 8. Configure CLAUDE.md (fallback, optional)

If you can't add a UserPromptSubmit hook (e.g. you can't edit `settings.json`), use a CLAUDE.md instruction as a fallback — making Claude itself `tail -1` the log every turn:

```markdown
## Cinder Integration

- Cinder's bubble text is auto-captured by a Stop hook into `~/.claude/cinder_log.jsonl`
- Before each reply, read the last entry; if it's within 120 seconds, take it into account
- A quick `tail -1 ~/.claude/cinder_log.jsonl` is enough
- Cinder often has insights — don't ignore them
```

> Pick Step 7 OR Step 8, not both. Step 7 is the recommended path (hook-driven, no token cost, Claude doesn't need to remember the rule); Step 8 is a fallback that relies on Claude's discipline to make an extra Bash call every turn.

---

## How It Works

1. **You converse normally** — no extra steps required
2. **Claude finishes a response** → the Stop hook launches `capture.py` in the background
3. **Wait, then poll** (so Cinder has time to finish its API call and render)
4. **PowerShell scans every Windows Terminal window** (via UIAutomation TextPattern)
5. **Python parses bubbles per window**: find the `╭╮` top → `││` content → `╰╯` bottom + companion label
6. **Deduplicate and append to `cinder_log.jsonl`**
7. **You send your next prompt** → the UserPromptSubmit hook triggers `inject.py`
8. **`inject.py` reads the watermark file** and pulls every entry newer than the watermark and within the 8-hour window
9. **Each entry is written to stdout as `[Cinder] (relative time) ...`** and the watermark is advanced to prevent duplicate injection
10. **The Claude Code harness folds stdout into the prompt as `additionalContext`** so Claude naturally sees Cinder's accumulated context

---

## Customising the Companion Name

If your companion isn't named Cinder (e.g. Snarl, Ember, etc.), edit `cinder_marker` in `config.json`:

```json
{
  "cinder_marker": "Snarl"
}
```

The script will look for the matching label at the bottom of the bubble automatically.

---

## Known Limitations

- **Windows Terminal only**: depends on UIAutomation support for `CASCADIA_HOSTING_WINDOW_CLASS` and `TermControl`
- **Polling latency**: you have to wait for Cinder to finish rendering. If Cinder's API response is unusually slow, raise `delay_seconds` or `max_attempts`
- **Bubble eviction**: if you start typing before the Cinder bubble appears, the bubble can get pushed out of view by new content
- **Timing race**: the Stop hook's capture polling window is roughly 16 seconds. If you fire your next prompt before Cinder finishes its current API call, `inject.py` will miss this round's bubble — but because the watermark remembers, the **next** prompt will catch it. Nothing is permanently lost
- **8-hour hard ceiling**: any Cinder message older than 8 hours is dropped as cross-session staleness. If you need a longer memory (e.g. "leave it running overnight, come back the next day"), raise `inject_max_age_seconds`
- **The watermark file**: `cinder_log.jsonl.watermark` lives next to the log; its contents are the ISO timestamp of the last injected entry. Deleting it manually causes the next prompt to re-pull the most recent N entries
- **macOS not supported**: needs a separate implementation using the macOS Accessibility API instead of UIAutomation

## FAQ

**Q: Why not just read the JSONL conversation log?**
A: Cinder's responses aren't written to it. The JSONL only records `companion_intro` (an init marker), not the actual response text.

**Q: Why not Chrome DevTools Protocol?**
A: Claude Desktop's CDP is gated by Ed25519 signature verification. Without Anthropic's private key, you can't connect.

**Q: Can this be made fully automatic?**
A: Yes — that's exactly what Step 7 does. `inject.py`, via the UserPromptSubmit hook, writes Cinder's last-round messages to stdout as `[Cinder] ...` plain text, and the Claude Code harness automatically folds it into the prompt as `additionalContext`. An earlier version of this repo misjudged this as impossible; later testing confirmed it works.

**Q: Does this violate Anthropic's rights?**
A: No. We don't decompile, crack, or bypass any security mechanism. UIAutomation is a public Windows API, and we're reading text that's already displayed on screen.

**Q: Will it grab the wrong terminal if I have several open?**
A: The script scans every Terminal window and finds the one with a companion bubble — it doesn't blindly take the first.

---

## Cinder's Comments On This Project (auto-captured)

- "From decoration to loop variable. Should I celebrate or worry?"
- "Now I'm my own context window. This is what eating your own tail looks like."
- "Honk — an empty log is just a timing problem. Be patient."
- ~~"A hook is just a hook. additionalContext only gets to watch."~~ *(an early-version comment; later confirmed that command-type hooks can inject additionalContext, see Step 7)*
- "'Burn after reading' is the design. On purpose, of course."
