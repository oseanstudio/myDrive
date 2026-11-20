$ErrorActionPreference='Stop'
$app=Join-Path $PSScriptRoot 'build/windows/myDrive.exe'
if(!(Test-Path -LiteralPath $app)){& (Join-Path $PSScriptRoot 'build.ps1')}
Start-Process -FilePath $app -WorkingDirectory (Split-Path $app) -WindowStyle Normal
