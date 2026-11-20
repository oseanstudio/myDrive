param([string]$RuntimeRoot)
$ErrorActionPreference='Stop'
if(!$RuntimeRoot){
    $storage=$env:OSEAN_STUDIO_DATA
    if(!$storage){$config=Join-Path $env:LOCALAPPDATA 'OseanStudio\storage.json';if(Test-Path -LiteralPath $config){$storage=(Get-Content -LiteralPath $config -Raw|ConvertFrom-Json).root}}
    if(!$storage){$storage=Join-Path $env:LOCALAPPDATA 'OseanStudio'}
    $RuntimeRoot=Join-Path $storage 'Runtimes\myDrive Blip'
}
$root=[IO.Path]::GetFullPath($RuntimeRoot)
$support=Join-Path $root 'support'
$lock=Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'Blip\runtime-lock.json') -Raw|ConvertFrom-Json
New-Item -ItemType Directory -Path $support -Force|Out-Null
foreach($entry in $lock.support_files.PSObject.Properties){
    if($entry.Name -ne [IO.Path]::GetFileName($entry.Name)){throw 'Support dependency must be a filename.'}
    $target=Join-Path $support $entry.Name
    if(!(Test-Path -LiteralPath $target)){
        $temporary=Join-Path $support ('download-'+[guid]::NewGuid().ToString('N'))
        Invoke-WebRequest -Uri $entry.Value.url -OutFile $temporary -TimeoutSec 90
        if((Get-FileHash -LiteralPath $temporary).Hash.ToLowerInvariant() -ne $entry.Value.sha256){throw 'Support dependency checksum mismatch; download was not installed.'}
        # Both resolved paths are confined to the explicit runtime support directory.
        if(![IO.Path]::GetFullPath($temporary).StartsWith($support+'\',[StringComparison]::OrdinalIgnoreCase) -or ![IO.Path]::GetFullPath($target).StartsWith($support+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Dependency target escaped support directory.'}
        Move-Item -LiteralPath $temporary -Destination $target
    }
    if((Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -ne $entry.Value.sha256){throw 'Installed support dependency checksum mismatch.'}
    Write-Output "Verified $($entry.Name)"
}
