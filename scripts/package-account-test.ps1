param([string]$Executable)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
if (-not $Executable) { $Executable = Join-Path $project 'target\release\daozai.exe' }
$output = Join-Path $project 'dist\Windows-Island-account-test'
New-Item -ItemType Directory -Path $output -Force | Out-Null
Copy-Item -LiteralPath $Executable -Destination (Join-Path $output 'Windows Island.exe') -Force
foreach ($name in @('LICENSE', 'THIRD_PARTY_NOTICES.txt')) {
    Copy-Item -LiteralPath (Join-Path $project $name) -Destination $output -Force
}
Copy-Item -LiteralPath (Join-Path $project 'docs\ACCOUNT-TEST.md') -Destination (Join-Path $output '测试说明.md') -Force
$launcher = @'
@echo off
set "DAOZAI_DATA_DIR=%~dp0data"
start "" "%~dp0Windows Island.exe" --account
'@
[IO.File]::WriteAllText((Join-Path $output '打开账户设置.cmd'), $launcher.Replace("`n", "`r`n") + "`r`n", [Text.Encoding]::ASCII)
Get-Item -LiteralPath (Join-Path $output 'Windows Island.exe') | Select-Object FullName, Length, LastWriteTime
