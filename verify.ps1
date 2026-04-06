# verify.ps1 - Quick environment check for cinder-capture
# Usage: powershell -ExecutionPolicy Bypass -File verify.ps1

$pass = 0
$fail = 0
$warn = 0

function Test-Check($name, $result, $detail) {
    if ($result) {
        Write-Host "  [PASS] $name" -ForegroundColor Green
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
        $script:pass++
    } else {
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
        $script:fail++
    }
}

function Test-Warn($name, $detail) {
    Write-Host "  [WARN] $name" -ForegroundColor Yellow
    if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
    $script:warn++
}

Write-Host ""
Write-Host "=== cinder-capture environment check ===" -ForegroundColor Cyan
Write-Host ""

# 1. OS
$os = [System.Environment]::OSVersion
$isWin = $os.Platform -eq "Win32NT"
Test-Check "Windows OS" $isWin "$os"

# 2. Python
$py = $null
try { $py = & python --version 2>&1 } catch {}
$hasPy = $py -match "Python 3\."
Test-Check "Python 3.x" $hasPy "$py"

# 3. Pillow (optional but useful)
if ($hasPy) {
    $pil = $null
    try { $pil = & python -c "import PIL; print(PIL.__version__)" 2>&1 } catch {}
    if ($pil -match "^\d+\.") {
        Write-Host "  [PASS] Pillow $pil (optional, for fallback OCR)" -ForegroundColor Green
        $pass++
    } else {
        Test-Warn "Pillow not installed" "Optional - only needed for screenshot OCR fallback"
    }
}

# 4. PowerShell UIAutomation assemblies
$uiaOk = $false
try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $uiaOk = $true
} catch {}
Test-Check "UIAutomation assemblies" $uiaOk "UIAutomationClient + UIAutomationTypes"

# 5. Windows Terminal running
$termFound = $false
$termName = ""
if ($uiaOk) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty,
        "CASCADIA_HOSTING_WINDOW_CLASS"
    )
    $terminal = $root.FindFirst(
        [System.Windows.Automation.TreeScope]::Children, $cond
    )
    if ($terminal) {
        $termFound = $true
        $termName = $terminal.Current.Name
    }
}
Test-Check "Windows Terminal running" $termFound $termName

# 6. TermControl with TextPattern
$textPatternOk = $false
$textLen = 0
if ($termFound) {
    $ctrlCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty, "TermControl"
    )
    $termCtrl = $terminal.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants, $ctrlCond
    )
    if ($termCtrl) {
        try {
            $tp = $termCtrl.GetCurrentPattern(
                [System.Windows.Automation.TextPattern]::Pattern
            )
            $sample = $tp.DocumentRange.GetText(100)
            if ($sample.Length -gt 0) {
                $textPatternOk = $true
                $fullText = $tp.DocumentRange.GetText(-1)
                $textLen = $fullText.Length
            }
        } catch {}
    }
}
Test-Check "TermControl TextPattern readable" $textPatternOk "$textLen chars in buffer"

# 7. Cinder companion active
$cinderFound = $false
if ($textPatternOk) {
    $hasBubbleChars = ($fullText.Contains([char]0x256D)) -and ($fullText.Contains([char]0x2570))
    $hasCinderLabel = $fullText.Contains("Cinder")
    if ($hasCinderLabel) {
        $cinderFound = $true
        if ($hasBubbleChars) {
            Test-Check "Cinder companion detected" $true "Label + bubble border found"
        } else {
            Test-Check "Cinder companion detected" $true "Label found (no active bubble right now)"
        }
    } else {
        Test-Warn "Cinder not detected" "Is Claude Code running in this terminal with a companion enabled?"
    }
}
if (-not $cinderFound -and $textPatternOk) {
    Test-Warn "Cinder not detected" "Make sure Claude Code is running with companion enabled"
}

