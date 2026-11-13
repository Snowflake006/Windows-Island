param([int]$Owner,[switch]$Once)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=$PSScriptRoot
$dataDir=$env:WORKPELLET_DATA_DIR
$null=New-Item -ItemType Directory -Force $dataDir
$bundledPython=Join-Path $root 'runtime\python'
if (!(Test-Path (Join-Path $bundledPython 'python.exe')) -and (Test-Path (Join-Path $root 'python-runtime.zip'))) {
 $null=New-Item -ItemType Directory -Force $bundledPython
 Expand-Archive -LiteralPath (Join-Path $root 'python-runtime.zip') -DestinationPath $bundledPython -Force
}
. (Join-Path $root 'AgentStatus.ps1')
. (Join-Path $root 'AgentProcesses.ps1')
$collector=[PowerShell]::Create(); $vpn=[PowerShell]::Create()
$collection=[IO.File]::ReadAllText((Join-Path $root 'Collector.ps1'))
$vpnModule=[IO.File]::ReadAllText((Join-Path $root 'VpnStatus.ps1'))
$vpnLoaded=$false
try { & (Join-Path $root 'Hello.ps1') -Directory $dataDir } catch {}
$pending=$null; $vpnPending=$null; $desktop=$null; $fast=$null
$agents=@(); $usage=@(); $vpnState=@{Connected=$false;Text='正在检查连接'}
try {
 $info=[Diagnostics.ProcessStartInfo]::new('powershell.exe')
 $info.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+(Join-Path $root 'DesktopAgentMonitor.ps1')+'" -Owner '+$Owner
 $info.UseShellExecute=$false; $info.CreateNoWindow=$true
 $desktopInfo=$info; $desktop=[Diagnostics.Process]::Start($desktopInfo)
 $python=Get-IslandTelemetryPython
 if ($python) {
  $info=[Diagnostics.ProcessStartInfo]::new($python)
  $info.Arguments='-u "'+(Join-Path $root 'AgentTelemetry.py')+'" --watch-fast'
  $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
  $fast=[Diagnostics.Process]::Start($info); $fastLine=$fast.StandardOutput.ReadLineAsync(); $fastError=$fast.StandardError.ReadToEndAsync()
 }
 $nextFull=[datetime]::MinValue; $nextVpn=[datetime]::MinValue
 do {
  if (!$Once -and !(Get-Process -Id $Owner -ErrorAction SilentlyContinue)) { break }
  if ($desktop -and $desktop.HasExited -and (!$desktopRetry -or [datetime]::Now -ge $desktopRetry)) { $desktop.Dispose();$desktop=[Diagnostics.Process]::Start($desktopInfo);$desktopRetry=[datetime]::Now.AddSeconds(3) }
  if (!$pending -and [datetime]::Now -ge $nextFull) {
   $collector.Commands.Clear(); $null=$collector.AddScript($collection).AddArgument($dataDir).AddArgument($root); $pending=$collector.BeginInvoke()
  }
  if ($pending -and $pending.IsCompleted) {
   $result=@($collector.EndInvoke($pending)) | Select-Object -Last 1; $pending=$null; $nextFull=[datetime]::Now.AddSeconds(2)
   if ($result) {$agents=@($result.Agents);$usage=@($result.Usage)}
  }
  if (!$vpnPending -and [datetime]::Now -ge $nextVpn) {
   $vpn.Commands.Clear()
   # Load once so discovery and delay caches survive between runspace calls.
   if (!$vpnLoaded) { $null=$vpn.AddScript($vpnModule,$false); $vpnLoaded=$true }
   $null=$vpn.AddScript('Get-IslandVpnStatus'); $vpnStartedAt=[datetime]::Now; $vpnPending=$vpn.BeginInvoke()
  }
  if ($vpnPending -and $vpnPending.IsCompleted) {
   $v=@($vpn.EndInvoke($vpnPending)) | Select-Object -Last 1
   if($v){$vpnState=$v}else{$vpnState=@{Connected=$false;Delay=$null;Text='VPN 状态暂不可读'}}
   $vpn.Streams.Error.Clear(); $vpnPending=$null; $nextVpn=$vpnStartedAt.AddSeconds(3)
  }
  if ($fast -and $fastLine.IsCompleted) {
   try { $line=$fastLine.Result; if($line){$fastSnapshot=$line | ConvertFrom-Json}; $fastLine=$fast.StandardOutput.ReadLineAsync() } catch {$fastSnapshot=$null}
  }
  $display=@($agents | ForEach-Object { $_ | Select-Object * })
  # Fast lifecycle metadata overrides the slower inventory without inventing completion.
  foreach ($a in $display) {
   if ($a.Name -eq 'Codex') {
    try {
     if (!$codexInventoryAt -or ([datetime]::Now-$codexInventoryAt).TotalSeconds -ge 2) { $fastCodexFiles=Get-ChildItem (Join-Path $env:USERPROFILE '.codex\sessions') -Filter *.jsonl -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 20; $codexInventoryAt=[datetime]::Now }
     $files=$fastCodexFiles
     if (!$codexCache){$codexCache=@{}}
     $states=@(foreach($f in $files){$f.Refresh(); $version="$($f.Length):$($f.LastWriteTimeUtc.Ticks)";if(!$codexCache[$f.FullName] -or $codexCache[$f.FullName].Version -ne $version){$codexCache[$f.FullName]=@{Version=$version;Lines=@(Read-SessionTail $f.FullName)}};Add-CodexSessionIdentity (Get-SessionState $codexCache[$f.FullName].Lines) $f.FullName})
     $states=@(Select-CodexSessions $states)
     $busy=@($states | Where-Object State -in @('action','tool','thinking')); $latest=$states | Where-Object Time | Sort-Object Time -Descending | Select-Object -First 1
     if($busy.Count){$a.State=($busy | Sort-Object Time -Descending | Select-Object -First 1).State} elseif($latest){$a.State=$latest.State}
    } catch {}
   }
   if ($fastSnapshot -and ([datetimeoffset]::Now.ToUnixTimeMilliseconds()/1000.0-$fastSnapshot.SampledAt) -lt 2) {
    $detail=switch($a.Name){ '豆包' {$fastSnapshot.Detail}; 'DeepSeek Harness' {$fastSnapshot.Harness}; 'WorkBuddy' {$fastSnapshot.WorkBuddy} }
    if($detail){
     $busy=@($detail.Sessions | Where-Object State -in @('thinking','tool','action')); $latest=$detail.Sessions | Sort-Object Time -Descending | Select-Object -First 1
     if($busy.Count){$a.State=($busy | Sort-Object Time -Descending | Select-Object -First 1).State}elseif($latest){$a.State=$latest.State}
    }
   }
  }
  try {
   $view=Get-Content (Join-Path $dataDir 'desktop-agent-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
   if($view.Gemini.Present -and ([datetimeoffset]::Now-[datetimeoffset]$view.Gemini.Time).TotalSeconds -lt 4){foreach($a in $display | Where-Object Name -eq 'Gemini'){$a.State=$view.Gemini.State;$a.WindowState=$view.Gemini.WindowState}}
   $display=@(Select-IslandDisplayAgents $display $view.ChatGPT)
  } catch {}
  foreach($a in $display){$a.ProcessIds=@($a.ProcessIds | Where-Object {$_ -and $_ -gt 0} | ForEach-Object {[int]$_})}
  $unlockHint='unknown'
  try { $provider=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI' -Name LastLoggedOnProvider -ErrorAction Stop).LastLoggedOnProvider; if($provider -eq '{8AF662BF-65A0-4D0A-A540-A338A999D36F}'){$unlockHint='face'}elseif($provider -eq '{D6886603-9D2F-4EB2-B667-1971041FA96B}'){$unlockHint='pin'} } catch {}
  [Console]::WriteLine((@{UnlockHint=$unlockHint;Agents=@($display);Usage=@($usage);Vpn=$vpnState;Ready=($null -ne $result);SampledAt=[datetimeoffset]::Now.ToUnixTimeSeconds()} | ConvertTo-Json -Depth 12 -Compress))
  if($Once -and $result){break}
  Start-Sleep -Milliseconds 200
 } while($true)
} finally {
 foreach($p in @($desktop,$fast)){if($p){try{if(!$p.HasExited){$p.Kill()}}catch{};$p.Dispose()}}
 $collector.Dispose();$vpn.Dispose()
}
