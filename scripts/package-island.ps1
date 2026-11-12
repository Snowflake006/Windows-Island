param([string]$Executable,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
if(-not $Executable){$Executable=Join-Path $project 'target\release\daozai.exe'}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $project 'dist'}
$version=[regex]::Match((Get-Content (Join-Path $project 'Cargo.toml') -Raw),'(?m)^version = "([^"]+)"').Groups[1].Value
$binary=Get-Item -LiteralPath $Executable
if($binary.VersionInfo.FileVersion -notin @($version,"$version.0")){throw '程序版本与发布版本不一致'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
$name="Windows-Island-v$version-windows-x64"
$package=[IO.Path]::GetFullPath((Join-Path $output $name))
if(-not $package.StartsWith($output.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw '打包路径无效'}
New-Item -ItemType Directory -Path $package -Force | Out-Null
Copy-Item -LiteralPath $binary.FullName -Destination (Join-Path $package 'Windows Island.exe') -Force
foreach($file in @('LICENSE','THIRD_PARTY_NOTICES.txt')){Copy-Item -LiteralPath (Join-Path $project $file) -Destination $package -Force}
Copy-Item -LiteralPath (Join-Path $project 'docs\FEATURES.md') -Destination (Join-Path $package '功能说明.md') -Force
Copy-Item -LiteralPath (Join-Path $project 'docs\ACCOUNT.md') -Destination (Join-Path $package '账户使用说明.md') -Force
"Windows Island $version`r`n完整解压后运行 Windows Island.exe。`r`n设置 → 关于 → 检查更新 → 立即更新。`r`n本软件基于 Renly1994/xiaotang-daozai 二次开发，致敬原创。" | Set-Content -LiteralPath (Join-Path $package '使用说明.txt') -Encoding utf8
$archive=Join-Path $output "$name.zip"
Compress-Archive -LiteralPath $package -DestinationPath $archive -Force
$hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name.zip" | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Encoding ascii
Write-Output $archive
