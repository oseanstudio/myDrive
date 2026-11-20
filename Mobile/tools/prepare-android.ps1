param([string]$ToolRoot)
$ErrorActionPreference='Stop'
if(!$ToolRoot){
    $dataRoot=$env:OSEAN_STUDIO_DATA
    if(!$dataRoot){$config=Join-Path $env:LOCALAPPDATA 'OseanStudio\storage.json';if(Test-Path -LiteralPath $config){$dataRoot=(Get-Content -LiteralPath $config -Raw|ConvertFrom-Json).root}}
    if(!$dataRoot){$dataRoot=Join-Path $env:LOCALAPPDATA 'OseanStudio'}
    $ToolRoot=Join-Path $dataRoot 'Toolchains\myDrive Mobile'
}
$root=[IO.Path]::GetFullPath($ToolRoot)
New-Item -ItemType Directory -Path $root -Force|Out-Null
function Fetch($url,$name,$hash,$algorithm='SHA256'){
    $target=Join-Path $root $name
    if(!(Test-Path -LiteralPath $target)){Invoke-WebRequest -Uri $url -OutFile $target -TimeoutSec 300}
    if((Get-FileHash -LiteralPath $target -Algorithm $algorithm).Hash -ne $hash){throw "Download checksum mismatch: $name"}
    return $target
}
$asset=(Invoke-RestMethod -Uri 'https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=x64&image_type=jdk&os=windows')[0].binary.package
$jdk=Fetch $asset.link $asset.name $asset.checksum
$jdkDirectory=Join-Path $root ([IO.Path]::GetFileNameWithoutExtension($asset.name))
if(!(Test-Path -LiteralPath $jdkDirectory)){New-Item -ItemType Directory -Path $jdkDirectory -Force|Out-Null;Expand-Archive -LiteralPath $jdk -DestinationPath $jdkDirectory}
$env:JAVA_HOME=(Get-ChildItem -LiteralPath $jdkDirectory -Directory -Filter 'jdk-*'|Select-Object -First 1).FullName
if(!$env:JAVA_HOME){throw 'The JDK archive did not contain a JDK directory.'}
$gradleHash='20f1b1176237254a6fc204d8434196fa11a4cfb387567519c61556e8710aed78'
$gradle=Fetch 'https://services.gradle.org/distributions/gradle-8.13-bin.zip' 'gradle-8.13.zip' $gradleHash
if(!(Test-Path -LiteralPath (Join-Path $root 'gradle-8.13'))){Expand-Archive -LiteralPath $gradle -DestinationPath $root}
[xml]$repo=(Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/repository2-3.xml').Content
$package=$repo.SelectSingleNode("//*[local-name()='remotePackage' and @path='cmdline-tools;latest']")
$archive=@($package.archives.archive)|Where-Object {$_.'host-os' -eq 'windows'}|Select-Object -First 1
if(!$archive){throw 'Official Windows SDK archive missing.'}
$sdkZip=Fetch ('https://dl.google.com/android/repository/'+$archive.complete.url) $archive.complete.url $archive.complete.checksum.InnerText 'SHA1'
$sdk=Join-Path $root 'android-sdk'
if(!(Test-Path -LiteralPath (Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'))){
    $unpack=Join-Path $root ('command-tools-unpack-'+[guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $sdkZip -DestinationPath $unpack
    New-Item -ItemType Directory -Path (Join-Path $sdk 'cmdline-tools') -Force|Out-Null
    $from=(Resolve-Path -LiteralPath (Join-Path $unpack 'cmdline-tools')).Path
    $to=[IO.Path]::GetFullPath((Join-Path $sdk 'cmdline-tools\latest'))
    if(!$from.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or !$to.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Tool directory escaped its root.'}
    Move-Item -LiteralPath $from -Destination $to
}
$env:ANDROID_SDK_ROOT=$sdk
$cli=Join-Path $sdk 'cmdline-tools\latest\bin\android.exe'
if(Test-Path -LiteralPath $cli){
    # New Android CLI uses slash-separated package IDs and accepts one package per call.
    foreach($packageName in @('platform-tools','platforms/android-36','build-tools/35.0.0')){
        & $cli sdk --sdk $sdk install $packageName
        if($LASTEXITCODE -ne 0){throw "Android SDK package install failed: $packageName"}
    }
}else{
    $manager=Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
    & $manager --sdk_root=$sdk 'platform-tools' 'platforms;android-36' 'build-tools;35.0.0'
    if($LASTEXITCODE -ne 0){throw 'Android SDK install failed. Review any requested SDK licenses.'}
}
@{java=$env:JAVA_HOME;gradle=(Join-Path $root 'gradle-8.13\bin\gradle.bat');sdk=$sdk;jdkHash=$asset.checksum;gradleHash=$gradleHash;toolsHash=$archive.complete.checksum.InnerText}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'tools.json')
Write-Output (Join-Path $root 'tools.json')
