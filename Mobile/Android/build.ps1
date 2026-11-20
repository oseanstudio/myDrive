param([switch]$Tests, [string]$ToolsJson)
$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath $PSScriptRoot).Path
$dataRoot=$env:OSEAN_STUDIO_DATA
if(!$dataRoot){$config=Join-Path $env:LOCALAPPDATA 'OseanStudio\storage.json';if(Test-Path -LiteralPath $config){$dataRoot=(Get-Content -LiteralPath $config -Raw|ConvertFrom-Json).root}}
if(!$dataRoot){$dataRoot=Join-Path $env:LOCALAPPDATA 'OseanStudio'}
if(!$ToolsJson){$ToolsJson=Join-Path $dataRoot 'Toolchains\myDrive Mobile\tools.json'}
if(!(Test-Path -LiteralPath $ToolsJson)){throw 'Android tools are missing. Run Mobile/tools/prepare-android.ps1 first, or pass -ToolsJson.'}
$tools=Get-Content -LiteralPath $ToolsJson -Raw|ConvertFrom-Json
$cache=[IO.Path]::GetFullPath((Join-Path $dataRoot 'Build Cache\myDrive Mobile'))
$project=Join-Path $cache 'source\Android'
# A build copy on the cache drive avoids Android Gradle's cross-drive test-path error on Windows.
Get-ChildItem -LiteralPath $source -Recurse -File|Where-Object {$_.Name -notlike '._*' -and $_.FullName -notmatch '\\(\.gradle|build|screenshots)\\'}|ForEach-Object {
    $relative=$_.FullName.Substring($source.Length+1);$target=[IO.Path]::GetFullPath((Join-Path $project $relative))
    if(!$target.StartsWith($project+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Build target escaped cache directory'}
    New-Item -ItemType Directory -Path (Split-Path $target) -Force|Out-Null;Copy-Item -LiteralPath $_.FullName -Destination $target -Force
}
$env:JAVA_HOME=$tools.java;$env:ANDROID_HOME=$tools.sdk;$env:ANDROID_SDK_ROOT=$tools.sdk
$env:ANDROID_USER_HOME=Join-Path $cache 'android-user';$env:GRADLE_USER_HOME=Join-Path $cache 'gradle';$env:MYDRIVE_ANDROID_BUILD=Join-Path $cache 'android'
$tasks=@(':app:assembleDebug');if($Tests){$tasks+=':app:testDebugUnitTest'}
& $tools.gradle -p $project --project-cache-dir (Join-Path $cache 'project-cache') --no-daemon @tasks --console=plain
if($LASTEXITCODE -ne 0){throw 'Android build or checks failed.'}
$output=Join-Path $dataRoot 'Previews\myDrive Mobile'
New-Item -ItemType Directory -Path $output -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $env:MYDRIVE_ANDROID_BUILD 'outputs\apk\debug\app-debug.apk') -Destination (Join-Path $output 'myDrive-android-debug.apk') -Force
Write-Output (Join-Path $output 'myDrive-android-debug.apk')
