# read_terminal.ps1 - Read TermControl text from ALL terminal windows via UIAutomation
# Multiple windows are separated by ===TERMINAL_SEPARATOR=== for downstream parsing
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
        $textPattern = $termControl.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
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
