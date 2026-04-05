# read_terminal.ps1 - Minimal: read TermControl text via UIAutomation, write to file
# No Unicode literals, no text processing - just raw read
param(
    [string]$OutputPath = "$PSScriptRoot\.terminal_raw.txt",
    [string]$TerminalClass = "CASCADIA_HOSTING_WINDOW_CLASS",
    [string]$TermCtrlClass = "TermControl",
    [int]$TerminalPid = 0
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement

# Find Windows Terminal — by PID if provided, fallback to class name
$terminal = $null
if ($TerminalPid -gt 0) {
    $pidCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $TerminalPid
    )
    $terminal = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $pidCond)
}
if (-not $terminal) {
    $termCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty, $TerminalClass
    )
    $terminal = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $termCond)
}
if (-not $terminal) { exit 1 }

# Find TermControl — pick the active tab (not offscreen)
$ctrlCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty, $TermCtrlClass
)
$allControls = $terminal.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants, $ctrlCond
)
if ($allControls.Count -eq 0) { exit 1 }

$termControl = $null
foreach ($ctrl in $allControls) {
    if (-not $ctrl.Current.IsOffscreen) {
        $termControl = $ctrl
        break
    }
}
if (-not $termControl) { $termControl = $allControls[0] }

# Read text
try {
    $textPattern = $termControl.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    $fullText = $textPattern.DocumentRange.GetText(-1)
} catch {
    exit 1
}

if (-not $fullText) { exit 1 }

# Write UTF-8 to file
[System.IO.File]::WriteAllText($OutputPath, $fullText, [System.Text.Encoding]::UTF8)
exit 0
