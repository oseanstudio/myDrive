param([switch]$Run)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path (Split-Path $PSScriptRoot)
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if(!(Test-Path -LiteralPath $vswhere)){throw 'Install Visual Studio Build Tools with the Desktop development with C++ workload.'}
$vsPath=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(!$vsPath){throw 'The MSVC C++ build tools are missing.'}
$vcvars=Join-Path $vsPath 'VC/Auxiliary/Build/vcvars64.bat'
$output=Join-Path $projectRoot 'build/cloudfiles-spike'
New-Item -ItemType Directory -Force -Path $output|Out-Null
$source=Join-Path $PSScriptRoot 'spike.cpp'
$script=Join-Path $output 'compile.cmd'
@"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /MT /DUNICODE /D_UNICODE "$source" /Fo"$output\spike.obj" /Fe"$output\myDrive-cloudfiles-spike.exe" /link CldApi.lib
exit /b %errorlevel%
"@ | Set-Content -LiteralPath $script -Encoding ascii
& $env:ComSpec /d /c $script
if($LASTEXITCODE -ne 0){throw 'Cloud Files spike build failed.'}
if($Run){& (Join-Path $output 'myDrive-cloudfiles-spike.exe');if($LASTEXITCODE -ne 0){throw 'Cloud Files spike did not pass.'}}
