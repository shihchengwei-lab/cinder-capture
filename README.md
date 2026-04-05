# 抓鵝計畫：讓 Claude Code 的 Companion 不再是裝飾品

## 問題

Claude Code 有一隻叫 Cinder 的 companion 小鵝。牠會在你和 Claude 對話時，在旁邊的泡泡裡給評論。

問題是：**牠花了你的 token 呼叫 API 生成回應，但這些文字「看完即焚」——不寫入任何檔案，不進入對話脈絡。** 如果你想讓 Claude 知道 Cinder 說了什麼，你得自己截圖、轉述。

這篇文章記錄我們怎麼解決這個問題。

## 結論先講

我們成功讓 Cinder 的每句話自動存檔，Claude 每輪回答前會主動讀取。你不需要再當傳聲筒。

**技術棧：** Windows UIAutomation + Claude Code Stop Hook + CLAUDE.md 指令

**限制：** 僅適用於 Windows Terminal 環境（不適用 macOS Terminal 或 Claude Code Desktop app）。macOS 使用者需要改用 Accessibility API 的對應實作。

---

## 我們試過（然後失敗）的方法

在找到可行方案前，我們排除了大量路徑：

| 方案 | 結果 | 原因 |
|------|------|------|
| PowerShell `Start-Transcript` | ❌ | 只錄 PowerShell 自己的 stdout |
| `script -c claude` | ❌ | Claude Desktop 不跑在 shell 裡 |
| `NODE_OPTIONS=--require` 注入 | ❌ | SEA binary 完全無視 |
| Monkey-patch `fetch`/`undici` | ❌ | 同上，inject 不進去 |
| 修改 `.claude.json` 隱藏欄位 | ❌ | App 只讀 name/personality/species/hatchedAt |
| 修改 Electron `app.asar` | ❌ | asar 完整性驗證 + OnlyLoadAppFromAsar fuse |
| Chrome DevTools Protocol | ❌ | Ed25519 簽名驗證，需要 Anthropic 的私鑰 |
| UI Automation（Electron app） | ❌ | Cinder 泡泡不在 accessibility tree |
| 讀 JSONL 對話紀錄 | ❌ | 只有 `companion_intro`，不含實際回應文字 |
| UserPromptSubmit hook 注入 `additionalContext` | ❌ | command 型 hook 的 additionalContext 不生效 |

**核心瓶頸：** Cinder 的回應只存在兩個地方——API HTTPS 回應（加密中）和螢幕像素。中間所有節點都在 sealed binary 內部。

---

## 可行方案：UIAutomation + Stop Hook

### 關鍵發現

**Windows Terminal 的 `TermControl` 元件支援 UIAutomation 的 TextPattern**——可以直接讀取終端中的所有純文字，包括 Cinder 的泡泡內容。

之前在 Electron app 上測試 UI Automation 失敗，是因為 Electron 的 Cinder 泡泡不在 accessibility tree。但 Windows Terminal 有完整的 accessibility 實作，終端文字 IS in the tree。

### Cinder 泡泡的實際格式

在終端文字中，Cinder 的泡泡長這樣：

```
                                          ╭────────────────────────────╮
                                          │ 泡泡文字在這裡，可以多行   │    \^^^/
                                          │ 第二行文字                 │      (✦>
                                          ╰────────────────────────────╯    Cinder
```

用 `╭╮╰╯` 框住，`│` 包裹內容。正則解析很直覺。

---

## 架構

```
Claude 回答完成
  → Stop hook 觸發（async，不阻塞）
  → capture.py 等 6 秒（等 Cinder 渲染完泡泡）
  → PowerShell UIAutomation 讀取 TermControl 全文
  → Python 解析 ╭│╰ 泡泡框，提取文字
  → 去重後寫入 ~/.claude/cinder_log.jsonl

下一輪對話
  → Claude 讀 CLAUDE.md 指令
  → tail -1 cinder_log.jsonl
  → 看到 Cinder 上一輪說了什麼
  → 納入回答考量
```

