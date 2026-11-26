param(
    [Parameter(Mandatory=$true)][string]$AssetsFile,
    [Parameter(Mandatory=$true)][string]$PublishDirectory
)
$ErrorActionPreference = 'Stop'
$assets = Get-Content -LiteralPath $AssetsFile -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$deps = Get-Content -LiteralPath (Join-Path $PublishDirectory 'myDrive.deps.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100

# The self-contained .NET runtime pack is resolved at restore time and appears
# in the published dependency manifest separately from PackageReference items.
$runtimePacks = @($deps.libraries.Keys | Where-Object { $_ -match '^runtimepack\.Microsoft\.NETCore\.App\.Runtime\.' })
if($runtimePacks.Count -ne 1) { throw 'Could not identify the .NET runtime being redistributed.' }

$packages = @{}
foreach ($key in $assets.libraries.Keys) {
    $library = $assets.libraries[$key]
    if ($library.type -eq 'package' -and $library.path) { $packages[$key] = $library.path }
}
foreach ($runtime in $runtimePacks) {
    $name = $runtime.Substring('runtimepack.'.Length)
    $packages[$name] = $name.ToLowerInvariant()
}

$included = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$notices = [Text.StringBuilder]::new()
[void]$notices.AppendLine('myDrive Windows runtime and dependency notices')
foreach($package in ($packages.Keys | Sort-Object)) {
    foreach($folder in $assets.packageFolders.Keys) {
        $directory = Join-Path $folder $packages[$package]
        if (!(Test-Path -LiteralPath $directory -PathType Container)) { continue }
        $licenseFiles = Get-ChildItem -LiteralPath $directory -File |
            Where-Object { $_.Name -match '^(licen[sc]e|copying|notice|copyright|third[-_ ]?party[-_ ]?notices?)(?:\.(txt|md|rtf))?$' } |
            Sort-Object Name
        foreach($file in $licenseFiles) {
            [void]$notices.AppendLine()
            [void]$notices.AppendLine("===== $package - $($file.Name) =====")
            [void]$notices.AppendLine((Get-Content -LiteralPath $file.FullName -Raw))
            [void]$included.Add($package)
        }
        break
    }
}

if (!($included | Where-Object { $_ -match '^Microsoft\.NETCore\.App\.Runtime\.' }) -or
    !($included | Where-Object { $_ -match '^Microsoft\.WindowsAppSDK\.WinUI/' })) {
    throw 'The .NET and WinUI license notices are required in the Windows installer.'
}
[void]$notices.AppendLine()
[void]$notices.AppendLine('===== ZXing.Net/0.16.11 - upstream COPYING =====')
[void]$notices.AppendLine('Copyright 2008 ZXing authors and ZXing.Net contributors')
[void]$notices.AppendLine((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ZXing.Net-COPYING.txt') -Raw))
$output = Join-Path $PublishDirectory 'Windows-ThirdPartyNotices.txt'
[IO.File]::WriteAllText($output, $notices.ToString())