# 8. Claude Code CLI
$claude = $null
try { $claude = & claude --version 2>&1 } catch {}
$hasClaude = $claude -match "\d+\.\d+\.\d+"
if ($hasClaude) {
    Test-Check "Claude Code CLI" $true "$claude"
} else {
    Test-Warn "Claude Code CLI not found in PATH" "Not required for verify, but needed for hooks"
}

# 9. Git Bash (for hook wrapper)
$bash = $null
try { $bash = & bash --version 2>&1 | Select-Object -First 1 } catch {}
$hasBash = $bash -match "bash"
Test-Check "Bash available" $hasBash "$bash"

# =================================================================
# inject.py auto-injection chain
# =================================================================
# Each step depends on the previous; first FAIL skips the rest of
# the chain so the failure point is unmistakable.
Write-Host ""
Write-Host "=== inject.py auto-injection check ===" -ForegroundColor Cyan
Write-Host ""

$injectChainBroken = $false
$injectPath = Join-Path $PSScriptRoot "inject.py"
$configPath = Join-Path $PSScriptRoot "config.json"

# I1: inject.py exists
$injectExists = Test-Path $injectPath
Test-Check "inject.py present" $injectExists $injectPath
if (-not $injectExists) { $injectChainBroken = $true }

# I2: config.json log_path resolved
$logPath = $null
if (-not $injectChainBroken) {
    if (Test-Path $configPath) {
        try {
            $configRaw = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
            $config = $configRaw | ConvertFrom-Json
            $logPath = $config.log_path
        } catch {}
    }
    if ($logPath) {
        Test-Check "config.json log_path resolved" $true $logPath
    } else {
        Test-Check "config.json log_path resolved" $false "Copy config.example.json to config.json and set log_path"
        $injectChainBroken = $true
    }
}

# Helper: run inject.py and capture stdout/stderr/exit cleanly
function Invoke-Inject {
    param([string]$ScriptPath)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "python"
    $psi.Arguments = "`"$ScriptPath`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $stdoutText = $p.StandardOutput.ReadToEnd()
    $stderrText = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [PSCustomObject]@{
        Stdout = $stdoutText
        Stderr = $stderrText
        ExitCode = $p.ExitCode
    }
}

# I3: inject.py runs cleanly (no traceback, exit 0)
if (-not $injectChainBroken) {
    $r = $null
    try { $r = Invoke-Inject $injectPath } catch {}
    if ($r -and $r.ExitCode -eq 0 -and -not ($r.Stderr -match "Traceback")) {
        Test-Check "inject.py runs cleanly" $true "exit 0"
    } else {
        $detail = if ($r) { "exit $($r.ExitCode); stderr: $($r.Stderr.Trim())" } else { "failed to launch python" }
        Test-Check "inject.py runs cleanly" $false $detail
        $injectChainBroken = $true
    }
}

# I4: end-to-end sentinel test (write sentinel to log -> inject.py -> verify output)
# Uses try/finally to truncate the log back to its original size, leaving no trace.
if (-not $injectChainBroken) {
    $logSizeBefore = if (Test-Path $logPath) { (Get-Item $logPath).Length } else { 0 }
    $logExistedBefore = Test-Path $logPath

    $sentinelTs = (Get-Date).ToUniversalTime()
    # Build the Chinese verification suffix from UTF-8 bytes so this .ps1 file
    # stays pure ASCII (PowerShell 5.1 on a CP950 console mis-reads non-ASCII
    # bytes in source files and breaks the parser).
    $cnBytes = [byte[]] @(
        0xe7,0xb4,0xab, 0xe8,0x89,0xb2, 0xe7,0xab,0xa0,
        0xe9,0xad,0x9a, 0xe5,0x9c,0xa8, 0xe8,0xb7,0xb3, 0xe8,0x88,0x9e
    )
    $cnSuffix = [System.Text.Encoding]::UTF8.GetString($cnBytes)
    $sentinel = "VERIFY_" + [int][double]::Parse((Get-Date -UFormat %s)) + "_" + $cnSuffix
    $entry = [PSCustomObject]@{
        timestamp = $sentinelTs.ToString("o")
        text = $sentinel
        source = "verify.ps1"
    } | ConvertTo-Json -Compress

    # Ensure log dir exists
    $logDir = Split-Path $logPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $sentinelOk = $false
    $sentinelDetail = ""
    try {
        [System.IO.File]::AppendAllText($logPath, $entry + "`n", [System.Text.Encoding]::UTF8)
        $r2 = Invoke-Inject $injectPath
        $expected = "[Cinder] $sentinel"
        if ($r2.Stdout.Contains($expected)) {
            $sentinelOk = $true
            $sentinelDetail = "[Cinder] prefix + UTF-8 sentinel matched"
        } else {
            $preview = $r2.Stdout.Trim()
            if ($preview.Length -gt 80) { $preview = $preview.Substring(0, 80) + "..." }
            $sentinelDetail = "expected '$expected', got: '$preview'"
        }
    } catch {
        $sentinelDetail = "exception: $_"
    } finally {
        # Roll back the log to its previous state, byte-perfect
        if ($logExistedBefore) {
            try {
                $fs = [System.IO.File]::OpenWrite($logPath)
                $fs.SetLength($logSizeBefore)
                $fs.Close()
            } catch {}
        } else {
            try { Remove-Item $logPath -ErrorAction SilentlyContinue } catch {}
        }
    }

    Test-Check "inject.py output (wire + UTF-8)" $sentinelOk $sentinelDetail
    if (-not $sentinelOk) { $injectChainBroken = $true }
}

