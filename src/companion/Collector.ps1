
 param($dataDir,$root)
 . (Join-Path $root 'AgentStatus.ps1')
 . (Join-Path $root 'AgentProcesses.ps1')
 $local:agents=@()
 if (!$script:fileCache) { $script:fileCache=@{} }
 $sessionStates=@()
 if (!$script:inventoryAt -or ([datetime]::Now-$script:inventoryAt).TotalSeconds -ge 2) {
 $script:allProcesses = @(Get-Process -ErrorAction SilentlyContinue)
 # Match executable names, plus known scripts hosted by node/python; never expose command lines.
 $hosted=@()
 try { $hosted=@(Get-CimInstance Win32_Process -Filter "Name = 'node.exe' OR Name = 'python.exe' OR Name = 'bun.exe' OR Name = 'dsh.exe'" -ErrorAction Stop) } catch {}
 $script:hostedProcesses=$hosted; $script:inventoryAt=[datetime]::Now
 }
 $all=$script:allProcesses; $hosted=$script:hostedProcesses
 foreach ($spec in @(@('Codex','^(codex|CodexDesktop)$','[\\/]@openai[\\/]codex[\\/]|[\\/]codex\.(js|mjs)(?:["\s]|$)'),@('DeepSeek Harness','^(DeepSeek[ -]?Harness|deepseek|dsh)$','deepseek-harness|[\\/]dsh[\\/]|[\\/]dsh\.(js|mjs|py)(?:["\s]|$)'),@('豆包','^(doubao|豆包|doubao_desktop)$','doubao'),@('Claude','^(claude|ClaudeDesktop)$','[\\/]claude([\\/.]|-code)'),@('Cursor','^Cursor$','cursor'),@('OpenClaw','^openclaw.*$','[\\/]openclaw[\\/]|openclaw\.(mjs|js)|openclaw.*gateway'),@('Ollama','^ollama','ollama'),@('Gemini','^(Gemini|GoogleGemini|gemini-cli)$','[\\/]@google[\\/]gemini-cli[\\/]|[\\/]gemini-cli[\\/]|[\\/]gemini\.(js|mjs)'),@('WorkBuddy','^WorkBuddy$','^$'))) {
  if ($spec[0] -in @('Codex','DeepSeek Harness','豆包','WorkBuddy')) { $ps=@($all | Where-Object { Test-IslandProviderProcess $spec[0] $_ }) }
  else { $ps = @($all | Where-Object ProcessName -Match $spec[1]) }
  $hosts=@($hosted | Where-Object { $_.CommandLine -match $spec[2] })
  if ($spec[0] -in @('豆包','WorkBuddy')) { $hosts=@() } # Desktop only; node MCP/daemon helpers are not separate agents.
  $windowState=$null
  if ($spec[0] -in @('Codex','豆包','WorkBuddy','DeepSeek Harness','Gemini')) {
   $trayProcesses=@($all | Where-Object { Test-IslandProviderPresence $spec[0] $_ })
   $windowState=Get-IslandProviderWindowState $spec[0] $trayProcesses
   # A minimized or tray-hidden window still belongs to a running application.
   # Keep its lifecycle row so a busy background agent stays visible on the island.
   if ($windowState -ne 'absent' -and !$ps.Count) { $ps=$trayProcesses }
   if ($windowState -eq 'absent') { $windowState=$null } # Pure CLI has no window rule.
  }
  if ($ps.Count -or $hosts.Count) { $local:agents += [pscustomobject]@{Name=$spec[0]; Count=$ps.Count+$hosts.Count; ProcessIds=@($ps.Id)+@($hosts.ProcessId); Memory=[math]::Round(($ps | Measure-Object WorkingSet64 -Sum).Sum / 1MB); State='online'; Active=0; Sessions=@(); Source='已检测到应用进程；尚无可读取的生命周期事件'; Quota=$null; QuotaTime=$null; Context=$null; WindowState=$windowState} }
 }
 $local:usage = @()
 $local:quota=$null; $local:quotaTime=$null
 $logDir = Join-Path $env:USERPROFILE '.codex\sessions'
 if (Test-Path $logDir) {
  foreach ($f in @(Get-ChildItem $logDir -Filter *.jsonl -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 20)) {
   try {
    $cacheKey=$f.FullName
    $version="$($f.Length):$($f.LastWriteTimeUtc.Ticks)"
    $cached=$script:fileCache[$cacheKey]
    if (!$cached -or $cached.Version -ne $version) {
     $lines=@(Read-SessionTail $f.FullName)
     $cached=@{Version=$version; Lines=$lines}
     $script:fileCache[$cacheKey]=$cached
    }
    $session=Get-SessionState $cached.Lines
    $session=Add-CodexSessionIdentity $session $f.FullName
    $sessionStates += $session
    $last = $cached.Lines | Where-Object { $_ -match '"token_count"' -and $_ -match 'total_token_usage' } | Select-Object -Last 1
    if ($last) {
     $record=$last | ConvertFrom-Json
     if ($record.payload.rate_limits -and (!$local:quotaTime -or [datetimeoffset]$record.timestamp -gt [datetimeoffset]$local:quotaTime)) {
      $local:quota=$record.payload.rate_limits; $local:quotaTime=$record.timestamp
     }
    }
    if ($last -and $f.CreationTime.Date -eq (Get-Date).Date) { $ev = $last | ConvertFrom-Json; $u = $ev.payload.info.total_token_usage; if ($u) { $local:usage += [pscustomobject]@{Agent='Codex'; File=$f.Name; Total=[long]$u.total_tokens; Input=[long]$u.input_tokens; Cached=[long]$u.cached_input_tokens; Output=[long]$u.output_tokens; Time=$ev.timestamp; Limits=$ev.payload.rate_limits} } }
   } catch {}
  }
 }
 $sessionStates=@(Select-CodexSessions $sessionStates)
 $codex=$local:agents | Where-Object Name -eq 'Codex'
 if ($codex -and $sessionStates.Count) {
  $active=@($sessionStates | Where-Object State -in @('thinking','tool','action'))
  $latest=$sessionStates | Where-Object Time | Sort-Object Time -Descending | Select-Object -First 1
  $codex.Sessions=@($active | ForEach-Object { [pscustomobject]@{State=$_.State;Time=$_.Time} })
  $codex.Quota=$local:quota; $codex.QuotaTime=$local:quotaTime
  $codex.Active=$active.Count
  if ($active.Count) {
   $codex.State=($active | Sort-Object Time -Descending | Select-Object -First 1).State
  } elseif ($latest -and ([datetimeoffset]::Now-$latest.Time).TotalMinutes -le 10) { $codex.State=$latest.State }
  $codex.Source='Codex 会话生命周期日志；10 分钟无事件的运行状态标为待确认'
 }
 # Optional adapter: a zstd-capable Python decodes Harness logs and reads other providers.
 $pythonExe=Get-IslandTelemetryPython
 if ($pythonExe) {
  try {
   $start=New-Object Diagnostics.ProcessStartInfo
   $start.FileName=$pythonExe
   $start.Arguments='"'+(Join-Path $root 'AgentTelemetry.py')+'" --cache "'+(Join-Path $dataDir 'telemetry-cache.json')+'"'
   $start.UseShellExecute=$false; $start.CreateNoWindow=$true
   $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
   $process=[Diagnostics.Process]::Start($start)
   $outputTask=$process.StandardOutput.ReadToEndAsync(); $errorTask=$process.StandardError.ReadToEndAsync()
   if (!$process.WaitForExit(6000)) { $process.Kill(); throw 'Telemetry timeout' }
   if ($process.ExitCode -ne 0) { throw 'Telemetry unavailable' }
   $extra=$outputTask.Result | ConvertFrom-Json
   foreach ($a in $local:agents) {
    if ($a.Name -eq 'Codex') { continue }
    $detail=$extra.($a.Name)
    if (!$detail) { continue }
    $local:usage+=@($detail.Usage)
    $active=@($detail.Sessions | Where-Object State -in @('thinking','tool','action'))
    $latest=$detail.Sessions | Sort-Object Time -Descending | Select-Object -First 1
    $a.Active=$active.Count; $a.Sessions=$active
    $a.Context=$detail.Context
    if ($detail.Quota) { $a.Quota=$detail.Quota; $a.QuotaTime=$detail.QuotaTime }
    if ($active.Count) { $a.State=($active | Sort-Object Time -Descending | Select-Object -First 1).State }
    elseif ($latest) { $a.State=if ($latest.State -eq 'unknown' -or ([datetimeoffset]::Now.ToUnixTimeSeconds()-$latest.Time) -le 600) { $latest.State } else { 'online' } }
    $a.Source=$detail.Source
    if ($detail.Warning) { $a.Source+='；'+$detail.Warning }
   }
   $process.Dispose()
  } catch {
   foreach ($a in $local:agents | Where-Object Name -ne 'Codex') { $a.Source+='；本地日志适配器暂不可用（Harness 需要 Python 3.14+）' }
  }
 }
 # Clients without a readable account quota interface can use a locally stored
 # snapshot. Both providers share the same UsedPercent/WindowMinutes/ResetsAt shape.
 foreach ($quotaSpec in @(@('豆包','doubao-quota.json'),@('WorkBuddy','workbuddy-quota.json'))) {
  $quotaFile = Join-Path $dataDir $quotaSpec[1]
  if (!(Test-Path $quotaFile)) { continue }
  foreach ($a in @($local:agents | Where-Object Name -eq $quotaSpec[0])) {
   try {
    $q = Get-Content $quotaFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $q.UsedPercent) { continue }
    $a.Quota = [pscustomobject]@{primary=[pscustomobject]@{used_percent=[double]$q.UsedPercent; window_minutes=[double]$q.WindowMinutes; resets_at=$q.ResetsAt; window_label=$q.WindowLabel}}
    $a.QuotaTime = $q.Time
    if ($q.Source) { $a.Source += '；额度快照：' + $q.Source }
   } catch {}
  }
 }
 $nf = Join-Path $dataDir 'notifications.json' 
 if (Test-Path $nf) { try { $n = Get-Content $nf -Raw -Encoding UTF8 | ConvertFrom-Json; $local:notificationStatus = $n.status; $local:notices = @($n.items) } catch {} }

 $local:agents=@(Select-IslandUniqueAgents $local:agents)
 [pscustomobject]@{CodexStates=@($sessionStates);Quota=$local:quota; QuotaTime=$local:quotaTime; Agents=@($local:agents); Usage=@($local:usage); Notices=@($local:notices); Status=$local:notificationStatus}
