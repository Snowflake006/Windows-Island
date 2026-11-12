$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'AgentStatus.ps1')
$now=[datetimeoffset]::Now
function Event($type,$payload) { @{timestamp=$now.ToString('o');type=$type;payload=$payload} | ConvertTo-Json -Compress }
$start=Event 'event_msg' @{type='task_started'}
$tool=Event 'response_item' @{type='custom_tool_call';name='exec'}
$output=Event 'response_item' @{type='custom_tool_call_output'}
$final=Event 'response_item' @{type='message';role='assistant';phase='final_answer'}
$end=Event 'event_msg' @{type='task_complete'}
$abort=Event 'event_msg' @{type='turn_aborted'}
$needsInput=Event 'response_item' @{type='function_call';name='request_user_input'}
$approval=Event 'event_msg' @{type='approval_request'}
$cases=@(
 @{Lines=@($start);Expected='thinking'},
 @{Lines=@($start,$tool);Expected='tool'},
 @{Lines=@($start,$tool,$output);Expected='thinking'},
 @{Lines=@($start,$tool,$output,$final,$end);Expected='complete'},
 @{Lines=@($start,$abort);Expected='stopped'},
 @{Lines=@($start,$needsInput);Expected='action'},
 @{Lines=@($start,$approval);Expected='action'},
 @{Lines=@($start,$needsInput,$output);Expected='thinking'},
 @{Lines=@('{invalid');Expected='unknown'}
)
foreach ($case in $cases) {
 $actual=Get-SessionState $case.Lines $now
 if ($actual.State -ne $case.Expected) { throw "Expected $($case.Expected), got $($actual.State)" }
}
if ((Get-SessionState @($start) ($now.AddMinutes(11))).State -ne 'unknown') { throw 'Stale running session must not remain active' }
$sameChat=@(
 [pscustomobject]@{SessionId='chat-a';Generation='2026-11-11T10-00-00';State='thinking';Time=$now;File='old'},
 [pscustomobject]@{SessionId='chat-a';Generation='2026-11-11T11-00-00';State='complete';Time=$now;File='new'},
 [pscustomobject]@{SessionId='chat-b';Generation='2026-11-11T11-00-00';State='tool';Time=$now;File='other'}
)
$dedup=@(Select-CodexSessions $sameChat)
if ($dedup.Count -ne 2 -or ($dedup | Where-Object SessionId -eq 'chat-a').State -ne 'complete') { throw 'Resumed chat must not multiply active sessions' }
foreach ($item in @(@('thinking','#FFD166'),@('action','#FF626C'),@('complete','#45D68A'))) {
 if ((Get-AgentPresentation $item[0])[1] -ne $item[1]) { throw "Wrong status light: $($item[0])" }
}
'PASS: lifecycle, tool execution, completion, interruption, malformed logs, stale sessions'

foreach ($state in 'thinking','tool','unknown','action','error','complete','stopped','online') {
 $expected=if($state -in @('thinking','tool','unknown')){'#FFD166'}elseif($state -in @('action','error')){'#FF626C'}else{'#45D68A'}
 if ((Get-AgentLight $state) -ne $expected) { throw "Unexpected compact light: $state" }
}
'PASS: compact three-color status lights'
