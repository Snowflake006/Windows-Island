if (!('IslandWindowNative' -as [type])) {
 Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class IslandWindowNative {
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
 public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
 [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);
 [DllImport("user32.dll", EntryPoint="GetWindowLongW")] private static extern int GetWindowLong32(IntPtr hWnd, int index);
 [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out int value, int size);
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
 private static long WindowExStyle(IntPtr hWnd) {
  return IntPtr.Size == 8 ? GetWindowLongPtr64(hWnd, -20).ToInt64() : GetWindowLong32(hWnd, -20);
 }
 // A tray widget, a zero-size helper, a cloaked window or a minimized window is
 // not an application the user can interact with. Only a real, visible main
 // window means "this app is in the foreground".
 public static bool IsRealMainWindow(bool visible, bool iconic, bool toolWindow, int width, int height, bool cloaked) {
  if (!visible || iconic || cloaked || toolWindow) return false;
  return width >= 200 && height >= 150;
 }
 private static readonly object Sync = new object();
 private static DateTime CacheAt = DateTime.MinValue;
 private static HashSet<uint> CachedPids = new HashSet<uint>();
 public static HashSet<uint> ScanVisibleMainWindowPids() {
  var result = new HashSet<uint>();
  try {
   EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
    if (!IsWindowVisible(hWnd) || IsIconic(hWnd)) return true;
    int cloaked = 0;
    try { DwmGetWindowAttribute(hWnd, 14, out cloaked, 4); } catch {}
    long ex = 0;
    try { ex = WindowExStyle(hWnd); } catch {}
    RECT r;
    if (!GetWindowRect(hWnd, out r)) return true;
    if (!IsRealMainWindow(true, false, (ex & 0x80L) != 0,
                          r.Right - r.Left, r.Bottom - r.Top, cloaked != 0)) return true;
    uint pid;
    GetWindowThreadProcessId(hWnd, out pid);
    if (pid != 0) result.Add(pid);
    return true;
   }, IntPtr.Zero);
  } catch {}
  return result;
 }
 // The 200 ms probe asks about every helper process of a desktop app. One
 // short-lived cache keeps that to a single EnumWindows sweep per probe.
 public static bool HasVisibleMainWindow(uint pid) {
  lock (Sync) {
   if ((DateTime.UtcNow - CacheAt).TotalMilliseconds > 150) {
    CachedPids = ScanVisibleMainWindowPids(); CacheAt = DateTime.UtcNow;
   }
   return CachedPids.Contains(pid);
  }
 }
}
'@
}
# WorkBuddy, Doubao and DeepSeek Harness stay alive in the tray after their front
# window is minimized or closed. Only these three have a background-only mode.
$script:islandBackgroundProviders=@('WorkBuddy','豆包','DeepSeek Harness')
# DeepSeek Harness stores session logs as .zstd. Python 3.14+ ships compression.zstd
# in the standard library; older interpreters silently skip every Harness session,
# which leaves that brand stuck at "online" with no thinking/completed animation.
function Test-IslandPythonZstd($path) {
 if (!$path -or !(Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
 try {
  $info=[Diagnostics.ProcessStartInfo]::new()
  $info.FileName=[string]$path
  $info.Arguments='-c "import sys,compression.zstd; assert sys.version_info >= (3,14)"'
  $info.UseShellExecute=$false; $info.CreateNoWindow=$true
  $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
  $p=[Diagnostics.Process]::Start($info)
  try { if (!$p.WaitForExit(4000)) { return $false }; return $p.ExitCode -eq 0 }
  finally { $p.Dispose() }
 } catch { return $false }
}
function Get-IslandTelemetryPython {
 # Cached per runspace: both the collector and the resident fast channel call this.
 if ($script:islandTelemetryPythonChecked) { return $script:islandTelemetryPython }
 $script:islandTelemetryPythonChecked=$true; $script:islandTelemetryPython=''
 $candidates=@()
 $bundled=Join-Path $PSScriptRoot 'runtime\python\python.exe'
 if (Test-Path -LiteralPath $bundled) { $candidates+=@($bundled) }
 $launcher=Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
 if ($launcher) {
  try {
   foreach ($line in @(& $launcher.Source -0p 2>$null)) {
    if ($line -match '^\s*-V:3\.(\d+)\s+\*?\s+(.+\.exe)\s*$' -and [int]$Matches[1] -ge 14) {
     $candidates+=@($Matches[2].Trim())
    }
   }
  } catch {}
 }
 foreach ($base in @((Join-Path $env:LOCALAPPDATA 'Programs\Python'),'C:\',(Join-Path $env:ProgramFiles 'Python'))) {
  if (!$base -or !(Test-Path -LiteralPath $base)) { continue }
  foreach ($ver in @('Python314','Python315','Python316','Python313')) {
   $candidate=Join-Path (Join-Path $base $ver) 'python.exe'
   if (Test-Path -LiteralPath $candidate) { $candidates+=@($candidate) }
  }
 }
 $current=Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
 if ($current) { $candidates+=@($current.Source) }
 foreach ($candidate in @($candidates | Select-Object -Unique)) {
  if (Test-IslandPythonZstd $candidate) { $script:islandTelemetryPython=$candidate; break }
 }
 # Keep the old behaviour on machines without 3.14+: other providers still work.
 if (!$script:islandTelemetryPython -and $current) { $script:islandTelemetryPython=$current.Source }
 return $script:islandTelemetryPython
}
function Get-IslandProviderProcessNames($provider) {
 switch ($provider) {
  'Gemini' { return @('Gemini','GoogleGemini') }
  'WorkBuddy' { return @('WorkBuddy') }
  '豆包' { return @('Doubao','doubao_desktop','豆包') }
  'DeepSeek Harness' { return @('DeepSeek Harness','DeepSeek-Harness','DeepSeekHarness','deepseek','dsh') }
  default { return @() }
 }
}
function Test-IslandProviderPresence($provider,$process) {
 # A surviving process means the app still runs, even with no visible window.
 if ($provider -eq 'Codex') {
  return $process -and $process.ProcessName -eq 'ChatGPT' -and $process.Path -match '[\\/]OpenAI\.Codex_[^\\/]+[\\/]'
 }
 return $process -and ($process.ProcessName -in @(Get-IslandProviderProcessNames $provider))
}
function Test-IslandProviderForeground($provider,$process) {
 # When Doubao/WorkBuddy hide their main window in the tray, a tiny always-on
 # widget stays visible (Doubao shows a 52x52 floating ball). Windows then
 # reports that widget as MainWindowHandle. Inspecting only that one handle
 # would keep the app "foreground" forever, so real processes are classified
 # by enumerating all their top-level windows instead.
 if ($process -is [Diagnostics.Process]) {
  try { return [IslandWindowNative]::HasVisibleMainWindow([uint32]$process.Id) } catch { return $false }
 }
 $handle=[intptr]::Zero
 try { $handle=[intptr]$process.MainWindowHandle } catch {}
 if ($handle -eq [intptr]::Zero) { return $false }
 try {
  # Synthetic handles in unit tests stand for an ordinary visible window;
  # real windows are checked for minimized/hidden tray state.
  if (![IslandWindowNative]::IsWindow($handle)) { return $true }
  if ([IslandWindowNative]::IsIconic($handle)) { return $false }
  if (![IslandWindowNative]::IsWindowVisible($handle)) { return $false }
 } catch { return $true }
 return $true
}
function Get-IslandProviderWindowState($provider,$processes) {
 $matched=@($processes | Where-Object { Test-IslandProviderPresence $provider $_ })
 if (!$matched.Count) { return 'absent' }
 foreach ($p in $matched) { if (Test-IslandProviderForeground $provider $p) { return 'foreground' } }
 return 'background'
}
function Test-IslandBusyState($state) {
 return $state -in @('thinking','tool','action','chat_thinking')
}
function Test-IslandRecentTelemetry($sessions,[double]$windowSeconds=45) {
 # A provider still writing session events is alive even when its process name
 # or main window disappears into the tray. Doubao's minimized/tray helper
 # processes do not all share the desktop executable name, so the 200 ms window
 # probe can report "absent" while a background task is actually running.
 if (!$sessions) { return $false }
 $cutoff=[datetimeoffset]::Now.ToUnixTimeSeconds()-$windowSeconds
 foreach ($session in @($sessions)) {
  if (!$session) { continue }
  $stamp=if ($session.PSObject.Properties['Time']) { $session.Time } else { $null }
  if (!$stamp) { continue }
  try { if ([double]$stamp -ge $cutoff) { return $true } } catch { continue }
 }
 return $false
}
function Select-IslandVisibleAgents($agents) {
 # A background-only desktop app leaves the island unless it is still working.
 # CLI providers and other brands have no WindowState and are unaffected.
 @($agents | Where-Object {
  $_ -and $_.Name -and (
   $_.WindowState -ne 'background' -or
   (Test-IslandBusyState $_.State) -or
   (@($_.Sessions | Where-Object { Test-IslandBusyState $_.State }).Count -gt 0)
  )
 })
}
function Test-IslandProviderProcess($provider,$process) {
 $name=$process.ProcessName
 $path=$null; $window=[intptr]::Zero
 try { $window=[intptr]$process.MainWindowHandle } catch {}
 try { $path=$process.Path } catch {}
 switch ($provider) {
  '豆包' {
   return $name -match '^(doubao|豆包|doubao_desktop)$' -and $window -ne [intptr]::Zero
  }
  Codex {
   # The desktop application is ChatGPT.exe. resources/codex.exe is its backend,
   # and can outlive the window; CUA/node helpers must never imply app presence.
   if ($name -eq 'ChatGPT' -and $path -match '[\\/]OpenAI\.Codex_[^\\/]+[\\/]' -and $window -ne [intptr]::Zero) { return $true }
   if ($name -match '^(codex|CodexDesktop)$') {
    if ($path -match '[\\/]OpenAI\.Codex_[^\\/]+[\\/]app[\\/]resources[\\/]') { return $false }
    return $true
   }
   return $false
  }
  'WorkBuddy' {
   # Only the main window is the desktop application. Renderer/GPU/MCP node
   # helpers all share the same executable name and must never imply presence.
   return $name -eq 'WorkBuddy' -and $window -ne [intptr]::Zero
  }
  'DeepSeek Harness' {
   if ($name -match '^DeepSeek[ -]?Harness$') { return $window -ne [intptr]::Zero }
   return $name -match '^(deepseek|dsh)$'
  }
 }
 return $false
}
function Select-IslandUniqueAgents($agents) {
 @($agents | Where-Object { $_ -and $_.Name } | Group-Object Name | ForEach-Object { $_.Group | Select-Object -Last 1 })
}
function Select-IslandDisplayAgents($agents,$view,[datetimeoffset]$now=[datetimeoffset]::Now) {
 # Raw lifecycle data stays untouched. Every renderer uses this same projection,
 # so a background scan cannot bring the other OpenAI mode back into view.
 $others=@($agents | Where-Object Name -notin @('Codex','ChatGPT'))
 $codex=$agents | Where-Object Name -eq 'Codex' | Select-Object -Last 1
 $age=if ($view -and $view.Time) { ($now-[datetimeoffset]$view.Time).TotalSeconds } else { 999 }
 if (!$view -or !$view.Present -or $age -lt -1 -or $age -gt 4 -or $view.Mode -notin @('chat','work')) {
  return @($agents | Where-Object { $_.Name -ne 'ChatGPT' -and ($_.Name -ne 'Codex' -or $_ -eq $codex) })
 }
 $isChat=$view.Mode -eq 'chat'
 $state=if($isChat){if($view.State -in @('chat_thinking','complete')){$view.State}else{'unknown'}}else{if($view.State -in @('thinking','tool','action','error','complete','stopped')){$view.State}else{'unknown'}}
 $windowState=if ($view.WindowState) { $view.WindowState } elseif ($codex) { $codex.WindowState } else { $null }
 # In background Work/Codex, logs include running chats beyond the selected tab.
 # Ordinary chat must keep its independent blue thinking state.
 $sessions=@()
 if (!$isChat -and $windowState -eq 'background' -and $codex) {
  $sessions=@($codex.Sessions | Where-Object { Test-IslandBusyState $_.State })
  if ($sessions.Count -or (Test-IslandBusyState $codex.State)) { $state=$codex.State }
 }
 $display=[pscustomobject]@{Name=if($isChat){'ChatGPT'}else{'Codex'};State=$state;Active=if(Test-IslandBusyState $state){1}else{0};Sessions=$sessions;WindowState=$windowState;Source=$view.Source;Quota=$null;QuotaTime=$null;Context=$null;ProcessIds=@($view.ProcessId);Count=1;Memory=0}
 if (!$isChat -and $codex) { $display.Quota=$codex.Quota; $display.QuotaTime=$codex.QuotaTime; $display.Memory=$codex.Memory }
 $inserted=$false
 $ordered=@(foreach ($agent in $agents) {
  if ($agent.Name -in @('Codex','ChatGPT')) { if (!$inserted) { $display; $inserted=$true } }
  else { $agent }
 })
 if (!$inserted) { $ordered+=@($display) }
 return $ordered
}