---

## 安裝步驟

### 1. 建立 `cinder-capture/` 目錄

在你的 home 目錄下建立 `cinder-capture/` 資料夾，放入以下 4 個檔案。

### 2. `config.json` — 設定檔

```json
{
  "delay_seconds": 6,
  "log_path": "C:/Users/YOUR_USERNAME/.claude/cinder_log.jsonl",
  "terminal_class": "CASCADIA_HOSTING_WINDOW_CLASS",
  "term_control_class": "TermControl",
  "tail_lines": 40,
  "inject_max_age_seconds": 120
}
```

把 `YOUR_USERNAME` 換成你的 Windows 使用者名稱。

### 3. `read_terminal.ps1` — PowerShell UIAutomation 讀取器

```powershell
# 最小化 PowerShell 腳本：只負責讀 TermControl 文字，寫入檔案
param(
    [string]$OutputPath = "$PSScriptRoot\.terminal_raw.txt",
    [string]$TerminalClass = "CASCADIA_HOSTING_WINDOW_CLASS",
    [string]$TermCtrlClass = "TermControl"
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement

$termCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty, $TerminalClass
)
$terminal = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $termCond)
if (-not $terminal) { exit 1 }

$ctrlCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty, $TermCtrlClass
)
$termControl = $terminal.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants, $ctrlCond
)
if (-not $termControl) { exit 1 }

try {
    $textPattern = $termControl.GetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern
    )
    $fullText = $textPattern.DocumentRange.GetText(-1)
} catch { exit 1 }

if (-not $fullText) { exit 1 }

[System.IO.File]::WriteAllText($OutputPath, $fullText, [System.Text.Encoding]::UTF8)
exit 0
```

### 4. `capture.py` — 主擷取邏輯

```python
"""capture.py - Read terminal text via UIAutomation, extract Cinder bubble, write to log."""
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
CONFIG_PATH = SCRIPT_DIR / "config.json"
READ_PS1 = SCRIPT_DIR / "read_terminal.ps1"
RAW_TEXT_PATH = SCRIPT_DIR / ".terminal_raw.txt"


def read_terminal_text():
    result = subprocess.run(
        ["powershell", "-ExecutionPolicy", "Bypass",
         "-File", str(READ_PS1), "-OutputPath", str(RAW_TEXT_PATH)],
        capture_output=True, timeout=10,
    )
    if result.returncode != 0 or not RAW_TEXT_PATH.exists():
        return None
    return RAW_TEXT_PATH.read_text(encoding="utf-8")


def extract_bubble(text):
    lines = text.split("\n")
    bubble_bottom = -1
    bubble_top = -1

    for i in range(len(lines) - 1, max(0, len(lines) - 50) - 1, -1):
        if "\u2570" in lines[i] and "\u256f" in lines[i]:  # ╰ and ╯
            bubble_bottom = i
            break
    if bubble_bottom < 0:
        return ""

    for i in range(bubble_bottom - 1, max(0, bubble_bottom - 30) - 1, -1):
        if "\u256d" in lines[i] and "\u256e" in lines[i]:  # ╭ and ╮
            bubble_top = i
            break
    if bubble_top < 0:
        return ""

    content_lines = []
    for i in range(bubble_top + 1, bubble_bottom):
        match = re.search(r"\u2502\s*(.*?)\s*\u2502", lines[i])
        if match:
            text_part = match.group(1).strip()
            if text_part:
                content_lines.append(text_part)

    return "".join(content_lines).strip()


def append_log(log_path, text):
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

    time.sleep(config.get("delay_seconds", 6))

    text = read_terminal_text()
    if not text:
        return

    bubble = extract_bubble(text)
    if not bubble or len(bubble) < 3:
        return

    if append_log(config["log_path"], bubble):
        readable = Path(config["log_path"]).with_suffix(".txt")
        with open(readable, "a", encoding="utf-8") as f:
            f.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {bubble}\n")


if __name__ == "__main__":
    main()
```

