param([Parameter(Mandatory=$true)][string]$PreparedRuntime)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$PreparedRuntime=(Resolve-Path -LiteralPath $PreparedRuntime).Path
$appStorageRoot=$env:OSEAN_STUDIO_DATA
if(!$appStorageRoot){
    $storageConfig=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OseanStudio/storage.json'
    if(Test-Path -LiteralPath $storageConfig){$appStorageRoot=(Get-Content -LiteralPath $storageConfig -Raw|ConvertFrom-Json).root}
}
if(!$appStorageRoot){$appStorageRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OseanStudio'}
$runtimeRoot=Join-Path $appStorageRoot 'Runtimes/myDrive Blip'
$runtimeLock=Get-Content -LiteralPath (Join-Path $projectRoot 'Blip/runtime-lock.json') -Raw|ConvertFrom-Json
foreach($property in $runtimeLock.files.PSObject.Properties){
    $file=Join-Path (Join-Path $PreparedRuntime 'blip') $property.Name
    if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $property.Value){throw "Unreviewed Blip runtime: $($property.Name)"}
}
New-Item -ItemType Directory -Path $runtimeRoot -Force|Out-Null
foreach($folder in @('blip',$runtimeLock.java.directory)){
    Copy-Item -LiteralPath (Join-Path $PreparedRuntime $folder) -Destination $runtimeRoot -Recurse -Force
}
$node=(Get-Command node -ErrorAction Stop).Source
Copy-Item -LiteralPath $node -Destination (Join-Path $runtimeRoot 'node.exe') -Force
$priorRuntime=$env:MYDRIVE_BLIP_RUNTIME
& (Join-Path $PSScriptRoot 'prepare-blip-support.ps1') -RuntimeRoot $runtimeRoot
try{
    $env:MYDRIVE_BLIP_RUNTIME=$runtimeRoot
    & $node (Join-Path $projectRoot 'Blip/cli.mjs') build
    if($LASTEXITCODE -ne 0){throw 'Blip bridge compilation failed.'}
    & $node (Join-Path $projectRoot 'Blip/cli.mjs') doctor
    if($LASTEXITCODE -ne 0){throw 'Blip runtime check failed.'}
}finally{$env:MYDRIVE_BLIP_RUNTIME=$priorRuntime}
Write-Output "Prepared myDrive Blip runtime at $runtimeRoot. No profile or account was copied or configured."