# I5: UserPromptSubmit hook configured in global settings.json
$globalSettings = Join-Path $env:USERPROFILE ".claude\settings.json"
$hookFound = $false
$hookDetail = ""
if (Test-Path $globalSettings) {
    try {
        $settingsRaw = [System.IO.File]::ReadAllText($globalSettings, [System.Text.Encoding]::UTF8)
        $settings = $settingsRaw | ConvertFrom-Json
        if ($settings.hooks -and $settings.hooks.UserPromptSubmit) {
            foreach ($group in @($settings.hooks.UserPromptSubmit)) {
                foreach ($h in @($group.hooks)) {
                    if ($h.type -eq "command" -and $h.command -match "inject\.py") {
                        $hookFound = $true
                        $hookDetail = $h.command
                        break
                    }
                }
                if ($hookFound) { break }
            }
        }
        if (-not $hookFound) {
            $hookDetail = "Add UserPromptSubmit hook in $globalSettings (see README Step 7)"
        }
    } catch {
        $hookDetail = "could not parse $globalSettings : $_"
    }
} else {
    $hookDetail = "$globalSettings not found"
}
Test-Check "UserPromptSubmit hook in global settings.json" $hookFound $hookDetail
if (-not $hookFound) { $injectChainBroken = $true }

if ($injectChainBroken) {
    Write-Host ""
    Write-Host "  STOP: Auto-injection chain is broken." -ForegroundColor Red
    Write-Host "  Fix the FAIL above before relying on inject.py. Until then, Cinder's" -ForegroundColor Red
    Write-Host "  output is invisible to Claude no matter how often the bubble appears." -ForegroundColor Red
}

# Summary
Write-Host ""
Write-Host "=== Result ===" -ForegroundColor Cyan
Write-Host "  $pass passed, $fail failed, $warn warnings" -ForegroundColor White
Write-Host ""

if ($fail -eq 0) {
    Write-Host "  Ready to use cinder-capture!" -ForegroundColor Green
    Write-Host "  Copy config.example.json to config.json, update paths, and configure hooks." -ForegroundColor DarkGray
} else {
    Write-Host "  Some requirements are missing. Check the FAIL items above." -ForegroundColor Red
}

Write-Host ""
