function Get-VpnColor($connected,$delay) {
 if (!$connected) { return $null }
 if ($null -eq $delay -or $delay -gt 300) { return '#E6505B' }
 if ($delay -gt 150) { return '#D7A82E' }
 return '#25A96A'
}
function Invoke-IslandMihomo($pipeName,$path) {
 $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$pipeName,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
 try {
  $pipe.Connect(700)
  $bytes=[Text.Encoding]::ASCII.GetBytes("GET $path HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`n`r`n")
  $pipe.Write($bytes,0,$bytes.Length); $pipe.Flush()
  $reader=[IO.StreamReader]::new($pipe,[Text.Encoding]::UTF8)
  try {
   $task=$reader.ReadToEndAsync()
   if (!$task.Wait(4500)) { throw 'Local controller timeout' }
   $raw=$task.Result
  } finally { $reader.Dispose() }
  $parts=$raw -split "`r`n`r`n",2
  if ($parts.Count -ne 2 -or $parts[0] -notmatch '^HTTP/1\.[01] 200') { throw 'Local controller unavailable' }
  $body=$parts[1]
  if ($parts[0] -match '(?i)Transfer-Encoding: chunked') {
   $decoded=[Text.StringBuilder]::new(); $offset=0
   while ($offset -lt $body.Length) {
    $end=$body.IndexOf("`r`n",$offset); if ($end -lt 0) { break }
    $length=[Convert]::ToInt32(($body.Substring($offset,$end-$offset) -split ';')[0],16)
    if (!$length) { break }; $offset=$end+2
    # JSON is UTF-8: chunk lengths count bytes, not .NET UTF-16 characters.
    $remaining=[Text.Encoding]::UTF8.GetBytes($body.Substring($offset))
    $piece=[Text.Encoding]::UTF8.GetString($remaining,0,$length)
    $null=$decoded.Append($piece); $offset+=$piece.Length+2
   }
   $body=$decoded.ToString()
  }
  $body | ConvertFrom-Json
 } finally { $pipe.Dispose() }
}
function Get-IslandVpnStatus([switch]$NoProbe) {
 $off=[pscustomobject]@{Connected=$false;Delay=$null;Color=$null;Text='VPN 未连接';Checked=[datetime]::Now}
 try {
  $config=Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'
  if (!(Test-Path $config)) { return $off }
  $text=[IO.File]::ReadAllText($config)
  $pipePath=[regex]::Match($text,'(?m)^external-controller-pipe:\s*(.+)$').Groups[1].Value.Trim().Trim("'",'"')
  if (!$pipePath.StartsWith('\\.\pipe\')) { return $off }
  $pipeName=$pipePath.Substring(9)
  $runtime=Invoke-IslandMihomo $pipeName '/configs'
  if ($runtime.mode -eq 'direct') { return $off }
  $proxy=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
  $port=$runtime.'mixed-port'
  $systemProxy=$proxy.ProxyEnable -eq 1 -and $port -gt 0 -and $proxy.ProxyServer -match ("(?:127\.0\.0\.1|localhost):"+$port+'(?:;|$)')
  if (!$systemProxy -and !$runtime.tun.enable) { return $off }
  $proxies=(Invoke-IslandMihomo $pipeName '/proxies').proxies
  $selected='GLOBAL'
  if ($runtime.mode -eq 'rule') {
   $rules=(Invoke-IslandMihomo $pipeName '/rules').rules
   $match=$rules | Where-Object type -eq 'Match' | Select-Object -Last 1
   if (!$match) { return $off }; $selected=$match.proxy
  }
  $visited=@{}
  for ($i=0;$i -lt 16;$i++) {
   if ($selected -in @('DIRECT','REJECT','REJECT-DROP','PASS') -or $visited.ContainsKey($selected)) { return $off }
   $visited[$selected]=$true
   $node=$proxies.PSObject.Properties[$selected].Value
   if (!$node) { return $off }
   if (!$node.now) { break }; $selected=[string]$node.now
  }
  $delay=$null
  if ($NoProbe) {
   $history=@($node.history | Select-Object -Last 1)
   if ($history.Count -and $history[0].delay -gt 0) { $delay=[double]$history[0].delay }
   return [pscustomobject]@{Connected=$true;Delay=$delay;Color=(Get-VpnColor $true $delay);Text='VPN 已启用 · 正在测速';Key=($pipeName+'|'+$selected);Pipe=$pipeName;Node=$selected;Checked=[datetime]::Now}
  }
  try {
   $name=[uri]::EscapeDataString($selected)
   $result=Invoke-IslandMihomo $pipeName ("/proxies/$name/delay?timeout=2500&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204")
   if ($result.delay -gt 0) { $delay=[double]$result.delay }
  } catch {}
  $description=if ($null -eq $delay) { 'VPN 已启用 · 测速超时或暂不可达' } else { "VPN 节点延迟 $delay ms" }
  [pscustomobject]@{Connected=$true;Delay=$delay;Color=(Get-VpnColor $true $delay);Text=$description;Checked=[datetime]::Now}
 } catch { return $off }
}

function Measure-IslandVpnNode($state) {
 $delay=$null
 try {
  $name=[uri]::EscapeDataString($state.Node)
  $result=Invoke-IslandMihomo $state.Pipe ("/proxies/$name/delay?timeout=1500&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204")
  if ($result.delay -gt 0) { $delay=[double]$result.delay }
 } catch {}
 [pscustomobject]@{Connected=$true;Key=$state.Key;Delay=$delay;Color=(Get-VpnColor $true $delay);Text=$(if($null -eq $delay){'VPN 已启用 · 测速超时'}else{"VPN 节点延迟 $delay ms"});Checked=[datetime]::Now}
}
