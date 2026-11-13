$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'VpnStatus.ps1')
function Assert-Equal($actual,$expected,[string]$label) { if ($actual -ne $expected) { throw "$label : expected [$expected], got [$actual]" }; $script:checks++ }
$script:checks=0
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('Island-Mihomo-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
$originalInvoke=${function:Invoke-IslandMihomo}
$originalPaths=${function:Get-IslandMihomoConfigPaths}
function Process-Fixture($name,$id,$parent=0,$command='') {
 [pscustomobject]@{Name=$name;ProcessId=$id;ParentProcessId=$parent;CommandLine=$command;ExecutablePath=(Join-Path $fixture ('程序 Files\'+$name))}
}
function Reset-Fixture {
 $script:processes=@(); $script:listeners=@(); $script:runtimes=@{}; $script:controllerPorts=@{}
 $script:proxy=[pscustomobject]@{ProxyEnable=0;ProxyServer='';ProxyOverride='';AutoConfigURL=''}
 $script:routeAliases=@('Mihomo-Test'); $script:reachable=$true; $script:controllerFailure=$false; $script:delayFailure=$false
 $script:discoveryCalls=0; $script:probeCalls=0; $script:delayCalls=0; $script:islandMihomoDiscovery=$null; $script:islandVpnDelayAt=$null; $script:lastControllerOwner=0
}
function Add-ClientFixture($name,[int]$id,[int]$controlPort,[int]$proxyPort) {
 $directory=Join-Path $fixture ('用户 '+$id+'\安装 路径')
 $null=New-Item -ItemType Directory -Path $directory -Force
 $config=Join-Path $directory 'config.yaml'
 [IO.File]::WriteAllText($config,"external-controller: '127.0.0.1:$controlPort'`nsecret: 'fixture-secret # private'`n",[Text.UTF8Encoding]::new($false))
 $script:processes+=@(Process-Fixture $name $id)
 $script:processes+=@(Process-Fixture 'mihomo.exe' ($id+1) $id ('mihomo.exe -f "'+$config+'"'))
 $script:listeners+=@([pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=$controlPort;OwningProcess=$id+1},[pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=$proxyPort;OwningProcess=$id+1})
 $script:runtimes[$id+1]=[pscustomobject]@{mode='global';'mixed-port'=$proxyPort;port=0;tun=[pscustomobject]@{enable=$false;device='Mihomo-Test'}}
 $script:controllerPorts[$id+1]=$controlPort
}
# No real registry, installed-client config, process list, routes or Internet are read.
function Get-IslandMihomoProcesses { $script:discoveryCalls++; $script:processes }
function Get-IslandMihomoListeners { $script:listeners }
function Get-IslandMihomoConfigPaths($process,$processes) { $file=Get-IslandMihomoArgument $process.CommandLine '-f|--config'; if ($file) { $file } }
function Get-IslandSystemProxy { $script:proxy }
function Get-IslandProbeRouteAliases { $script:routeAliases }
function Invoke-IslandProxyProbe($proxyAddress) { $script:probeCalls++; $script:lastProxy=$proxyAddress; $script:reachable }
function Invoke-IslandMihomo($controller,$path) {
 if ($script:controllerFailure) { throw 'Fixture controller unavailable' }
 if (!$script:controllerPorts.ContainsKey([int]$controller.OwnerId) -or ([uri]$controller.Address).Port -ne $script:controllerPorts[[int]$controller.OwnerId] -or $controller.Secret -ne 'fixture-secret # private') { throw 'Fixture authentication failure' }
 $script:lastControllerOwner=$controller.OwnerId
 switch -Regex ($path) {
  '^/version$' { return [pscustomobject]@{meta=$true;version='Mihomo fixture'} }
  '^/configs$' { return $script:runtimes[[int]$controller.OwnerId] }
  '^/proxies$' { return [pscustomobject]@{proxies=[pscustomobject]@{GLOBAL=[pscustomobject]@{now='测试节点'};'测试节点'=[pscustomobject]@{type='Shadowsocks'}}} }
  '^/rules$' { return [pscustomobject]@{rules=@([pscustomobject]@{type='Match';proxy='GLOBAL'})} }
  '^/proxies/.+/delay\?' { $script:delayCalls++; if ($script:delayFailure) { throw 'Fixture timeout' }; return [pscustomobject]@{delay=42} }
 }
 throw 'Unexpected fixture request'
}
try {
 foreach ($case in @(@('clash-verge.exe','Clash Verge Rev'),@('CLASH-PARTY.exe','Clash Party'),@('mihomo-party.exe','Clash Party'),@('FlClash.exe','FlClash'),@('clash-nyanpasu.exe','Clash Nyanpasu'))) { Assert-Equal (Get-IslandMihomoClientName $case[0]) $case[1] 'Client name' }
 foreach ($name in 'xray.exe','sing-box.exe','v2rayN.exe','hiddify.exe') { Assert-Equal (Get-IslandMihomoClientName $name) $null 'Unsupported client' }
 Assert-Equal (Get-VpnColor $true 150) '#25A96A' 'Green threshold'
 Assert-Equal (Get-VpnColor $true 300) '#D7A82E' 'Yellow threshold'
 Assert-Equal (Get-VpnColor $true $null) '#E6505B' 'Unknown latency red'
 Assert-Equal (Get-VpnColor $false 42) $null 'Disabled color'
 Assert-Equal (New-IslandMihomoController '192.168.1.1:9090' 'fixture-secret') $null 'No remote credentials'
 Assert-Equal (New-IslandMihomoController 'http://user:password@localhost:9090') $null 'No URI credentials'
 Assert-Equal (New-IslandMihomoController '127.0.0.1:9090' "bad`r`nheader") $null 'Reject header injection'
 Assert-Equal ([uri](New-IslandMihomoController '[::]:19090').Address).IsLoopback $true 'IPv6 wildcard normalization'
 Assert-Equal (Get-IslandHttpsProxy ([pscustomobject]@{ProxyEnable=1;ProxyServer='http=localhost:80;https=localhost:23456'})) 'http://localhost:23456' 'HTTPS proxy mapping'
 Assert-Equal (Get-IslandHttpsProxy ([pscustomobject]@{ProxyEnable=1;ProxyServer='localhost:1234';ProxyOverride='*.gstatic.com'})) $null 'Probe bypass'
 $owners=@(Get-IslandMihomoSocketOwners 'http://127.0.0.1:22222' @([pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=22222;OwningProcess=1},[pscustomobject]@{LocalAddress='::1';LocalPort=22222;OwningProcess=2}))
 Assert-Equal $owners.Count 1 'Different IP families do not collide'
 Assert-Equal $owners[0] 1 'Exact loopback listener owns proxy'
 Reset-Fixture
 Assert-Equal (Get-IslandVpnStatus).Status 'stopped' 'No clients'
 $script:processes=@(Process-Fixture 'clash-verge.exe' 10); $script:islandMihomoDiscovery=$null
 Assert-Equal (Get-IslandVpnStatus).Status 'core_stopped' 'Client without core'
 $script:processes+=@(Process-Fixture 'mihomo.exe' 11 10); $script:islandMihomoDiscovery=$null
 Assert-Equal (Get-IslandVpnStatus).Status 'unknown' 'Core without controller'
 foreach ($name in 'clash-verge.exe','clash-party.exe','FlClash.exe','clash-nyanpasu.exe') {
  Reset-Fixture; Add-ClientFixture $name 20 19321 21321
  $script:proxy.ProxyEnable=1; $script:proxy.ProxyServer='127.0.0.1:21321'
  $result=Get-IslandVpnStatus
  Assert-Equal $result.Status 'connected' "$name system proxy"
  Assert-Equal $result.ActiveClient (Get-IslandMihomoClientName $name) 'Attributed client'
  Assert-Equal $result.Delay 42 'Node delay'
  Assert-Equal $result.Reachable $true 'Actual proxy probe'
  Assert-Equal $result.Mode 'system' 'System mode'
  Assert-Equal (($result | ConvertTo-Json -Depth 8 -Compress) -match 'fixture-secret|Authorization|安装|Controller') $false 'Sanitized bridge output'
  $null=Get-IslandVpnStatus; $null=Get-IslandVpnStatus
  Assert-Equal $script:discoveryCalls 1 'Discovery cached'
  Assert-Equal $script:delayCalls 1 'No repeated speed test'
  Assert-Equal $script:probeCalls 3 'Connectivity checked independently'
  $script:islandVpnDelayAt=[datetime]::UtcNow.AddSeconds(-16); $null=Get-IslandVpnStatus
  Assert-Equal $script:delayCalls 2 'Delay cache expires'
  $script:reachable=$false
  $result=Get-IslandVpnStatus
  Assert-Equal $result.Status 'unreachable' 'Core running but proxy down'
  Assert-Equal $result.CoreRunning $true 'Core separate from reachability'
  Assert-Equal $result.Color '#E6505B' 'Unreachable capsule red'
  $script:reachable=$true; $script:delayFailure=$true; $script:islandVpnDelayAt=$null
  $result=Get-IslandVpnStatus
  Assert-Equal $result.Status 'connected' 'Reachable despite node timeout'
  Assert-Equal $result.Delay $null 'Node timeout remains unknown'
  $script:controllerFailure=$true
  Assert-Equal (Get-IslandVpnStatus).Status 'unknown' 'Controller failure'
 }
 Reset-Fixture; Add-ClientFixture 'FlClash.exe' 30 19322 21322
 $script:runtimes[31].tun.enable=$true
 $result=Get-IslandVpnStatus
 Assert-Equal $result.Status 'connected' 'TUN enabled with matching route'
 Assert-Equal $result.Mode 'tun' 'TUN mode'
 Assert-Equal ([string]$script:lastProxy) '' 'TUN probe bypasses system proxy'
 $script:routeAliases=@('Ethernet')
 Assert-Equal (Get-IslandVpnStatus).Status 'unknown' 'TUN enabled without route proof'
 $script:routeAliases=@('Mihomo-Test','Ethernet')
 Assert-Equal (Get-IslandVpnStatus).Status 'unknown' 'Mixed IPv4/IPv6 routes'
 Reset-Fixture; Add-ClientFixture 'clash-party.exe' 40 19323 21323; Add-ClientFixture 'clash-verge.exe' 50 19324 21324
 $script:proxy.ProxyEnable=1; $script:proxy.ProxyServer='127.0.0.1:21324'
 $result=Get-IslandVpnStatus
 Assert-Equal $result.ActiveClient 'Clash Verge Rev' 'Multi-client actual listener wins'
 Assert-Equal $script:lastControllerOwner 51 'Probe uses selected core'
 $script:proxy.ProxyServer='127.0.0.1:21323'
 Assert-Equal (Get-IslandVpnStatus).ActiveClient 'Clash Party' 'Proxy switches independently of discovery order'
 $script:proxy.ProxyEnable=0; $script:runtimes[41].tun.enable=$true; $script:runtimes[51].tun.enable=$true
 Assert-Equal (Get-IslandVpnStatus).Status 'unknown' 'Two TUN cores ambiguous'
 $script:runtimes[41].tun.enable=$false; $script:runtimes[51].tun.enable=$false
 Assert-Equal (Get-IslandVpnStatus).Status 'disabled' 'Core without enabled proxy'
 $script:proxy.AutoConfigURL='http://localhost/pac'
 Assert-Equal (Get-IslandVpnStatus).Status 'unknown' 'PAC safely unknown'
 $script:proxy.AutoConfigURL=''; $script:proxy.ProxyEnable=1; $script:proxy.ProxyServer='127.0.0.1:21324'; $script:runtimes[51].mode='direct'
 Assert-Equal (Get-IslandVpnStatus).Status 'disabled' 'Direct mode'
 # Exercise the bridge's real persistent-runspace loading pattern. Caches must
 # survive Commands.Clear/BeginInvoke rather than being reconstructed per poll.
 Reset-Fixture; Add-ClientFixture 'clash-party.exe' 60 19325 21325
 $script:proxy.ProxyEnable=1; $script:proxy.ProxyServer='127.0.0.1:21325'
 $helpers=@('Get-IslandMihomoProcesses','Get-IslandMihomoListeners','Get-IslandMihomoConfigPaths','Get-IslandSystemProxy','Get-IslandProbeRouteAliases','Invoke-IslandProxyProbe','Invoke-IslandMihomo')
 $mockSource=($helpers | ForEach-Object { 'function '+$_+' {'+(Get-Item ('Function:'+$_)).ScriptBlock.ToString()+"}`n" }) -join "`n"
 $initial=@{processes=$script:processes;listeners=$script:listeners;runtimes=$script:runtimes;controllerPorts=$script:controllerPorts;proxy=$script:proxy;reachable=$true;controllerFailure=$false;delayFailure=$false;discoveryCalls=0;probeCalls=0;delayCalls=0}
 $worker=[PowerShell]::Create()
 try {
  $null=$worker.AddScript([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VpnStatus.ps1')),$false)
  $null=$worker.AddScript(('param($state); foreach($key in $state.Keys){Set-Variable -Name $key -Scope Script -Value $state[$key]};'+$mockSource),$false).AddArgument($initial)
  $null=$worker.Invoke()
  foreach ($iteration in 1..3) {
   $worker.Commands.Clear(); $null=$worker.AddScript('Get-IslandVpnStatus')
   $pending=$worker.BeginInvoke(); $result=@($worker.EndInvoke($pending)) | Select-Object -Last 1
   Assert-Equal $result.Status 'connected' 'Bridge asynchronous poll'
  }
  $worker.Commands.Clear(); $null=$worker.AddScript('[pscustomobject]@{Discoveries=$script:discoveryCalls;Delays=$script:delayCalls;Probes=$script:probeCalls}')
  $counters=@($worker.Invoke()) | Select-Object -Last 1
  Assert-Equal $counters.Discoveries 1 'Persistent discovery cache'
  Assert-Equal $counters.Delays 1 'Persistent delay cache'
  Assert-Equal $counters.Probes 3 'Independent connection checks'
 } finally { $worker.Dispose() }
 Set-Item Function:Invoke-IslandMihomo $originalInvoke
 Set-Item Function:Get-IslandMihomoConfigPaths $originalPaths
 'PASS: '+$script:checks+' assertions; four clients, system/TUN, multi-client attribution, failures, privacy and cache timing'
} finally {
 Set-Item Function:Invoke-IslandMihomo $originalInvoke
 Set-Item Function:Get-IslandMihomoConfigPaths $originalPaths
 $resolved=[IO.Path]::GetFullPath($fixture); $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
