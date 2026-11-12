param([switch]$Live)
$ErrorActionPreference='Stop'
$null=New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot 'data')
. (Join-Path $PSScriptRoot 'AgentProcesses.ps1')
function Fake-Process($name,$path,$handle,$id) {
 [pscustomobject]@{ProcessName=$name;Path=$path;MainWindowHandle=[intptr]$handle;Id=$id;WorkingSet64=1024}
}
$desktop=Fake-Process 'ChatGPT' 'C:\Program Files\WindowsApps\OpenAI.Codex_1\app\ChatGPT.exe' 100 1
$backend=Fake-Process 'codex' 'C:\Program Files\WindowsApps\OpenAI.Codex_1\app\resources\codex.exe' 0 2
$harness=Fake-Process 'DeepSeek Harness' 'D:\DeepSeek Harness\DeepSeek Harness.exe' 200 3
$helper=Fake-Process 'DeepSeek Harness' 'D:\DeepSeek Harness\DeepSeek Harness.exe' 0 4
# Codex installs a always-on Windows service; it must never imply an open app.
$service=Fake-Process 'codex-windows-sandbox-service' 'C:\Program Files\WindowsApps\OpenAI.Codex_1\app\codex-windows-sandbox-service.exe' 0 5
$doubao=Fake-Process 'Doubao' 'D:\Doubao\Doubao.exe' 300 6
$doubaoHelper=Fake-Process 'Doubao' 'D:\Doubao\Doubao.exe' 0 7
$workbuddy=Fake-Process 'WorkBuddy' 'D:\WorkBuddy\WorkBuddy.exe' 400 8
$workbuddyHelper=Fake-Process 'WorkBuddy' 'D:\WorkBuddy\WorkBuddy.exe' 0 9
if (!(Test-IslandProviderProcess '豆包' $doubao)) { throw 'Doubao desktop missing' }
if (Test-IslandProviderProcess '豆包' $doubaoHelper) { throw 'Doubao background helper must not imply an open application' }
if (!(Test-IslandProviderProcess 'WorkBuddy' $workbuddy)) { throw 'WorkBuddy desktop missing' }
if (Test-IslandProviderProcess 'WorkBuddy' $workbuddyHelper) { throw 'WorkBuddy renderer/daemon helper must not imply an open application' }
if (!(Test-IslandProviderProcess 'Codex' $desktop)) { throw 'Codex desktop missing' }
if (Test-IslandProviderProcess 'Codex' $backend) { throw 'Codex backend must not imply an open application' }
if (Test-IslandProviderProcess 'Codex' $service) { throw 'Codex background service must not imply an open application' }
if (!(Test-IslandProviderProcess 'DeepSeek Harness' $harness)) { throw 'Harness desktop missing' }
if (Test-IslandProviderProcess 'DeepSeek Harness' $helper) { throw 'Harness helper must not imply an open application' }
$body=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Collector.ps1'))
$worker=[PowerShell]::Create()
try {
 foreach ($case in @(
  @{Snapshot=@($desktop,$harness,$backend,$helper,$service);Expected=2;Visible=2},
  @{Snapshot=@($desktop,$harness,$backend,$helper);Expected=2;Visible=2},
  @{Snapshot=@($harness,$backend);Expected=1;Visible=1},
  @{Snapshot=@($backend,$helper);Expected=1;Visible=0;Tray=$true}
  @{Snapshot=@($doubao,$doubaoHelper);Expected=1;Visible=1}
  @{Snapshot=@($doubaoHelper);Expected=1;Visible=0;Tray=$true}
  @{Snapshot=@($workbuddy,$workbuddyHelper);Expected=1;Visible=1}
  @{Snapshot=@($workbuddyHelper);Expected=1;Visible=0;Tray=$true}
  @{Snapshot=@($desktop,$harness,$workbuddy,$backend,$helper,$service,$workbuddyHelper);Expected=3;Visible=3}
 )) {
  $worker.Commands.Clear()
  $null=$worker.AddScript('param($snapshot); $script:allProcesses=$snapshot; $script:hostedProcesses=@([pscustomobject]@{CommandLine="python AgentTelemetry.py --watch-fast";ProcessId=999}); $script:inventoryAt=[datetime]::Now').AddArgument($case.Snapshot)
  $null=$worker.Invoke()
  $worker.Commands.Clear()
  $null=$worker.AddScript($body).AddArgument((Join-Path $PSScriptRoot 'data')).AddArgument($PSScriptRoot)
  $result=@($worker.Invoke()) | Select-Object -Last 1
  if (@($result.Agents).Count -ne $case.Expected) { throw "Repeated scan/close failed: expected $($case.Expected), got $(@($result.Agents).Count)" }
  if (@($result.Agents | Group-Object Name | Where-Object Count -gt 1).Count) { throw 'Duplicate agent rows' }
  if ($case.Tray -and @($result.Agents | Where-Object WindowState -ne 'background').Count) { throw 'Tray-only app must be marked background' }
  # The collector also reads the real local session log. Neutralise its state so
  # this assertion tests only the window rule, not whatever app is running now.
  foreach ($a in $result.Agents) { $a.State='online'; $a.Sessions=@() }
  if (@(Select-IslandVisibleAgents $result.Agents).Count -ne $case.Visible) { throw ('Background visibility projection disagrees: expected '+$case.Visible+', got '+@(Select-IslandVisibleAgents $result.Agents).Count+' rows [ '+(($result.Agents | ForEach-Object { $_.Name+'/'+$_.State+'/'+$_.WindowState }) -join ', ')+' ]') }
 }
 # A minimized/tray app stays off the island while idle, but a live thinking or
 # tool state (including a session-level one) keeps it visible.
 $idle=[pscustomobject]@{Name='WorkBuddy';State='complete';WindowState='background'}
 $busy=[pscustomobject]@{Name='豆包';State='thinking';WindowState='background'}
 $sessionBusy=[pscustomobject]@{Name='DeepSeek Harness';State='online';WindowState='background';Sessions=@([pscustomobject]@{State='tool'})}
 $front=[pscustomobject]@{Name='WorkBuddy';State='complete';WindowState='foreground'}
 $cli=[pscustomobject]@{Name='Claude';State='complete'}
 if (@(Select-IslandVisibleAgents @($idle,$busy,$sessionBusy,$front,$cli)).Count -ne 4) { throw 'Busy background app must keep its island status' }
 if (@(Select-IslandVisibleAgents @($idle)).Count) { throw 'Idle background app must be hidden' }
 if ((Get-IslandProviderWindowState 'WorkBuddy' @()) -ne 'absent') { throw 'No process must read as absent' }
 if ((Get-IslandProviderWindowState 'WorkBuddy' @($workbuddy)) -ne 'foreground') { throw 'Visible window must read as foreground' }
 if ((Get-IslandProviderWindowState 'WorkBuddy' @($workbuddyHelper)) -ne 'background') { throw 'Tray helper must read as background' }
 # A real Win32 window that exists but is hidden (the tray-hide path) must not
 # count as a foreground window. No window is ever shown to the user here.
 Add-Type -AssemblyName System.Windows.Forms
 $probeForm=New-Object Windows.Forms.Form
 try {
  $probeForm.Text='island-window-probe'
  $hidden=[pscustomobject]@{ProcessName='WorkBuddy';MainWindowHandle=$probeForm.Handle}
  if (Test-IslandProviderForeground 'WorkBuddy' $hidden) { throw 'Hidden window must not read as foreground' }
  if ((Get-IslandProviderWindowState 'WorkBuddy' @($hidden)) -ne 'background') { throw 'Hidden window must read as background' }
 } finally { $probeForm.Dispose() }
# Doubao hides its real main window in the tray but leaves a 52x52 always-on
# widget visible; Windows then reports that widget as MainWindowHandle. Only
# enumerating all top-level windows can tell the two apart, otherwise the app
# stays "foreground" forever and a finished background task never animates
# back to today's todos.
if ([IslandWindowNative]::IsRealMainWindow($true,$false,$true,52,52,$false)) { throw 'Doubao tray widget must not count as a main window' }
if ([IslandWindowNative]::IsRealMainWindow($true,$false,$false,52,52,$false)) { throw 'Tiny visible helper must not count as a main window' }
if ([IslandWindowNative]::IsRealMainWindow($false,$false,$false,1115,747,$false)) { throw 'Hidden main window must not count as foreground' }
if ([IslandWindowNative]::IsRealMainWindow($true,$true,$false,1115,747,$false)) { throw 'Minimized main window must not count as foreground' }
if ([IslandWindowNative]::IsRealMainWindow($true,$false,$false,1115,747,$true)) { throw 'Cloaked main window must not count as foreground' }
if (![IslandWindowNative]::IsRealMainWindow($true,$false,$false,1115,747,$false)) { throw 'Visible main window must count as foreground' }
$self=[Diagnostics.Process]::GetCurrentProcess()
try { if (Test-IslandProviderForeground '豆包' $self) { throw 'Headless real process must not read as foreground' } }
finally { $self.Dispose() }
# Recent session events prove a tray/minimized app is still alive even when its
 # process name is not one of the known desktop executables (Doubao helpers).
 $nowUnix=[datetimeoffset]::Now.ToUnixTimeSeconds()
 $staleEvents=@([pscustomobject]@{State='complete';Time=$nowUnix-3600})
 $freshEvents=@($staleEvents+@([pscustomobject]@{State='thinking';Time=$nowUnix}))
 if (Test-IslandRecentTelemetry $null) { throw 'Empty telemetry must not keep an app alive' }
 if (Test-IslandRecentTelemetry $staleEvents) { throw 'Stale events must not keep an app alive' }
 if (!(Test-IslandRecentTelemetry $freshEvents)) { throw 'Fresh events must keep a tray app alive' }
 if (Test-IslandRecentTelemetry @([pscustomobject]@{State='thinking'})) { throw 'Events without a timestamp must not keep an app alive' }
 if (Test-IslandRecentTelemetry @([pscustomobject]@{State='complete';Time=$nowUnix-30}) 10) { throw 'Custom activity window must be respected' }
 'PASS: desktop recognition, tray background rows, repeated scans, unique providers, visibility projection, log liveness'
} finally { $worker.Dispose() }
# Harness stores sessions as .zstd. A Python without compression.zstd silently
# drops every Harness session, which leaves that brand without state animations.
$telemetryPython=Get-IslandTelemetryPython
if (!$telemetryPython) { throw 'No Python interpreter found for the telemetry adapter' }
if (@(Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.dsh\sessions') -Filter '*.zstd' -Recurse -File -ErrorAction SilentlyContinue).Count -and !(Test-IslandPythonZstd $telemetryPython)) {
 throw 'Telemetry Python cannot decode Harness zstd logs'
}
if ($Live) {
 $worker=[PowerShell]::Create()
 try {
  foreach ($attempt in 1..3) {
   $worker.Commands.Clear()
   $null=$worker.AddScript($body).AddArgument((Join-Path $PSScriptRoot 'data')).AddArgument($PSScriptRoot)
   $result=@($worker.Invoke()) | Select-Object -Last 1
   if (@($result.Agents | Group-Object Name | Where-Object Count -gt 1).Count) { throw 'Live duplicate agent rows' }
   [pscustomobject]@{Scan=$attempt;Agents=@($result.Agents | ForEach-Object Name);Windows=@($result.Agents | ForEach-Object { $_.Name+'='+$_.WindowState });States=@($result.Agents | ForEach-Object { $_.Name+'='+$_.State });Sources=@($result.Agents | ForEach-Object { $_.Name+'='+([string]$_.Source).Substring(0,[Math]::Min(90,([string]$_.Source).Length)) })} | ConvertTo-Json -Compress
  }
 } finally { $worker.Dispose() }
}
