function Get-WorkPelletDataDirectory {
 param([string]$ApplicationRoot=$PSScriptRoot)
 if ($env:WORKPELLET_DATA_DIR) { $directory=$env:WORKPELLET_DATA_DIR }
 elseif (Test-Path -LiteralPath (Join-Path $ApplicationRoot 'installed.flag')) {
  $directory=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WorkPellet'
 } else { $directory=Join-Path $ApplicationRoot 'data' }
 $null=New-Item -ItemType Directory -Force -Path $directory
 return $directory
}
