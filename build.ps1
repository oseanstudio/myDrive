param([switch]$Run,[switch]$SkipTests,[string]$Go = 'go')
$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot

# Per-machine build tools and caches must stay outside the synced project.
$appStorageRoot = $env:OSEAN_STUDIO_DATA
if (!$appStorageRoot) {
    $storageConfig = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OseanStudio/storage.json'
    if (Test-Path -LiteralPath $storageConfig) { $appStorageRoot = (Get-Content -LiteralPath $storageConfig -Raw | ConvertFrom-Json).root }
}
if (!$appStorageRoot) { $appStorageRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OseanStudio' }

$env:CARGO_TARGET_DIR=Join-Path $appStorageRoot 'Build Cache/myDrive Core'
$env:CARGO_INCREMENTAL='0'
$dotnetLocal = Join-Path $appStorageRoot 'Toolchains/myDrive/dotnet/dotnet.exe'
$dotnet = if(Test-Path -LiteralPath $dotnetLocal){$dotnetLocal}else{(Get-Command dotnet -ErrorAction Stop).Source}
$cargoLocal = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cargo/bin/cargo.exe'
$cargo = if(Test-Path -LiteralPath $cargoLocal){$cargoLocal}else{(Get-Command cargo -ErrorAction Stop).Source}
function Check-NativeExit([string]$step){if($LASTEXITCODE -ne 0){throw "$step failed (exit $LASTEXITCODE)."}}
Push-Location $projectRoot
try {
    & './Windows/create-icon.ps1'
    if(!$SkipTests){& $cargo test --locked --manifest-path 'Core/Cargo.toml';Check-NativeExit 'Core tests'; & './tests/service-cache.ps1' -Dotnet $dotnet -CacheRoot (Join-Path $appStorageRoot 'Build Cache')}
    & $cargo build --release --locked --manifest-path 'Core/Cargo.toml';Check-NativeExit 'Core build'
    $windowsCache=Join-Path $appStorageRoot 'Build Cache/myDrive Windows'
    & $dotnet publish 'Windows/App/myDrive.csproj' -c Release -p:Platform=x64 "-p:BaseIntermediateOutputPath=$windowsCache/obj/" "-p:BaseOutputPath=$windowsCache/bin/" -o 'build/windows' --nologo;Check-NativeExit 'Windows app build'
    Copy-Item -LiteralPath (Join-Path $env:CARGO_TARGET_DIR 'release/mydrive-core.exe') -Destination 'build/windows/mydrive-core.exe' -Force
    Copy-Item -LiteralPath 'build/windows/mydrive-core.exe' -Destination 'build/windows/mydrive-cli.exe' -Force
    $windowsBuild=(Resolve-Path 'build/windows').Path
    & ./Windows/packaging/collect-notices.ps1 -AssetsFile (Join-Path $windowsCache 'obj/project.assets.json') -PublishDirectory $windowsBuild
    node Core/third-party-notices.mjs Core/Cargo.toml (Join-Path $windowsBuild 'ThirdPartyNotices.txt') $cargo
    Check-NativeExit 'Rust dependency notices'
    Push-Location 'Core/SmbHost'
    try {
        if(!$SkipTests){& $Go run build.go --test;Check-NativeExit 'Private SMB host tests'}
        & $Go run build.go $windowsBuild;Check-NativeExit 'Private SMB host build'
    } finally {Pop-Location}
    Write-Host "Built myDrive: $(Join-Path $projectRoot 'build/windows/myDrive.exe')"
    if($Run){Start-Process -FilePath (Join-Path $projectRoot 'build/windows/myDrive.exe') -WorkingDirectory (Join-Path $projectRoot 'build/windows') -WindowStyle Normal}
} finally {Pop-Location}
