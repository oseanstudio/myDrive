param([Parameter(Mandatory=$true)][string]$Share,[string]$Root='', [string]$Name='Studio PC', [string]$HostName, [int]$Port=445, [string]$Output)
$ErrorActionPreference='Stop'
if($Share -match '[\\/:\x00]' -or $Share -in @('.','..') -or $Root -match '(^|/)\.\.(/|$)|[\\:\x00]' -or $Port -lt 1 -or $Port -gt 65535){throw 'Use a valid share, relative start folder and port.'}
if(!$HostName){$tailscale=(Get-Command tailscale -ErrorAction Stop).Source;$status=& $tailscale status --json|ConvertFrom-Json;if($LASTEXITCODE -ne 0 -or $status.BackendState -ne 'Running'){throw 'Connect Tailscale or pass -HostName.'};$HostName=$status.Self.DNSName.TrimEnd('.')}
if($HostName -match '[/\\@?#\s]'){throw 'Enter only a hostname or IP address.'}
if(!$Output){$dataRoot=$env:OSEAN_STUDIO_DATA;if(!$dataRoot){$config=Join-Path $env:LOCALAPPDATA 'OseanStudio\storage.json';if(Test-Path -LiteralPath $config){$dataRoot=(Get-Content -LiteralPath $config -Raw|ConvertFrom-Json).root}};if(!$dataRoot){$dataRoot=Join-Path $env:LOCALAPPDATA 'OseanStudio'};$Output=Join-Path $dataRoot 'Previews\myDrive Mobile\connections.json'}
$file=[IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Path (Split-Path $file) -Force|Out-Null
@{version=1;devices=@(@{id=[guid]::NewGuid().ToString();name=$Name;host=$HostName;share=$Share;root=$Root;username='';domain='';port=$Port;encrypted=$false})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $file -Encoding utf8NoBOM
Write-Output $file
