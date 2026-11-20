param([string]$Dotnet,[string]$CacheRoot)
$ErrorActionPreference='Stop'
if(!$Dotnet){$Dotnet=(Get-Command dotnet -ErrorAction Stop).Source}
if(!$CacheRoot){$CacheRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'myDrive/Build Cache'}
$testRoot=Join-Path $CacheRoot 'myDrive Service Tests'
$env:DOTNET_ROOT=Split-Path $Dotnet
& $Dotnet publish (Join-Path $PSScriptRoot 'service-cache/ServiceCache.csproj') -c Release "-p:BaseIntermediateOutputPath=$testRoot/obj/" "-p:BaseOutputPath=$testRoot/bin/" -o (Join-Path $testRoot 'run') --nologo
if($LASTEXITCODE){throw 'Connection-cache regression test build failed.'}
& (Join-Path $testRoot 'run/mydrive-core.exe') --test
if($LASTEXITCODE){throw 'Connection-cache regression tests failed.'}
