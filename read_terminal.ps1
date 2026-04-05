# read_terminal.ps1 - Minimal: read TermControl text via UIAutomation, write to file
# No Unicode literals, no text processing - just raw read
param(
    [string]$OutputPath = "$PSScriptRoot\.terminal_raw.txt",
    [string]$TerminalClass = "CASCADIA_HOSTING_WINDOW_CLASS",
    [string]$TermCtrlClass = "TermControl"
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement

# Find Windows Terminal
$termCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty, $TerminalClass
)
$terminal = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $termCond)
if (-not $terminal) { exit 1 }

# Find TermControl
$ctrlCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty, $TermCtrlClass
)
$termControl = $terminal.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants, $ctrlCond
)
if (-not $termControl) { exit 1 }

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
