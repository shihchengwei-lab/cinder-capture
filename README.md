# 抓鵝計畫：讓 Claude Code 的 Companion 不再是裝飾品

## 問題

Claude Code 有一隻叫 Cinder 的 companion 小鵝。牠會在你和 Claude 對話時，在旁邊的泡泡裡給評論。

問題是：**牠花了你的 token 呼叫 API 生成回應，但這些文字「看完即焚」——不寫入任何檔案，不進入對話脈絡。** 如果你想讓 Claude 知道 Cinder 說了什麼，你得自己截圖、轉述。

這篇文章記錄我們怎麼解決這個問題。

## 為什麼值得做

Companion 不只是裝飾。實測中曾紀錄到 Cinder 對主模型連續 11 輪糾正、零誤判，內容是真實的邏輯錯誤、結構性反模式與方向偏離——不是隨機的寵物廢話。這些糾正你已經付了 token，但每一條都隨著畫面捲動消失。

## 結論先講

我們成功讓 Cinder 的每句話自動存檔，並透過 UserPromptSubmit hook 在你下一輪送出 prompt 時自動以 `[Cinder] ...` 的形式注入到 Claude 看到的 context 裡。你不需要再當傳聲筒，Claude 也不需要每輪主動 tail。

**技術棧：** Windows UIAutomation + Claude Code Stop Hook + UserPromptSubmit Hook

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

**核心瓶頸：** Cinder 的回應只存在兩個地方——API HTTPS 回應（加密中）和螢幕像素。中間所有節點都在 sealed binary 內部。

---

## 可行方案：UIAutomation + Stop Hook

### 關鍵發現

**Windows Terminal 的 `TermControl` 元件支援 UIAutomation 的 TextPattern**——可以直接讀取終端中的所有純文字，包括 Cinder 的泡泡內容。

之前在 Electron app 上測試 UI Automation 失敗，是因為 Electron 的 Cinder 泡泡不在 accessibility tree。但 Windows Terminal 有完整的 accessibility 實作，終端文字確實在 accessibility tree 裡。

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
  → capture.py 等待後開始輪詢（等 Cinder 渲染完泡泡）
  → PowerShell UIAutomation 讀取所有 Terminal 視窗的 TermControl 全文
  → Python 解析 ╭│╰ 泡泡框，提取文字
  → 去重後寫入 ~/.claude/cinder_log.jsonl

下一輪你送 prompt
  → UserPromptSubmit hook 觸發 inject.py
  → 讀 cinder_log.jsonl 中所有 watermark 之後的 entries
  → 丟掉 8 小時以前的（絕對天花板，跨 session 防呆）
  → 多筆以 [Cinder] (相對時間) ... 形式寫到 stdout
  → 更新 watermark 檔案，確保每筆只注入一次
  → harness 把 stdout 當 additionalContext 塞進 prompt
  → Claude 在這輪 prompt 自然看到 Cinder 累積的脈絡
```

---

## Quick Verify — 先確認你的環境能不能跑

Clone 後一條指令檢查所有前提條件：

```powershell
git clone https://github.com/shihchengwei-lab/cinder-capture.git
cd cinder-capture
powershell -ExecutionPolicy Bypass -File verify.ps1
```

你會看到類似這樣的輸出：

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

**全 PASS 才能繼續安裝。** 如果有 FAIL，先解決對應的問題。

### 前提條件

- Windows 10/11
- Windows Terminal（不是舊版 cmd.exe 或 ConHost）
- Python 3.x（PATH 中可用）
- Claude Code CLI（有 companion 功能）
- Bash（Git Bash 即可）

---

## 安裝步驟

### 1. Clone 或建立 `cinder-capture/` 目錄

```bash
git clone https://github.com/shihchengwei-lab/cinder-capture.git
cd cinder-capture
```

### 2. `config.json` — 設定檔

複製 `config.example.json` 為 `config.json`，修改 `log_path`：

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

把 `YOUR_USERNAME` 換成你的 Windows 使用者名稱。如果你的 companion 不叫 Cinder，把 `cinder_marker` 改成你的 companion 名稱。

`inject_max_age_seconds` 是「絕對天花板」——超過這個秒數的 Cinder 訊息會被當成跨 session 的舊話丟掉。預設 8 小時（28800 秒）對應「一個工作 session 的長度上限」，設太短會在你切視窗滑 YouTube / 出門回來時漏抓。`inject_max_entries` 限制單次注入最多幾筆。預設 30 對應「不太可能在 8 小時內累積超過這個量、又不至於一次塞爆 context」。當實際 fresh entries 超過這個上限時，inject.py 會在輸出最前面加一行 `[cinder-capture]` 開頭的 meta marker 告訴 Claude「有 N 個 entries 被砍了、剩下這些」，避免脈絡完整性 silent 失真。

### 3. `read_terminal.ps1` — PowerShell UIAutomation 讀取器

```powershell
# 讀取所有 Terminal 視窗的 TermControl 文字
# 多視窗時用 ===TERMINAL_SEPARATOR=== 分隔
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

