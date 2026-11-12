param([switch]$Once,[switch]$SelfTest,[long]$WindowHandle=0,[string]$Provider='Gemini',[int]$Owner=0)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopAgentStatus.cs') -ReferencedAssemblies @('UIAutomationClient','UIAutomationTypes','WindowsBase')
if ($SelfTest) {
 foreach ($name in '停止','停止生成','停止回答','停止流式传输','Stop response','Stop generating','Stop streaming') {
  if (![IslandDesktopAgentReader]::IsStopButton($name)) { throw "Missing stop control: $name" }
 }
 foreach ($name in '停止朗读','Stop reading','停止分享','停止录音','a previous answer says Stop generating') {
  if ([IslandDesktopAgentReader]::IsStopButton($name)) { throw "False stop control: $name" }
 }
 if ([IslandDesktopAgentReader]::Classify($true,$true) -ne 'thinking' -or [IslandDesktopAgentReader]::Classify($false,$true) -ne 'ready' -or [IslandDesktopAgentReader]::Classify($false,$false) -ne 'unknown') { throw 'Control classifier failed' }
 foreach ($name in '询问 ChatGPT','Message ChatGPT','Ask anything') { if (![IslandDesktopAgentReader]::IsChatComposer($name)) { throw 'ChatGPT composer missing' } }
 foreach ($name in '使用 ChatGPT Work','Use ChatGPT Work','为 Gemini 输入提示') { if ([IslandDesktopAgentReader]::IsChatComposer($name)) { throw 'Work/Gemini mistaken for ordinary chat' } }
 if (![IslandDesktopAgentReader]::IsWorkComposer('使用 ChatGPT Work')) { throw 'Work composer missing' }
 if (![IslandDesktopAgentReader]::IsGenericComposer('prompt-textarea')) { throw 'Unnamed background composer missing' }
 if ([IslandDesktopAgentReader]::ResolveOpenAIMode($false,$false,'chat') -ne 'chat' -or [IslandDesktopAgentReader]::ResolveOpenAIMode($true,$true,'work') -ne 'work') { throw 'Hidden document lost its known mode' }
 if ([IslandDesktopAgentReader]::ResolveOpenAIMode($false,$false,'unknown') -ne 'unknown') { throw 'Unknown document invented a mode' }
 foreach ($case in @(@($true,$false,$true,$false,'chat_thinking'),@($true,$false,$false,$true,'complete'),@($false,$true,$true,$false,'thinking'),@($false,$true,$true,$true,'action'),@($false,$true,$false,$false,'complete'),@($false,$false,$true,$false,'unknown'),@($true,$true,$true,$false,'unknown'))) {
  if ([IslandDesktopAgentReader]::ClassifyOpenAI($case[0],$case[1],$case[2],$case[3]) -ne $case[4]) { throw 'OpenAI window mode classifier failed' }
 }
 if ([IslandDesktopAgentReader]::IsActionButton('更改权限') -or [IslandDesktopAgentReader]::IsActionButton('帮我批准')) { throw 'Permission settings mistaken for pending approval' }
 'PASS: Gemini control classifier, unrelated stop buttons, unavailable control fallback'
 exit
}
if ($WindowHandle) {
 [IslandDesktopAgentReader]::ReadWindow([intptr]$WindowHandle,$Provider) | ConvertTo-Json -Compress
 exit
}
$mutex=[Threading.Mutex]::new($false,'Local\DaozaiDesktopStatusMonitor')
if (!$mutex.WaitOne(0)) { $mutex.Dispose(); exit }
. (Join-Path $PSScriptRoot 'RuntimePaths.ps1')
$monitorData=Get-WorkPelletDataDirectory $PSScriptRoot
$path=Join-Path $monitorData 'desktop-agent-status.json'
$wasThinking=$false
try {
 do {
  try {
  if ($Owner -and !(Get-Process -Id $Owner -ErrorAction SilentlyContinue)) { break }
  $geminiProcesses=@(Get-Process -Name Gemini,GoogleGemini -ErrorAction SilentlyContinue)
  $geminiHandle=[IslandDesktopAgentReader]::FindDesktopWindow([int[]]@($geminiProcesses.Id))
  # MainWindowHandle becomes zero after close-to-tray. The remembered real
  # window, or a hidden top-level window found by enumeration, is still readable.
  if (!$geminiHandle -and $lastGeminiWindow -and [IslandDesktopAgentReader]::IsWindow($lastGeminiWindow) -and [IslandDesktopAgentReader]::WindowProcessId($lastGeminiWindow) -in @($geminiProcesses.Id)) { $geminiHandle=$lastGeminiWindow }
  $app=if ($geminiHandle) { $geminiProcesses | Where-Object Id -eq ([IslandDesktopAgentReader]::WindowProcessId($geminiHandle)) | Select-Object -First 1 } else { $null }
  $snapshot=$null; $state='unknown'; $source='Gemini 界面控件暂不可读'
  if ($app) {
   $lastGeminiWindow=$geminiHandle
   $snapshot=[IslandDesktopAgentReader]::ReadWindow($geminiHandle,'Gemini')
   $state=$snapshot.State
   if ($state -eq 'ready') { $state=if($wasThinking){'complete'}else{'online'} }
   if ($snapshot.HasStop) { $wasThinking=$true }
   $source='Gemini 实时窗口控件（含最小化和隐藏到后台的窗口）'
   if ($snapshot.State -eq 'unknown') { $source='Gemini 界面控件暂不可读；不会按进程占用推测思考状态' }
  } elseif (!$geminiProcesses.Count) { $wasThinking=$false; $lastGeminiWindow=[intptr]::Zero }
  $geminiWindowState=if ($geminiHandle -and [IslandDesktopAgentReader]::IsWindowVisible($geminiHandle) -and ![IslandDesktopAgentReader]::IsIconic($geminiHandle)) {'foreground'} else {'background'}
  $geminiRecord=@{State=$state;Time=[datetimeoffset]::Now.ToString('o');ProcessId=if($app){$app.Id}else{0};Present=($geminiProcesses.Count -gt 0);WindowHandle=$geminiHandle.ToInt64();WindowState=$geminiWindowState;Source=$source;Probe=@{Stop=($snapshot -and $snapshot.HasStop);Composer=($snapshot -and $snapshot.HasComposer);Controls=if($snapshot){$snapshot.ControlCount}else{0}}}
  $geminiSignature=([pscustomobject]$geminiRecord | Select-Object Present,WindowState,State,WindowHandle | ConvertTo-Json -Compress)
  if ($geminiSignature -ne $lastGeminiSignature) {
   $lastGeminiSignature=$geminiSignature
   [IO.File]::AppendAllText((Join-Path $monitorData 'gemini-transitions.jsonl'),(($geminiRecord | ConvertTo-Json -Depth 4 -Compress)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
  }
  $record=@{Gemini=$geminiRecord}
  $chatApps=@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
  $chat=$null; $chatSnapshot=$null; $chosen=[intptr]::Zero
  $foreground=[IslandDesktopAgentReader]::GetForegroundWindow()
  $foregroundId=[IslandDesktopAgentReader]::WindowProcessId($foreground)
  $focused=$chatApps | Where-Object Id -eq $foregroundId | Select-Object -First 1
  if ($focused) { $chosen=$foreground; $chat=$focused }
  elseif ($lastOpenAIWindow -and [IslandDesktopAgentReader]::IsWindow($lastOpenAIWindow)) {
   $windowId=[IslandDesktopAgentReader]::WindowProcessId($lastOpenAIWindow)
   $chat=$chatApps | Where-Object Id -eq $windowId | Select-Object -First 1
   if ($chat) { $chosen=$lastOpenAIWindow }
  }
  if (!$chat) { $chat=$chatApps | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1; if ($chat) { $chosen=$chat.MainWindowHandle } }
  if ($chat) {
   $chatSnapshot=[IslandDesktopAgentReader]::ReadWindow($chosen,'ChatGPT')
   if ($chatSnapshot.Mode -ne 'unknown') { $lastOpenAIWindow=$chosen }
  }
  $windowState=if ($chat -and [IslandDesktopAgentReader]::IsWindowVisible($chosen) -and ![IslandDesktopAgentReader]::IsIconic($chosen)) {'foreground'} else {'background'}
  $record.ChatGPT=@{Present=($null -ne $chat);WindowState=$windowState;Mode=if($chatSnapshot){$chatSnapshot.Mode}else{'none'};State=if($chatSnapshot){$chatSnapshot.State}else{'unknown'};WindowHandle=$chosen.ToInt64();Time=[datetimeoffset]::Now.ToString('o');ProcessId=if($chat){$chat.Id}else{0};Source='ChatGPT 窗口模式、后台窗口与生成/等待操作控件'}
  $record.ChatGPT.Probe=if ($chatSnapshot) { @{Controls=$chatSnapshot.ControlCount;Scope=$chatSnapshot.Scope;Stop=$chatSnapshot.HasStop;Chat=$chatSnapshot.HasComposer;Work=$chatSnapshot.HasWorkComposer;Generic=$chatSnapshot.HasGenericComposer;Unavailable=$chatSnapshot.Unavailable} } else { @{Processes=$chatApps.Count} }
  $probeSignature=([pscustomobject]$record.ChatGPT | Select-Object Present,WindowState,Mode,State,WindowHandle | ConvertTo-Json -Compress)
  if ($env:WORKPELLET_TRACE -eq '1' -and $probeSignature -ne $lastProbeSignature) {
   $lastProbeSignature=$probeSignature
   [IO.File]::AppendAllText((Join-Path $monitorData 'openai-transitions.jsonl'),(($record.ChatGPT | ConvertTo-Json -Depth 4 -Compress)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
  }
  $temp=$path+'.tmp'
  [IO.File]::WriteAllText($temp,($record | ConvertTo-Json -Depth 4 -Compress),[Text.UTF8Encoding]::new($false))
  if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp,$path,[System.Management.Automation.Language.NullString]::Value) } else { [IO.File]::Move($temp,$path) }
  } catch {
   if ($Once) { throw }
   if (!$lastErrorAt -or ([datetime]::Now-$lastErrorAt).TotalSeconds -ge 10) {
    [IO.File]::AppendAllText((Join-Path $monitorData 'desktop-error.log'),([datetimeoffset]::Now.ToString('o')+' '+$_.Exception.GetType().Name+': '+$_.Exception.Message+[Environment]::NewLine))
    $lastErrorAt=[datetime]::Now
   }
  }
  if (!$Once) { Start-Sleep -Milliseconds 100 }
 } while (!$Once)
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
