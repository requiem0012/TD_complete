# Build the native multimedia player only. Never programs the FPGA or a physical disk.
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskPrj = Join-Path $taskRoot 'prj'
$taskTd = 'C:\Anlogic\TD_Release_2026.2.210.850\bin\td_commands_prompt.exe'
$taskStarted = Get-Date
$taskPhy = Join-Path $taskPrj 'tf_hdmi_display_Runs\phy_1'
$taskSyn = Join-Path $taskPrj 'tf_hdmi_display_Runs\syn_1'
function Invoke-Td($directory, $script, $log) {
    Push-Location -LiteralPath $directory
    try { & $taskTd $script *> $log } finally { Pop-Location }
}
function Fresh-File($path) {
    (Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).LastWriteTime -ge $taskStarted)
}
Invoke-Td $taskPrj './run_synth.tcl' (Join-Path $taskPrj 'native_build.log')
$taskGate = Join-Path $taskSyn 'tf_hdmi_display_gate.db'
if (-not (Fresh-File $taskGate)) {
    Invoke-Td $taskSyn '../../run_syn_direct.tcl' (Join-Path $taskPrj 'native_direct_syn.log')
    if (-not (Fresh-File $taskGate)) { throw 'No fresh synthesis database. Refusing stale output.' }
}
$taskBit = Join-Path $taskPhy 'tf_hdmi_display.bit'
$taskTiming = Join-Path $taskPhy 'final_timing.rpt'
if (-not (Fresh-File $taskBit) -or -not (Fresh-File $taskTiming)) {
    Invoke-Td $taskPhy '../../run_phy_direct.tcl' (Join-Path $taskPrj 'native_direct.log')
}
if (-not (Fresh-File $taskBit) -or -not (Fresh-File $taskTiming)) { throw 'No fresh implementation bit/timing.' }
$taskReport = Get-Content -LiteralPath $taskTiming -Raw
$taskSetup = [regex]::Match($taskReport, 'SWNS:\s*([-\d.]+)ns')
$taskHold = [regex]::Match($taskReport, 'HWNS:\s*([-\d.]+)ns')
if (-not $taskSetup.Success -or -not $taskHold.Success) { throw 'Timing summary not found.' }
$taskSetupNs = [double]::Parse($taskSetup.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
$taskHoldNs = [double]::Parse($taskHold.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
if (($taskSetupNs -lt 0) -or ($taskHoldNs -lt 0)) { throw "Timing failed: setup=$taskSetupNs hold=$taskHoldNs" }
$taskRelease = Join-Path $taskPrj 'TD_complete.bit'
Copy-Item -LiteralPath $taskBit -Destination $taskRelease
Write-Output "PASS fresh native multimedia player build: setup=$taskSetupNs ns, hold=$taskHoldNs ns"
Get-FileHash -LiteralPath $taskRelease -Algorithm SHA256