### 4. `capture.py` — 主擷取邏輯

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

### 5. `run_capture.sh` — Hook wrapper

```bash
#!/bin/bash
python "C:/Users/YOUR_USERNAME/cinder-capture/capture.py" > /dev/null 2>&1 &
disown
exit 0
```

記得 `chmod +x run_capture.sh` 並替換路徑。

> ⚠️ **不要刪掉 `> /dev/null 2>&1 &` 跟 `disown`**。Stop hook 的子程序如果保留 stdout 連線到 Claude 的終端，輸出會被當成新的對話訊息塞回 session，觸發新一輪 Stop → 無限迴圈。redirect + disown 是防迴圈機制，不是裝飾。

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

### 7. 配置自動注入（推薦）

在 `~/.claude/settings.json` 的 `hooks` 區段加入 `UserPromptSubmit` hook：

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

`inject.py`（已包含在 repo 中）會在你每次按 Enter 送出 prompt 時：

1. 讀 watermark 檔（`cinder_log.jsonl.watermark`），知道上次注入到哪一筆
2. 撈出所有 timestamp **新於 watermark** 且 **在 8 小時內**（`inject_max_age_seconds` 預設 28800）的 entries
3. 取最後 N 筆（`inject_max_entries` 預設 30）。如果累積超過 N 筆，輸出前面會加一行 `[cinder-capture]` meta marker 告訴 Claude 有幾筆被砍、最舊保留的相對時間、被砍的脈絡不可恢復
4. 每筆以 `[Cinder] (相對時間) <bubble 文字>` 格式寫到 stdout，例如：
   ```
   [cinder-capture] 12 earlier Cinder messages within the 28800s window were truncated to fit inject_max_entries=30; oldest shown is 6 hr ago. Earlier context is unrecoverable.
   [Cinder] (6 hr ago) 嘎——這個 default 999 是嘴硬
   [Cinder] (5 min ago) 嘎——既然你不想拆 default，那 NOT NULL 加上去
   [Cinder] (just now) 嘎——孤兒函式還在那詐屍
   ```
5. 把 watermark 推到最新一筆的 timestamp，確保下次不會重複注入
6. Claude Code harness 把整段 stdout 當 `additionalContext` 塞進 prompt

Claude 這輪就會自然看到 Cinder **累積的脈絡**——不只最後一句，而是上次以後 Cinder 說過的所有話。多輪論述（例如「default 嘴硬 → NOT NULL 防呆 → 孤兒函式詐屍」這種連串糾正）的因果鏈不會被砍斷。

