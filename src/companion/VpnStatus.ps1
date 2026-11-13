# Shared read-only Mihomo detection. Private controller objects never leave this runspace.
Add-Type -AssemblyName System.Net.Http
if (!('IslandMihomoPipeNative' -as [type])) {
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class IslandMihomoPipeNative {
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
'@
}
function Get-VpnColor($connected,$delay) {
 if (!$connected) { return $null }
 if ($null -eq $delay -or $delay -gt 300) { return '#E6505B' }
 if ($delay -gt 150) { return '#D7A82E' }
 return '#25A96A'
}
function Get-IslandMihomoClientName([string]$name) {
 switch -Regex ([IO.Path]::GetFileNameWithoutExtension($name)) {
  '^(clash-verge|clash-verge-rev)$' { return 'Clash Verge Rev' }
  '^(clash-party|mihomo-party)$' { return 'Clash Party' }
  '^flclash$' { return 'FlClash' }
  '^clash-nyanpasu$' { return 'Clash Nyanpasu' }
 }
 return $null
}
function Test-IslandMihomoCoreName([string]$name) {
 return [IO.Path]::GetFileNameWithoutExtension($name) -match '^(mihomo(?:[-_].*)?|clash-meta(?:[-_].*)?|verge-mihomo(?:[-_].*)?|FlClashCore)$'
}
function Get-IslandMihomoProcesses {
 # CLI can contain a secret. Never print these objects or exception details.
 @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { (Get-IslandMihomoClientName $_.Name) -or (Test-IslandMihomoCoreName $_.Name) })
}
function Get-IslandMihomoListeners {
 @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Select-Object LocalAddress,LocalPort,OwningProcess)
}
function Get-IslandMihomoSocketOwners([string]$address,$listeners) {
 $uri=[uri]$address; $hostName=$uri.DnsSafeHost.Trim('[',']')
 $parsed=$null; if ([Net.IPAddress]::TryParse($hostName,[ref]$parsed)) { $hostName=$parsed.ToString() }
 $addresses=switch ($hostName) {
  'localhost' { @('127.0.0.1','::1','0.0.0.0','::') }
  '::1' { @('::1','::') }
  default { @($hostName,'0.0.0.0') }
 }
 @($listeners | Where-Object { $_.LocalPort -eq $uri.Port -and $_.LocalAddress -in $addresses } | Select-Object -ExpandProperty OwningProcess -Unique)
}
function Get-IslandMihomoArgument([string]$command,[string]$flag) {
 $match=[regex]::Match($command,'(?:^|\s)(?:'+$flag+')(?:=|\s+)(?:"([^"]*)"|''([^'']*)''|([^\s]+))')
 if ($match.Success) { foreach ($index in 1..3) { if ($match.Groups[$index].Success) { return $match.Groups[$index].Value } } }
 return $null
}
function ConvertFrom-IslandYamlScalar([string]$value) {
 $value=$value.Trim()
 if ($value -match '^''((?:[^'']|'''')*)''\s*(?:#.*)?$') { return $Matches[1].Replace("''", "'") }
 if ($value -match '^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$') { try { return ('"'+$Matches[1]+'"' | ConvertFrom-Json -ErrorAction Stop) } catch { return $null } }
 return ($value -replace '\s+#.*$','').Trim()
}
function Read-IslandMihomoControllerConfig([string]$path) {
 $values=@{}
 if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $values }
 try {
  if ((Get-Item -LiteralPath $path).Length -gt 8MB) { return $values }
  # Only controller metadata is interpreted; never parse proxy/subscription credentials.
  foreach ($line in [IO.File]::ReadLines($path)) {
   if ($line -match '^(external-controller(?:-pipe|-tls)?|secret):\s*(.*?)\s*$') { $values[$Matches[1]]=ConvertFrom-IslandYamlScalar $Matches[2] }
  }
 } catch { return @{} }
 return $values
}
function New-IslandMihomoController([string]$address,[string]$secret='', [int]$ownerId=0,[string]$client='Mihomo',[switch]$Pipe) {
 if (!$address -or $secret -match '[\r\n]') { return $null }
 if ($Pipe) {
  if (!$address.StartsWith('\\.\pipe\',[StringComparison]::OrdinalIgnoreCase)) { return $null }
  return [pscustomobject]@{Kind='pipe';Address=$address.Substring(9);Secret=$secret;OwnerId=$ownerId;Client=$client;Key=('pipe:'+ $address);Verified=$false;RetryAt=[datetime]::MinValue}
 }
 if ($address -notmatch '^https?://') { $address='http://'+$address }
 $uri=$null
 if (![uri]::TryCreate($address,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) { return $null }
 $hostName=$uri.DnsSafeHost.Trim('[',']')
 $parsed=$null; if ([Net.IPAddress]::TryParse($hostName,[ref]$parsed)) { $hostName=$parsed.ToString() }
 if ($hostName -in @('0.0.0.0','::')) { $hostName=if($hostName -eq '::'){'::1'}else{'127.0.0.1'} }
 $ip=$null
 if ($hostName -ne 'localhost' -and (![Net.IPAddress]::TryParse($hostName,[ref]$ip) -or ![Net.IPAddress]::IsLoopback($ip))) { return $null }
 $builder=[UriBuilder]::new($uri); $builder.Host=$hostName
 return [pscustomobject]@{Kind='http';Address=$builder.Uri.AbsoluteUri.TrimEnd('/');Secret=$secret;OwnerId=$ownerId;Client=$client;Key=$builder.Uri.AbsoluteUri;Verified=$false;RetryAt=[datetime]::MinValue}
}
function Get-IslandMihomoConfigPaths($process,$processes) {
 $paths=@(); $directories=@()
 $file=Get-IslandMihomoArgument $process.CommandLine '-f|--config'
 $directory=Get-IslandMihomoArgument $process.CommandLine '-d|--home'
 # Never resolve another process's relative arguments against Island's directory.
 if ($file -and [IO.Path]::IsPathRooted($file)) { $paths+=$file }
 if ($directory -and [IO.Path]::IsPathRooted($directory)) { $directories+=$directory }
 if ($process.ExecutablePath) { $base=Split-Path $process.ExecutablePath -Parent; $directories+=@($base,(Join-Path $base 'data'),(Join-Path $base 'data\profiles')) }
 foreach ($base in @([Environment]::GetFolderPath('ApplicationData'),[Environment]::GetFolderPath('LocalApplicationData'))) {
  if (!$base) { continue }
  foreach ($relative in @('io.github.clash-verge-rev.clash-verge-rev','clash-party','mihomo-party','FlClash','com.follow.clash','com.follow\clash','clash-nyanpasu','org.dzhqu.clash-nyanpasu','com.github.libnyanpasu.clash-nyanpasu')) { $directories+=Join-Path $base $relative }
 }
 foreach ($base in $directories | Select-Object -Unique) { foreach ($name in 'config.yaml','config.yml','clash-verge.yaml','clash-party.yaml','clash-nyanpasu.yaml') { $paths+=Join-Path $base $name } }
 @($paths | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
}
function Get-IslandMihomoDiscovery([switch]$Refresh) {
 if (!$Refresh -and $script:islandMihomoDiscovery -and ([datetime]::UtcNow-$script:islandMihomoDiscovery.At).TotalSeconds -lt 15) { return $script:islandMihomoDiscovery }
 $processes=@(Get-IslandMihomoProcesses)
 $clients=@($processes | ForEach-Object { Get-IslandMihomoClientName $_.Name } | Where-Object { $_ } | Select-Object -Unique)
 $cores=@($processes | Where-Object { Test-IslandMihomoCoreName $_.Name })
 $listeners=@(); $listenerKnown=$true
 try { $listeners=@(Get-IslandMihomoListeners) } catch { $listenerKnown=$false }
 $controllers=@(); $seen=@{}; $configs=@{}; $clientById=@{}
 foreach ($process in $processes) {
  $client=Get-IslandMihomoClientName $process.Name
  if (!$client) { $parent=$processes | Where-Object ProcessId -eq $process.ParentProcessId | Select-Object -First 1; if ($parent) { $client=Get-IslandMihomoClientName $parent.Name } }
  $clientById[[int]$process.ProcessId]=if($client){$client}else{'Mihomo'}
 }
 foreach ($process in $processes) {
  $client=Get-IslandMihomoClientName $process.Name
  if (!$client) { $parent=$processes | Where-Object ProcessId -eq $process.ParentProcessId | Select-Object -First 1; if ($parent) { $client=Get-IslandMihomoClientName $parent.Name } }
  if (!$client) { $client='Mihomo' }
  $argumentSecret=Get-IslandMihomoArgument $process.CommandLine '-secret|--secret'
  $processControllers=@()
  foreach ($path in @(Get-IslandMihomoConfigPaths $process $processes)) {
   if (!$configs.ContainsKey($path)) { $configs[$path]=Read-IslandMihomoControllerConfig $path }
   $config=$configs[$path]
   foreach ($key in 'external-controller-pipe','external-controller','external-controller-tls') {
    $address=$config[$key]
    if ($key -eq 'external-controller-tls' -and $address -and $address -notmatch '^https://') { $address='https://'+$address }
    $secret=if($null -ne $argumentSecret){$argumentSecret}else{$config.secret}
    $candidate=New-IslandMihomoController $address $secret $process.ProcessId $client -Pipe:($key -eq 'external-controller-pipe')
    if ($candidate) { $processControllers+=@($candidate) }
   }
  }
  $ctl=Get-IslandMihomoArgument $process.CommandLine '-ext-ctl|--external-controller'
  $pipe=Get-IslandMihomoArgument $process.CommandLine '-ext-ctl-pipe|--external-controller-pipe'
  $secret=Get-IslandMihomoArgument $process.CommandLine '-secret|--secret'
  foreach ($candidate in @((New-IslandMihomoController $ctl $secret $process.ProcessId $client),(New-IslandMihomoController $pipe $secret $process.ProcessId $client -Pipe))) { if ($candidate) { $processControllers=@($candidate)+$processControllers } }
  foreach ($listener in @($listeners | Where-Object OwningProcess -eq $process.ProcessId)) {
   if ($listener.LocalAddress -notin @('127.0.0.1','::1','0.0.0.0','::')) { continue }
   $address='127.0.0.1:'+ $listener.LocalPort
   if ($listener.LocalAddress -in @('::','::1')) { $address='[::1]:'+ $listener.LocalPort }
   $processControllers+=@(New-IslandMihomoController $address $secret $process.ProcessId $client)
  }
  foreach ($candidate in $processControllers) {
   if (!$candidate) { continue }
   if ($candidate.Kind -eq 'http') {
    $owners=@(Get-IslandMihomoSocketOwners $candidate.Address $listeners | Where-Object { $_ -in @($processes.ProcessId) })
    if ($owners.Count -ne 1) { continue }; $candidate.OwnerId=[int]$owners[0]; $candidate.Client=$clientById[$candidate.OwnerId]
   }
   $identity=$candidate.Key+'|'+$candidate.Secret
   if (!$seen.ContainsKey($identity)) { $seen[$identity]=$true; $controllers+=@($candidate) }
  }
 }
 $script:islandMihomoDiscovery=[pscustomobject]@{At=[datetime]::UtcNow;Clients=$clients;Cores=$cores.Count;CoreIds=@($cores.ProcessId);Controllers=@($controllers | Select-Object -First 16);Listeners=$listeners;ListenerKnown=$listenerKnown;ClientById=$clientById}
 return $script:islandMihomoDiscovery
}
function Invoke-IslandMihomo($controller,[string]$path) {
 # Keep compatibility with the old pipe-name invocation.
 if ($controller -is [string]) { $controller=[pscustomobject]@{Kind='pipe';Address=$controller;Secret=''} }
 if ($path -notmatch '^/[a-zA-Z0-9/%?=&_.:+-]+$' -or $path -match '[\r\n]') { throw 'Invalid controller request' }
 $timeout=if($path -match '^/proxies/.+/delay\?'){3000}else{1400}
 if ($controller.Kind -eq 'http') {
  $handler=[Net.Http.HttpClientHandler]::new(); $handler.UseProxy=$false; $handler.AllowAutoRedirect=$false
  $http=[Net.Http.HttpClient]::new($handler); $http.Timeout=[timespan]::FromMilliseconds($timeout); $http.MaxResponseContentBufferSize=2MB
  try {
   if ($controller.Secret) { $http.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$controller.Secret) }
   $response=$http.GetAsync($controller.Address+$path).GetAwaiter().GetResult()
   try { if (!$response.IsSuccessStatusCode) { throw 'Controller unavailable' }; return ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -ErrorAction Stop) } finally { $response.Dispose() }
  } finally { $http.Dispose(); $handler.Dispose() }
 }
 $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$controller.Address,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
 try {
  $pipe.Connect(250)
  if ($controller.PSObject.Properties['OwnerId']) {
   [uint32]$serverId=0
   if ([IslandMihomoPipeNative]::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$serverId)) { $controller.OwnerId=[int]$serverId }
   else { $controller.OwnerId=0 }
  }
  $authorization=if($controller.Secret){'Authorization: Bearer '+$controller.Secret+"`r`n"}else{''}
  $bytes=[Text.Encoding]::UTF8.GetBytes("GET $path HTTP/1.1`r`nHost: localhost`r`n${authorization}Connection: close`r`n`r`n")
  $write=$pipe.WriteAsync($bytes,0,$bytes.Length); if (!$write.Wait(500)) { throw 'Controller timeout' }
  $stream=[IO.MemoryStream]::new(); $buffer=New-Object byte[] 8192; $clock=[Diagnostics.Stopwatch]::StartNew()
  try {
   while ($true) {
    $read=$pipe.ReadAsync($buffer,0,$buffer.Length); $remaining=$timeout-[int]$clock.ElapsedMilliseconds
    if ($remaining -le 0 -or !$read.Wait($remaining)) { throw 'Controller timeout' }
    $count=$read.Result; if (!$count) { break }
    if ($stream.Length+$count -gt 2MB) { throw 'Controller response too large' }; $stream.Write($buffer,0,$count)
   }
   # Latin1 preserves bytes; chunk lengths count UTF-8 bytes, not .NET characters.
   $raw=[Text.Encoding]::GetEncoding(28591).GetString($stream.ToArray())
  } finally { $stream.Dispose() }
  $parts=$raw -split "`r`n`r`n",2
  if ($parts.Count -ne 2 -or $parts[0] -notmatch '^HTTP/1\.[01] 200(?:\s|$)') { throw 'Controller unavailable' }
  $body=$parts[1]
  if ($parts[0] -match '(?i)Transfer-Encoding:\s*chunked') {
   $decoded=[Text.StringBuilder]::new(); $offset=0
   while ($true) {
    $end=$body.IndexOf("`r`n",$offset); if ($end -lt 0) { throw 'Invalid controller response' }
    $length=[Convert]::ToInt32(($body.Substring($offset,$end-$offset) -split ';')[0],16)
    if (!$length) { break }; $offset=$end+2
    if ($length -lt 0 -or $offset+$length+2 -gt $body.Length) { throw 'Invalid controller response' }
    $null=$decoded.Append($body.Substring($offset,$length)); $offset+=$length+2
   }
   $body=$decoded.ToString()
  }
  return ([Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(28591).GetBytes($body)) | ConvertFrom-Json -ErrorAction Stop)
 } finally { $pipe.Dispose() }
}
function Get-IslandSystemProxy { Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop }
function Get-IslandHttpsProxy($settings) {
 if ($settings.ProxyEnable -ne 1 -or !$settings.ProxyServer) { return $null }
 $server=[string]$settings.ProxyServer
 if ($server -match '=') { $match=[regex]::Match($server,'(?:^|;)\s*https=([^;]+)'); if (!$match.Success) { return $null }; $server=$match.Groups[1].Value }
 if ($server -notmatch '^https?://') { $server='http://'+$server }
 $controller=New-IslandMihomoController $server
 if (!$controller) { return $null }
 foreach ($bypass in ([string]$settings.ProxyOverride -split ';')) { if ($bypass -and $bypass -ne '<local>' -and 'www.gstatic.com' -like $bypass.Trim()) { return $null } }
 return $controller.Address
}
function Get-IslandProbeRouteAliases {
 if (!$script:islandProbeAddresses -or ([datetime]::UtcNow-$script:islandProbeDnsAt).TotalSeconds -ge 30) {
  $task=[Net.Dns]::GetHostAddressesAsync('www.gstatic.com'); if (!$task.Wait(1000)) { throw 'Route unavailable' }
  $script:islandProbeAddresses=@($task.Result); $script:islandProbeDnsAt=[datetime]::UtcNow
 }
 $aliases=@()
 foreach ($address in $script:islandProbeAddresses) {
  # An IPv4-only machine may resolve AAAA records without any IPv6 route.
  try { $route=Find-NetRoute -RemoteIPAddress $address.IPAddressToString -ErrorAction Stop | Where-Object { $_.InterfaceAlias } | Select-Object -First 1 } catch { $route=$null }
  if ($route) { $aliases+=[string]$route.InterfaceAlias }
 }
 if (!$aliases.Count) { throw 'Route unavailable' }
 @($aliases | Select-Object -Unique)
}
function Invoke-IslandProxyProbe([string]$proxyAddress) {
 $handler=[Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect=$false; $handler.UseProxy=!!$proxyAddress
 if ($proxyAddress) { $handler.Proxy=[Net.WebProxy]::new($proxyAddress) }
 $http=[Net.Http.HttpClient]::new($handler); $http.Timeout=[timespan]::FromMilliseconds(1800)
 try {
  $response=$http.GetAsync('https://www.gstatic.com/generate_204',[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
  try { return [int]$response.StatusCode -eq 204 } finally { $response.Dispose() }
 } catch { return $false } finally { $http.Dispose(); $handler.Dispose() }
}
function New-IslandVpnResult([string]$status,[string]$text,$discovery,[bool]$enabled=$false,$reachable=$null,$delay=$null,[string]$mode='unknown',[string]$activeClient='') {
 # Output allowlist excludes controllers, secrets, config paths and command lines.
 [pscustomobject]@{Connected=$enabled;Delay=$delay;Color=(Get-VpnColor $enabled $delay);Text=$text;Status=$status;ClientRunning=([bool]$discovery -and @($discovery.Clients).Count -gt 0);Clients=@($discovery.Clients | Where-Object { $_ });ActiveClient=$activeClient;CoreRunning=($discovery.Cores -gt 0);ProxyEnabled=$enabled;Reachable=$reachable;Mode=$mode;Checked=[datetime]::Now}
}
function Get-IslandMihomoSelectedNode($controller,$runtime) {
 $proxies=(Invoke-IslandMihomo $controller '/proxies').proxies; $selected='GLOBAL'
 if ($runtime.mode -eq 'rule') { $rules=(Invoke-IslandMihomo $controller '/rules').rules; $match=$rules | Where-Object type -eq 'Match' | Select-Object -Last 1; if (!$match) { return $null }; $selected=$match.proxy }
 $visited=@{}
 for ($i=0;$i -lt 16;$i++) {
  if (!$selected -or $selected -in @('DIRECT','REJECT','REJECT-DROP','PASS') -or $visited.ContainsKey($selected)) { return $null }
  $visited[$selected]=$true; $node=$proxies.PSObject.Properties[$selected].Value
  if (!$node) { return $null }; if (!$node.now) { return [string]$selected }; $selected=[string]$node.now
 }
 return $null
}
function Measure-IslandVpnNode($state) {
 $selected=Get-IslandMihomoSelectedNode $state.Controller $state.Runtime; if (!$selected) { return $null }
 $name=[uri]::EscapeDataString($selected)
 $result=Invoke-IslandMihomo $state.Controller ("/proxies/$name/delay?timeout=2500&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204")
 if ($result.delay -gt 0) { return [double]$result.delay }; return $null
}
function Get-IslandVpnStatusCore([switch]$NoProbe) {
 try { $discovery=Get-IslandMihomoDiscovery } catch { return (New-IslandVpnResult 'unknown' 'VPN 状态未知 · 客户端发现不可用' $null) }
 if (!$discovery.Controllers.Count) {
  if ($discovery.Cores -gt 0) { return (New-IslandVpnResult 'unknown' 'VPN 状态未知 · Mihomo 控制接口不可用' $discovery) }
  if ($discovery.Clients.Count) { return (New-IslandVpnResult 'core_stopped' '代理客户端运行中 · 未检测到 Mihomo 核心' $discovery) }
  return (New-IslandVpnResult 'stopped' 'VPN 未连接 · 未检测到受支持客户端' $discovery)
 }
 $candidates=@(); $seen=@{}; $controllerBudget=[Diagnostics.Stopwatch]::StartNew()
 foreach ($controller in $discovery.Controllers) {
  if ($controllerBudget.ElapsedMilliseconds -gt 3000) { break }
  if ([datetime]::UtcNow -lt $controller.RetryAt) { continue }
  try {
   if (!$controller.Verified) {
    $version=Invoke-IslandMihomo $controller '/version'
    if ($version.meta -ne $true -and $version.version -notmatch '(?i)mihomo|clash\.meta') { $controller.RetryAt=[datetime]::UtcNow.AddSeconds(15); continue }
    $controller.Verified=$true
   }
   $runtime=Invoke-IslandMihomo $controller '/configs'
   $controller.Client=if($discovery.ClientById.ContainsKey([int]$controller.OwnerId)){$discovery.ClientById[[int]$controller.OwnerId]}else{'Mihomo'}
   if ($seen.ContainsKey($controller.Key)) { continue }; $seen[$controller.Key]=$true; $discovery.Cores=[math]::Max(1,$discovery.Cores)
   $candidates+=@([pscustomobject]@{Controller=$controller;Runtime=$runtime})
  } catch { $controller.RetryAt=[datetime]::UtcNow.AddSeconds($(if($controller.Verified){3}else{15})) }
 }
 if (!$candidates.Count) { return (New-IslandVpnResult 'unknown' 'VPN 状态未知 · Mihomo 控制接口不可用或认证失败' $discovery) }
 try { $proxy=Get-IslandSystemProxy } catch { return (New-IslandVpnResult 'unknown' 'VPN 状态未知 · 系统代理设置不可读' $discovery) }
 $proxyAddress=Get-IslandHttpsProxy $proxy; $active=@(); $mode='unknown'
 if ($proxyAddress) {
  $mode='system'; $port=([uri]$proxyAddress).Port
  $ownerIds=@(Get-IslandMihomoSocketOwners $proxyAddress $discovery.Listeners)
  $active=@($candidates | Where-Object { $runtime=$_.Runtime; $port -in @($runtime.'mixed-port',$runtime.port) -and $_.Controller.OwnerId -in $ownerIds })
 } elseif ($proxy.ProxyEnable -eq 1 -or $proxy.AutoConfigURL) { return (New-IslandVpnResult 'unknown' 'VPN 状态未知 · 系统代理或 PAC 无法归属到 Mihomo' $discovery) }
 else {
  $tunnels=@($candidates | Where-Object { $_.Runtime.tun.enable -eq $true })
  if ($tunnels.Count) {
   $knownOwners=@($candidates | ForEach-Object { $_.Controller.OwnerId } | Select-Object -Unique)
   if (@($discovery.CoreIds | Where-Object { $_ -notin $knownOwners }).Count) { return (New-IslandVpnResult 'unknown' 'VPN 状态未知 · 其他 Mihomo 核心的 TUN 状态不可确认' $discovery) }
   try { $aliases=@(Get-IslandProbeRouteAliases) } catch { return (New-IslandVpnResult 'unknown' 'VPN 状态未知 · TUN 路由不可确认' $discovery) }
   $mode='tun'; $active=@($tunnels | Where-Object { $_.Runtime.tun.device -and $aliases.Count -eq 1 -and $_.Runtime.tun.device -eq $aliases[0] })
  }
 }
 $active=@($active | Group-Object { if($_.Controller.OwnerId){'pid:'+ $_.Controller.OwnerId}else{$_.Controller.Key} } | ForEach-Object { $_.Group | Select-Object -First 1 })
 if ($active.Count -gt 1) { return (New-IslandVpnResult 'unknown' 'VPN 状态未知 · 多个 Mihomo 核心同时匹配生效链路' $discovery) }
 if (!$active.Count) {
  if ($mode -eq 'tun' -or $mode -eq 'system') { return (New-IslandVpnResult 'unknown' 'VPN 状态未知 · 无法唯一确认生效的 Mihomo 核心' $discovery) }
  return (New-IslandVpnResult 'disabled' 'Mihomo 核心运行中 · 代理未启用' $discovery)
 }
 $state=$active[0]
 if ($state.Runtime.mode -notin @('rule','global','direct')) { return (New-IslandVpnResult 'unknown' 'VPN 状态未知 · Mihomo 运行模式不可确认' $discovery) }
 if ($state.Runtime.mode -eq 'direct') { return (New-IslandVpnResult 'disabled' 'Mihomo 当前为直连模式' $discovery) }
 $reachable=$null; if (!$NoProbe) { $reachable=Invoke-IslandProxyProbe $proxyAddress }
 $key=$state.Controller.Key+'|'+$state.Controller.OwnerId+'|'+$mode+'|'+$state.Runtime.mode; $delay=$null
 if (!$NoProbe -and (!$script:islandVpnDelayAt -or $script:islandVpnDelayKey -ne $key -or ([datetime]::UtcNow-$script:islandVpnDelayAt).TotalSeconds -ge 15)) {
  $script:islandVpnDelayAt=[datetime]::UtcNow; $script:islandVpnDelayKey=$key; $script:islandVpnDelay=$null
  try { $script:islandVpnDelay=Measure-IslandVpnNode $state } catch {}
 }
 if ($script:islandVpnDelayKey -eq $key) { $delay=$script:islandVpnDelay }
 if ($reachable -eq $false) { return (New-IslandVpnResult 'unreachable' 'VPN 已启用 · 实际代理链路暂不可达' $discovery $true $false $null $mode $state.Controller.Client) }
 if ($NoProbe) { return (New-IslandVpnResult 'unknown' 'VPN 已启用 · 网络连通未验证' $discovery $true $null $null $mode $state.Controller.Client) }
 $text=if($null -eq $delay){'VPN 链路正常 · 节点测速超时或不可用'}else{"VPN 节点延迟 $delay ms"}
 return (New-IslandVpnResult 'connected' $text $discovery $true $true $delay $mode $state.Controller.Client)
}
function Get-IslandVpnStatus([switch]$NoProbe) {
 try { Get-IslandVpnStatusCore -NoProbe:$NoProbe }
 catch { New-IslandVpnResult 'unknown' 'VPN 状态未知 · 检测暂不可用' $null }
}
