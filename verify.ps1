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