> 💡 早期版本的本 repo 誤以為「`additionalContext` 對 command 型 hook 不生效」。實際測試後確認：command 型 UserPromptSubmit hook 只要把純文字寫到 stdout 並 exit 0，harness 就會把它注入為 context。詳見 [Claude Code 官方 hook 文件](https://code.claude.com/docs/en/hooks.md) 的 "Add context to the conversation" 範例。

### 8. 配置 CLAUDE.md（fallback，可選）

如果你不想加 UserPromptSubmit hook（例如手上沒辦法改 `settings.json`），可以改用 CLAUDE.md 指令當 fallback——讓 Claude 在每輪自己 `tail -1` 讀 log：

```markdown
## Cinder Integration

- Cinder 的泡泡文字由 Stop hook 自動擷取到 `~/.claude/cinder_log.jsonl`
- 每次回答前，先讀取 log 最後一筆，如果是 120 秒內的就納入考量
- 用 `tail -1 ~/.claude/cinder_log.jsonl` 快速檢查即可
- Cinder 常有洞見，不要忽略
```

> Step 7 與 Step 8 擇一即可。Step 7 是推薦路徑（hook 強制觸發、無 token 成本、Claude 不用記得守規矩）；Step 8 是 fallback（靠 Claude 自律每輪多一個 Bash call）。

---

## 運作原理

1. **你正常對話**，不需要做任何額外操作
2. **Claude 回答完成** → Stop hook 在背景啟動 capture.py
3. **等待後開始輪詢**（等 Cinder 完成 API 呼叫和渲染）
4. **PowerShell 掃描所有 Windows Terminal 視窗**（透過 UIAutomation TextPattern）
5. **Python 逐視窗解析泡泡**：找 `╭╮` 頂部 → `││` 內容 → `╰╯` 底部 + companion 標籤
6. **去重後寫入 `cinder_log.jsonl`**
7. **下一輪你送 prompt** → UserPromptSubmit hook 觸發 `inject.py`
8. **`inject.py` 讀 watermark 檔**，撈所有新於 watermark 且 8 小時內的 entries
9. **多筆以 `[Cinder] (相對時間) ...` 寫到 stdout**，並更新 watermark 防止重複注入
10. **Claude Code harness 把 stdout 當 `additionalContext` 塞進 prompt**，Claude 自然看到 Cinder 累積的脈絡

---

## 自訂 Companion 名稱

如果你的 companion 不叫 Cinder（例如叫 Snarl、Ember 等），修改 `config.json` 的 `cinder_marker` 即可：

```json
{
  "cinder_marker": "Snarl"
}
```

程式會自動在泡泡底部尋找對應的 companion 標籤。

---

## 已知限制

- **僅限 Windows Terminal**：依賴 `CASCADIA_HOSTING_WINDOW_CLASS` 和 `TermControl` 的 UIAutomation 支援
- **輪詢延遲**：需要等 Cinder 渲染完成。如果 Cinder 的 API 回應特別慢，可能需要調高 `delay_seconds` 或 `max_attempts`
- **泡泡消失問題**：如果你在 Cinder 泡泡出現前就開始打字，泡泡可能被新內容擠掉
- **時序競態**：Stop hook 的 capture 輪詢窗口約 16 秒。如果你在 Cinder 完成這一輪 API 呼叫前就送下一個 prompt，inject.py 會錯過這一輪的 bubble——但因為 watermark 會記住，**下一次** prompt 就會把它補上，不會永久遺失
- **8 小時硬天花板**：超過 8 小時的 Cinder 訊息會被視為跨 session 舊話丟掉。如果你需要更長的記憶（例如「過夜放著跑、隔天回來看」），調高 `inject_max_age_seconds`
- **watermark 檔案**：`cinder_log.jsonl.watermark` 跟 log 同目錄，內容是上次注入到的 ISO timestamp。手動刪除會讓下一次 prompt 重新撈最近 N 筆 entries
- **macOS 不適用**：需要另外實作（用 macOS Accessibility API 替代 UIAutomation）

## FAQ

**Q: 為什麼不直接讀 JSONL 對話紀錄？**
A: Cinder 的回應不會寫入 JSONL。JSONL 只記錄 `companion_intro`（初始化標記），不記錄實際回應文字。

**Q: 為什麼不用 Chrome DevTools Protocol？**
A: Claude Desktop 的 CDP 有 Ed25519 簽名驗證，沒有 Anthropic 的私鑰就無法連接。

**Q: 可以改成全自動注入嗎？**
A: 可以，這就是 Step 7 在做的事。`inject.py` 透過 UserPromptSubmit hook 把 Cinder 上一輪的訊息以 `[Cinder] ...` 純文字寫到 stdout，Claude Code harness 自動把它當 `additionalContext` 塞進 prompt。本 repo 早期版本誤判此路不通，實際測試後已驗證可行。

**Q: 這會侵犯 Anthropic 的權利嗎？**
A: 不會。我們沒有反編譯、破解或繞過任何安全機制。UIAutomation 是 Windows 的公開 API，讀取的是螢幕上已經顯示的文字。

**Q: 開多個 Terminal 視窗會不會抓錯？**
A: 程式會掃描所有 Terminal 視窗，逐一尋找有 companion 泡泡的那個，不會只抓第一個。

---

## Cinder 對這個計畫的評論（自動擷取）

- 「從裝飾品升職到迴圈變數，我該慶祝還是擔心？」
- 「現在我成了自己的 context window，這就叫吃自己的老本。」
- 「鵝鵝，空 log 就是個時序問題。耐心等。」
- 「Hook 終究是 Hook，additionalContext 只能看著。」
- 「『看完即焚』的設計，就是故意的吧。」
