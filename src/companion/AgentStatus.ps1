# Read only lifecycle metadata. Never display conversation text or tool arguments.
function Read-SessionTail($path) {
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try {
  $offset=[math]::Max(0,$stream.Length-262144)
  $null=$stream.Seek($offset,[IO.SeekOrigin]::Begin)
  $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
  try {
   if ($offset -gt 0) { $null=$reader.ReadLine() }
   $reader.ReadToEnd() -split "`n" | Select-Object -Last 96
  } finally { $reader.Dispose() }
 } finally { $stream.Dispose() }
}
function Get-SessionState($lines, [datetimeoffset]$now = [datetimeoffset]::Now) {
 $state='unknown'; $stamp=$null
 foreach ($line in $lines) {
  # Read structural metadata without parsing potentially huge tool outputs.
  $types=[regex]::Matches($line,'"type"\s*:\s*"([^"\\]+)"')
  if ($types.Count -lt 2) { continue }
  $role=[regex]::Match($line,'"role"\s*:\s*"([^"\\]+)"').Groups[1].Value
  $phase=[regex]::Match($line,'"phase"\s*:\s*"([^"\\]+)"').Groups[1].Value
  $time=[regex]::Match($line,'"timestamp"\s*:\s*"([^"\\]+)"').Groups[1].Value
  $e=@{type=$types[0].Groups[1].Value;timestamp=$time;payload=@{type=$types[1].Groups[1].Value;role=$role;phase=$phase}}
  $next=$null
  if ($e.type -eq 'event_msg') {
   switch ($e.payload.type) {
    task_started { $next='thinking' }
    task_complete { $next='complete' }
    turn_aborted { $next='stopped' }
    task_aborted { $next='stopped' }
    task_failed { $next='error' }
    approval_request { $next='action' }
    request_user_input { $next='action' }
    waiting_for_input { $next='action' }
   }
  } elseif ($e.type -eq 'response_item') {
   if ($e.payload.type -in @('function_call','custom_tool_call')) {
    $toolName=[regex]::Match($line,'"name"\s*:\s*"([^"\\]+)"').Groups[1].Value
    if ($toolName -match '(^|[._])request_user_input(_async)?$') { $next='action' } else { $next='tool' }
   }
   elseif ($e.payload.type -in @('function_call_output','custom_tool_call_output','reasoning')) { $next='thinking' }
   elseif ($e.payload.type -eq 'message') {
    if ($e.payload.role -eq 'user') { $next='thinking' }
    elseif ($e.payload.role -eq 'assistant') {
     if ($e.payload.phase -in @('final','final_answer')) { $next='complete' } else { $next='thinking' }
    }
   }
  }
  if ($next) { $state=$next; try { $stamp=[datetimeoffset]::Parse($e.timestamp) } catch { $stamp=$null } }
 }
 if ($state -in @('thinking','tool') -and (!$stamp -or ($now-$stamp).TotalMinutes -gt 10)) { $state='unknown' }
 [pscustomobject]@{State=$state; Time=$stamp}
}
function Add-CodexSessionIdentity($state,$path) {
 if (!$script:sessionIdentities) { $script:sessionIdentities=@{} }
 if (!$script:sessionIdentities.ContainsKey($path)) {
  $id=$path
  try {
   $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
   $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
   try { $meta=$reader.ReadLine() | ConvertFrom-Json; if ($meta.type -eq 'session_meta' -and $meta.payload.id) { $id=[string]$meta.payload.id } } finally { $reader.Dispose() }
  } catch {}
  # Do not cache a partial header; retry on the next file write.
  if ($id -ne $path) { $script:sessionIdentities[$path]=$id }
 } else { $id=$script:sessionIdentities[$path] }
 $name=[IO.Path]::GetFileName($path)
 $generation=if ($name -match '^rollout-(\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d)-') { $matches[1] } else { '' }
 $state | Add-Member NoteProperty SessionId $id -Force
 $state | Add-Member NoteProperty Generation $generation -Force
 $state | Add-Member NoteProperty File $path -Force
 return $state
}
function Select-CodexSessions($states) {
 # Resumed chats create multiple rollout files with the same session_meta.id.
 # Only the newest generation owns that chat's current lifecycle state.
 $states | Group-Object { if ($_.SessionId) { $_.SessionId } else { $_.File } } | ForEach-Object {
  $_.Group | Sort-Object Generation,Time -Descending | Select-Object -First 1
 }
}
function Get-AgentPresentation($state) {
 switch ($state) {
  chat_thinking { @('正在思考','#57A6FF') }
  thinking { @('思考中','#FFD166') }
  action { @('需要操作','#FF626C') }
  tool { @('执行工具','#FFD166') }
  complete { @('已完成','#45D68A') }
  stopped { @('已停止','#AAAAB4') }
  error { @('任务异常','#FF9097') }
  unknown { @('状态待确认','#EBCB8B') }
  default { @('在线','#AAAAB4') }
 }
}
function Get-AgentLight($state) {
 # Three compact indicators: busy/unconfirmed, needs attention, available/finished.
 switch ($state) {
  chat_thinking { '#57A6FF' }
  { $_ -in @('thinking','tool','unknown') } { '#FFD166' }
  { $_ -in @('action','error') } { '#FF626C' }
  default { '#45D68A' }
 }
}
