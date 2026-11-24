param(
    [Parameter(Mandatory=$true)][string]$Executable,
    [string]$OutputDirectory,
    [string]$NsisCompiler
)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$version = [regex]::Match((Get-Content (Join-Path $project 'Cargo.toml') -Raw), '(?m)^version = "([0-9]+\.[0-9]+\.[0-9]+)"').Groups[1].Value
$binary = Get-Item -LiteralPath $Executable
if (!$version -or $binary.VersionInfo.FileVersion -notin @($version,"$version.0")) {
    throw '程序版本与安装包版本不一致'
}
if (!$OutputDirectory) { $OutputDirectory = Join-Path $project 'dist' }
if (!$NsisCompiler) {
    $compiler = Get-Command makensis.exe -ErrorAction SilentlyContinue
    $NsisCompiler = if ($compiler) { $compiler.Source } else { Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe' }
}
$compiler = (Get-Item -LiteralPath $NsisCompiler).FullName
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$setup = Join-Path $output "Windows-Island-Setup-v$version-windows-x64.exe"
& $compiler /V2 /WX "/DAPP_VERSION=$version" "/DPROJECT_DIR=$project" "/DSOURCE_EXE=$($binary.FullName)" "/DOUTPUT_FILE=$setup" (Join-Path $project 'installer\setup.nsi') | Out-Host
if ($LASTEXITCODE -ne 0) { throw '安装包编译失败' }
if ((Get-Item -LiteralPath $setup).VersionInfo.FileVersion -notin @($version,"$version.0")) {
    throw '安装包版本不正确'
}
Write-Output $setup