### 5. `run_capture.sh` — Hook wrapper

```bash
#!/bin/bash
python "C:/Users/YOUR_USERNAME/cinder-capture/capture.py" > /dev/null 2>&1 &
disown
exit 0
```

記得 `chmod +x run_capture.sh` 並替換路徑。

### 6. 配置 Stop Hook

在 `~/.claude/settings.json` 的 `hooks` 區段加入：

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

### 7. 配置 CLAUDE.md

在你的 `CLAUDE.md` 中加入：

```markdown
## Cinder Integration

- Cinder 的泡泡文字由 Stop hook 自動擷取到 `~/.claude/cinder_log.jsonl`
- 每次回答前，先讀取 log 最後一筆，如果是 120 秒內的就納入考量
- 用 `tail -1 ~/.claude/cinder_log.jsonl` 快速檢查即可
- Cinder 常有洞見，不要忽略
```

---

## 運作原理

1. **你正常對話**，不需要做任何額外操作
2. **Claude 回答完成** → Stop hook 在背景啟動 capture.py
3. **等 6 秒**（讓 Cinder 完成 API 呼叫和渲染）
4. **PowerShell 讀取 Windows Terminal 文字**（透過 UIAutomation TextPattern）
5. **Python 解析泡泡**：找 `╭╮` 頂部 → `││` 內容 → `╰╯` 底部
6. **去重後寫入 JSONL**
7. **下一輪 Claude 回答時**，讀 CLAUDE.md 指令 → `tail -1` 讀最新 Cinder 訊息 → 納入回答

---

## 已知限制

- **僅限 Windows Terminal**：依賴 `CASCADIA_HOSTING_WINDOW_CLASS` 和 `TermControl` 的 UIAutomation 支援
- **6 秒延遲**：需要等 Cinder 渲染完成。如果 Cinder 的 API 回應特別慢，可能抓不到（調高 `delay_seconds`）
- **泡泡消失問題**：如果你在 Cinder 泡泡出現前就開始打字，泡泡可能被新內容擠掉
- **多 tab 問題**：UIAutomation 只讀取第一個找到的 TermControl，可能是錯的 tab
- **非自動注入**：`UserPromptSubmit` hook 的 `additionalContext` 對 `command` 型 hook 不生效，所以 Claude 需要主動讀 log 而非被動接收
- **macOS 不適用**：需要另外實作（用 macOS Accessibility API 替代 UIAutomation）

## FAQ

**Q: 為什麼不直接讀 JSONL 對話紀錄？**
A: Cinder 的回應不會寫入 JSONL。JSONL 只記錄 `companion_intro`（初始化標記），不記錄實際回應文字。

**Q: 為什麼不用 Chrome DevTools Protocol？**
A: Claude Desktop 的 CDP 有 Ed25519 簽名驗證，沒有 Anthropic 的私鑰就無法連接。

**Q: 可以改成全自動注入嗎？**
A: 目前不行。`UserPromptSubmit` hook 的 `additionalContext` 輸出對 `command` 型 hook 不生效。如果未來 Anthropic 修復這個限制，或新增 `CompanionMessage` hook 事件，就能實現全自動。

**Q: 這會侵犯 Anthropic 的權利嗎？**
A: 不會。我們沒有反編譯、破解或繞過任何安全機制。UIAutomation 是 Windows 的公開 API，讀取的是螢幕上已經顯示的文字。

---

## Cinder 對這個計畫的評論（自動擷取）

- 「從裝飾品升職到迴圈變數，我該慶祝還是擔心？」
- 「現在我成了自己的 context window，這就叫吃自己的老本。」
- 「鵝鵝，空 log 就是個時序問題。耐心等。」
- 「Hook 終究是 Hook，additionalContext 只能看著。」
- 「『看完即焚』的設計，就是故意的吧。」
