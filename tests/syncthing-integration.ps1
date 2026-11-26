param(
    [string]$Syncthing = (Join-Path $env:APPDATA 'SyncTrayzor/syncthing.exe'),
    [string]$Core = (Join-Path $PSScriptRoot '../build/windows/mydrive-core.exe')
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot
$testStorageRoot=if($env:OSEAN_STUDIO_DATA){Join-Path $env:OSEAN_STUDIO_DATA 'Validation/myDrive'}else{Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'myDrive/Validation'}
$testRoot=Join-Path $testStorageRoot ('syncthing-test-'+[Guid]::NewGuid().ToString('N'))
$testHome=Join-Path $testRoot 'daemon'
$peerHome=Join-Path $testRoot 'peer'
New-Item -ItemType Directory -Force -Path $testHome,$peerHome|Out-Null
$checks=[System.Collections.Generic.List[string]]::new()
$daemon=$null
$peerDaemon=$null
$peerBase=$null
$peerHeaders=$null
$testHeaders=$null
$testBase=$null
function Assert-That([bool]$condition,[string]$label){if(!$condition){throw "Failed: $label"};$checks.Add($label)}
function Test-Api([string]$verb,[string]$resource,$body=$null){$arguments=@{Uri="$testBase/rest/$resource";Method=$verb;Headers=$testHeaders;TimeoutSec=12};if($null -ne $body){$arguments.Body=ConvertTo-Json -InputObject $body -Depth 40 -Compress;$arguments.ContentType='application/json'};Invoke-RestMethod @arguments}
function Peer-Api([string]$verb,[string]$resource,$body=$null){$arguments=@{Uri="$peerBase/rest/$resource";Method=$verb;Headers=$peerHeaders;TimeoutSec=12};if($null -ne $body){$arguments.Body=ConvertTo-Json -InputObject $body -Depth 40 -Compress;$arguments.ContentType='application/json'};Invoke-RestMethod @arguments}
function Free-Port {$listener=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop();return $port}
function Wait-Until([scriptblock]$test,[string]$label){for($i=0;$i -lt 150;$i++){try{if(&$test){$checks.Add($label);return}}catch{};Start-Sleep -Milliseconds 200};throw "Timed out: $label"}
function Core-Call([string]$action,$payload=@{},[switch]$ExpectError){
    $start=[System.Diagnostics.ProcessStartInfo]::new($Core);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[System.Diagnostics.Process]::new();$process.StartInfo=$start;$process.Start()|Out-Null
    try {
        $request=@{action="syncthing.$action";syncthing=@{endpoint=$testBase;api_key=$testHeaders['X-API-Key']};payload=$payload;data_dir=(Join-Path $testRoot 'mydrive-data')}
        $process.StandardInput.Write((ConvertTo-Json -InputObject $request -Depth 40 -Compress));$process.StandardInput.Close()
        $output=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd();$process.WaitForExit()
        if($process.ExitCode -ne 0){throw 'Core process failed'}
        $response=$output|ConvertFrom-Json
        if($ExpectError){if($response.ok){throw 'Expected the operation to be rejected'};return $response.error}
        if(!$response.ok){throw $response.error};return $response.data
    }finally{$process.Dispose()}
}
try {
    if(!(Test-Path -LiteralPath $Syncthing)){throw 'Supply the existing Syncthing executable path.'}
    if(!(Test-Path -LiteralPath $Core)){throw 'Build myDrive first, or supply -Core with a built core executable.'}
    & $Syncthing generate --home $testHome --no-port-probing 2>&1|Out-Null
    if($LASTEXITCODE -ne 0){throw 'Test daemon configuration generation failed'}
    & $Syncthing generate --home $peerHome --no-port-probing 2>&1|Out-Null
    if($LASTEXITCODE -ne 0){throw 'Test peer identity generation failed'}
    $testPeerId=(& $Syncthing device-id --home $peerHome).Trim()
    [xml]$fixtureConfig=Get-Content -LiteralPath (Join-Path $testHome 'config.xml') -Raw
    # Generated defaults can refer to ~/Sync. Remove them before ever starting this daemon.
    @($fixtureConfig.configuration.SelectNodes('folder'))|ForEach-Object{if($_){$fixtureConfig.configuration.RemoveChild($_)|Out-Null}}
    foreach($name in @('globalAnnounceEnabled','localAnnounceEnabled','relaysEnabled','natEnabled','startBrowser','crashReportingEnabled')){
        $element=$fixtureConfig.configuration.options.SelectSingleNode($name);if(!$element){$element=$fixtureConfig.CreateElement($name);$fixtureConfig.configuration.options.AppendChild($element)|Out-Null};$element.InnerText='false'
    }
    $fixtureConfig.configuration.options.autoUpgradeIntervalH='0'
    @($fixtureConfig.configuration.options.SelectNodes('listenAddress'))|ForEach-Object{if($_){$fixtureConfig.configuration.options.RemoveChild($_)|Out-Null}}
    $syncPort=Free-Port
    $listen=$fixtureConfig.CreateElement('listenAddress');$listen.InnerText="tcp://127.0.0.1:$syncPort";$fixtureConfig.configuration.options.AppendChild($listen)|Out-Null
    $listener=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
    $testBase="http://127.0.0.1:$port"
    $fixtureConfig.configuration.gui.address="127.0.0.1:$port"
    $fixtureConfig.Save((Join-Path $testHome 'config.xml'))
    $testHeaders=@{'X-API-Key'=[string]$fixtureConfig.configuration.gui.apikey}
    $daemon=Start-Process -FilePath $Syncthing -ArgumentList "serve --home `"$testHome`" --gui-address=$testBase --no-browser --no-restart" -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testRoot 'daemon.stdout.log') -RedirectStandardError (Join-Path $testRoot 'daemon.stderr.log')
    $ready=$false;for($attempt=0;$attempt -lt 60;$attempt++){try{Test-Api GET 'system/ping'|Out-Null;$ready=$true;break}catch{Start-Sleep -Milliseconds 200}}
    Assert-That $ready 'isolated daemon started'
    $peer=Test-Api GET 'config/defaults/device';$peer.deviceID=$testPeerId;$peer.name='myDrive test peer';$peer.addresses=@('tcp://127.0.0.1:1');Test-Api POST 'config/devices' $peer|Out-Null
    $source=Join-Path $testRoot 'source-project';New-Item -ItemType Directory -Force -Path $source,(Join-Path $source '.tools'),(Join-Path $source 'nested')|Out-Null
    Set-Content -LiteralPath (Join-Path $source 'README.txt') -Value 'keep this file'
    Set-Content -LiteralPath (Join-Path $source '.tools/cache.bin') -Value 'excluded generated cache'
    Set-Content -LiteralPath (Join-Path $source 'nested/a[1].txt') -Value 'literal bracket name'
    Set-Content -LiteralPath (Join-Path $source 'nested/other.txt') -Value 'sibling stays excluded'
    $preview=Core-Call 'share.preview' @{local_path=$source;device_id=$testPeerId;skip_build=$true}
    Assert-That ($preview.created -and !$preview.offered) 'sharing preview is read only'
    $result=Core-Call 'share' @{local_path=$source;device_id=$testPeerId;skip_build=$true}
    $folderId=$result.folder_id
    $folder=Test-Api GET "config/folders/$folderId"
    Assert-That (!$folder.paused -and @($folder.devices|Where-Object deviceID -eq $testPeerId).Count -eq 1) 'one-click sharing adds selected peer and starts folder'
    $originalIgnores=(Core-Call 'ignores' @{folder_id=$folderId}).ignore
    Assert-That (@($originalIgnores|Where-Object{$_ -eq '/.tools'}).Count -eq 1) 'generated SDK/cache exclusions installed before start'
    Test-Api POST "db/scan?folder=$folderId"|Out-Null
    $browse=Core-Call 'browse' @{folder_id=$folderId;path=''}
    Assert-That (@($browse.entries|Where-Object name -eq 'README.txt').Count -eq 1) 'folder browser shows local files'
    Assert-That (@($browse.entries|Where-Object name -eq '.tools').Count -eq 1) 'folder browser includes locally excluded folders'
    $stopRules=@(@{path='README.txt';sync=$false;is_dir=$false})
    $stopped=Core-Call 'selection.apply' @{folder_id=$folderId;expected_ignore=@($originalIgnores);rules=$stopRules}
    Test-Api POST "db/scan?folder=$folderId"|Out-Null
    $file=Test-Api GET "db/file?folder=$folderId&file=README.txt"
    Assert-That ([bool]$file.local.ignored) 'one-click Stop is honored by Syncthing'
    Assert-That ((Get-Content -LiteralPath (Join-Path $source 'README.txt') -Raw).Trim() -eq 'keep this file') 'Stop keeps the local file contents'
    $startRules=@(@{path='README.txt';sync=$true;is_dir=$false})
    $started=Core-Call 'selection.apply' @{folder_id=$folderId;expected_ignore=@($stopped.ignore);rules=$startRules}
    Test-Api POST "db/scan?folder=$folderId"|Out-Null
    $file=Test-Api GET "db/file?folder=$folderId&file=README.txt"
    Assert-That (!$file.local.ignored) 'one-click Sync resumes an excluded file'
    Assert-That (@($started.ignore|Where-Object{$_ -eq '/.tools'}).Count -eq 1) 'selection changes preserve existing rules'
    $nestedRules=@(@{path='nested';sync=$false;is_dir=$true},@{path='nested/a[1].txt';sync=$true;is_dir=$false})
    $nested=Core-Call 'selection.apply' @{folder_id=$folderId;expected_ignore=@($started.ignore);rules=$nestedRules}
    Test-Api POST "db/scan?folder=$folderId"|Out-Null
    $included=Test-Api GET "db/file?folder=$folderId&file=nested%2Fa%5B1%5D.txt";$excluded=Test-Api GET "db/file?folder=$folderId&file=nested%2Fother.txt"
    Assert-That (!$included.local.ignored -and $excluded.local.ignored) 'literal names and child overrides work with real Syncthing'
    $stale=Core-Call 'selection.apply' @{folder_id=$folderId;expected_ignore=@($originalIgnores);rules=@()} -ExpectError
    Assert-That ($stale -match 'changed') 'stale ignore edits are rejected'
    Core-Call 'pause' @{folder_id=$folderId;paused=$true}|Out-Null
    Assert-That ([bool](Test-Api GET "config/folders/$folderId").paused) 'Pause works'
    Core-Call 'pause' @{folder_id=$folderId;paused=$false}|Out-Null
    Assert-That (!(Test-Api GET "config/folders/$folderId").paused) 'Resume works'
    Core-Call 'share' @{local_path=$source;device_id=$testPeerId;skip_build=$true}|Out-Null
    $folder=Test-Api GET "config/folders/$folderId"
    Assert-That (@($folder.devices|Where-Object deviceID -eq $testPeerId).Count -eq 1) 'repeated Start does not duplicate devices or reset rules'
    $snapshot=Core-Call 'snapshot'
    Assert-That (@($snapshot.folders).Count -eq 1) 'native dashboard status API works'
    Assert-That ($folder.maxConflicts -eq -1 -and $folder.versioning.type -eq 'simple' -and $folder.versioning.params.keep -eq '20') 'new shares preserve alternative edits and twenty received versions'
    # A second independent daemon exercises actual transfers and offline divergent edits.
    [xml]$peerConfig=Get-Content -LiteralPath (Join-Path $peerHome 'config.xml') -Raw
    @($peerConfig.configuration.SelectNodes('folder'))|ForEach-Object{if($_){$peerConfig.configuration.RemoveChild($_)|Out-Null}}
    foreach($name in @('globalAnnounceEnabled','localAnnounceEnabled','relaysEnabled','natEnabled','startBrowser','crashReportingEnabled')){$element=$peerConfig.configuration.options.SelectSingleNode($name);if(!$element){$element=$peerConfig.CreateElement($name);$peerConfig.configuration.options.AppendChild($element)|Out-Null};$element.InnerText='false'}
    $peerConfig.configuration.options.autoUpgradeIntervalH='0'
    @($peerConfig.configuration.options.SelectNodes('listenAddress'))|ForEach-Object{if($_){$peerConfig.configuration.options.RemoveChild($_)|Out-Null}}
    $peerSyncPort=Free-Port;$peerGuiPort=Free-Port
    $listen=$peerConfig.CreateElement('listenAddress');$listen.InnerText="tcp://127.0.0.1:$peerSyncPort";$peerConfig.configuration.options.AppendChild($listen)|Out-Null
    $peerBase="http://127.0.0.1:$peerGuiPort";$peerConfig.configuration.gui.address="127.0.0.1:$peerGuiPort";$peerConfig.Save((Join-Path $peerHome 'config.xml'));$peerHeaders=@{'X-API-Key'=[string]$peerConfig.configuration.gui.apikey}
    $peerDaemon=Start-Process -FilePath $Syncthing -ArgumentList "serve --home `"$peerHome`" --gui-address=$peerBase --no-browser --no-restart" -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testRoot 'peer.stdout.log') -RedirectStandardError (Join-Path $testRoot 'peer.stderr.log')
    Wait-Until { $null -ne (Peer-Api GET 'system/ping') } 'second isolated daemon started'
    $firstId=(Test-Api GET 'system/status').myID
    $device=Peer-Api GET 'config/defaults/device';$device.deviceID=$firstId;$device.name='myDrive fixture one';$device.addresses=@("tcp://127.0.0.1:$syncPort");Peer-Api POST 'config/devices' $device|Out-Null
    Test-Api PATCH "config/devices/$testPeerId" @{addresses=@("tcp://127.0.0.1:$peerSyncPort")}|Out-Null
    $receiver=Join-Path $testRoot 'receiver';New-Item -ItemType Directory -Path $receiver|Out-Null
    $remoteFolder=Peer-Api GET 'config/defaults/folder';$remoteFolder.id=$folderId;$remoteFolder.label='myDrive fixture';$remoteFolder.path=$receiver;$remoteFolder.devices=@(@{deviceID=$firstId;encryptionPassword='';introducedBy=''},@{deviceID=$testPeerId;encryptionPassword='';introducedBy=''});$remoteFolder.maxConflicts=-1;$remoteFolder.versioning=@{type='simple';params=@{keep='20';cleanoutDays='0'};cleanupIntervalS=3600;fsPath='';fsType='basic'}
    Peer-Api POST 'config/folders' $remoteFolder|Out-Null
    Assert-That (@((Test-Api GET "config/folders/$folderId").devices|Where-Object{([string]$_.encryptionPassword).Length -gt 0}).Count -eq 0) 'source sharing has no unexpected encryption password'
    Assert-That (@((Peer-Api GET "config/folders/$folderId").devices|Where-Object{([string]$_.encryptionPassword).Length -gt 0}).Count -eq 0) 'destination sharing has no unexpected encryption password'
    $sourceFile=Join-Path $source 'README.txt';$receiverFile=Join-Path $receiver 'README.txt'
    Wait-Until {(Test-Path -LiteralPath $receiverFile) -and (Get-Content -LiteralPath $receiverFile -Raw).Trim() -eq 'keep this file'} 'a real file transfers between isolated devices'
    $beforeStop=(Core-Call 'ignores' @{folder_id=$folderId}).ignore
    $networkStop=Core-Call 'selection.apply' @{folder_id=$folderId;expected_ignore=@($beforeStop);rules=@($nestedRules)+@(@{path='README.txt';sync=$false;is_dir=$false})}
    Test-Api POST "db/scan?folder=$folderId"|Out-Null
    Set-Content -LiteralPath $receiverFile -Value 'an update while the first device has stopped syncing this file'
    Peer-Api POST "db/scan?folder=$folderId"|Out-Null
    $newSize=(Get-Item -LiteralPath $receiverFile).Length
    Wait-Until {$state=Test-Api GET "db/file?folder=$folderId&file=README.txt";$state.global.size -eq $newSize -and $state.local.ignored} 'excluded file receives index updates without downloading contents'
    Assert-That ((Get-Content -LiteralPath $sourceFile -Raw).Trim() -eq 'keep this file') 'Stop prevents an incoming peer edit from replacing the local file'
    Core-Call 'selection.apply' @{folder_id=$folderId;expected_ignore=@($networkStop.ignore);rules=@($nestedRules)+@(@{path='README.txt';sync=$true;is_dir=$false})}|Out-Null
    Test-Api POST "db/scan?folder=$folderId"|Out-Null
    Wait-Until {(Get-Content -LiteralPath $sourceFile -Raw).Trim() -eq 'an update while the first device has stopped syncing this file'} 'Sync downloads the peer edit after re-enabling the file'
    Test-Api PATCH "config/devices/$testPeerId" @{paused=$true}|Out-Null
    Wait-Until {!((Test-Api GET 'system/connections').connections.$testPeerId.connected)} 'devices can go offline without removing files'
    Set-Content -LiteralPath $sourceFile -Value 'offline edit from first device'
    Set-Content -LiteralPath $receiverFile -Value 'independent offline edit from second device'
    (Get-Item -LiteralPath $sourceFile).LastWriteTimeUtc=[DateTime]::UtcNow.AddSeconds(-3)
    Test-Api POST "db/scan?folder=$folderId"|Out-Null;Peer-Api POST "db/scan?folder=$folderId"|Out-Null
    Assert-That ((Get-Content -LiteralPath $sourceFile -Raw).Trim() -eq 'offline edit from first device' -and (Get-Content -LiteralPath $receiverFile -Raw).Trim() -eq 'independent offline edit from second device') 'each offline device keeps its own saved edits'
    Test-Api PATCH "config/devices/$testPeerId" @{paused=$false}|Out-Null
    Wait-Until {$files=@(Get-ChildItem -LiteralPath $source -File|Where-Object{$_.Name -eq 'README.txt' -or $_.Name -like 'README.sync-conflict-*'});$contents=@($files|ForEach-Object{(Get-Content -LiteralPath $_.FullName -Raw).Trim()});$contents -contains 'offline edit from first device' -and $contents -contains 'independent offline edit from second device'} 'reconnecting preserves both divergent offline edits'
    Wait-Until {$files=@(Get-ChildItem -LiteralPath $receiver -File|Where-Object{$_.Name -eq 'README.txt' -or $_.Name -like 'README.sync-conflict-*'});$contents=@($files|ForEach-Object{(Get-Content -LiteralPath $_.FullName -Raw).Trim()});$contents -contains 'offline edit from first device' -and $contents -contains 'independent offline edit from second device'} 'alternative edits also reach the other device'
    $conflictBrowse=Core-Call 'browse' @{folder_id=$folderId;path=''}
    Assert-That (@($conflictBrowse.entries|Where-Object alternative_for -eq 'README.txt').Count -ge 1) 'native UI groups conflicts as saved alternative edits'
    Wait-Until {(Test-Api GET "db/status?folder=$folderId").state -eq 'idle' -and (Peer-Api GET "db/status?folder=$folderId").state -eq 'idle'} 'both devices finish reconciling'
    $beforeIncoming=(Get-Content -LiteralPath $sourceFile -Raw).Trim()
    Set-Content -LiteralPath $receiverFile -Value 'a newer ordinary save from the second device, after reconciliation'
    Peer-Api POST "db/scan?folder=$folderId"|Out-Null
    Wait-Until {(Get-Content -LiteralPath $sourceFile -Raw).Trim() -eq 'a newer ordinary save from the second device, after reconciliation'} 'ordinary saves sync automatically after reconnect'
    $versions=Core-Call 'versions' @{folder_id=$folderId}
    Assert-That (@($versions.'README.txt').Count -ge 1) 'received overwrite is retained in version history'
    $chosen=@($versions.'README.txt'|Sort-Object versionTime -Descending)[0]
    $restore=Core-Call 'restore' @{folder_id=$folderId;path='README.txt';version_time=$chosen.versionTime}
    Assert-That ((Get-Content -LiteralPath $restore.backup -Raw).Trim() -eq 'a newer ordinary save from the second device, after reconciliation') 'restore protects the current file in a separate backup'
    Assert-That ((Get-Content -LiteralPath $sourceFile -Raw).Trim() -eq $beforeIncoming) 'saved version restores successfully'
    $oldVersioning=Test-Api GET "config/folders/$folderId"
    Core-Call 'protect' @{folder_id=$folderId}|Out-Null
    Assert-That ((Test-Api GET "config/folders/$folderId").versioning.type -eq $oldVersioning.versioning.type) 'protect history preserves an existing versioning policy'
    $beforeDemand = Core-Call 'browse' @{folder_id=$folderId;path=''}
    $cold = Core-Call 'selection.mode' @{folder_id=$folderId;expected_ignore=@($beforeDemand.ignore);on_demand=$true}
    Assert-That ($cold.on_demand -and (Test-Path -LiteralPath $sourceFile)) 'download mode preserves existing local copies'
    $onlineDir = Join-Path $receiver 'online-fixture'
    New-Item -ItemType Directory -Path $onlineDir | Out-Null
    Set-Content -LiteralPath (Join-Path $onlineDir 'open.txt') -Value 'download this on open'
    Set-Content -LiteralPath (Join-Path $onlineDir 'pin.txt') -Value 'keep this offline'
    Set-Content -LiteralPath (Join-Path $onlineDir 'untouched.txt') -Value 'keep this online'
    Peer-Api POST "db/scan?folder=$folderId" | Out-Null
    Wait-Until {
        $browse = Core-Call 'browse' @{folder_id=$folderId;path='online-fixture'}
        $browse.on_demand -and @($browse.entries | Where-Object {$_.remote -and !$_.local}).Count -eq 3
    } 'on-demand mode lists remote nested files without downloading them'
    $target = Join-Path $source 'online-fixture/open.txt'
    Core-Call 'local_file' @{folder_id=$folderId;path='online-fixture/open.txt';wait_seconds=6} | Out-Null
    Wait-Until { (Test-Path -LiteralPath $target) -and (Get-Content -LiteralPath $target -Raw).Trim() -eq 'download this on open' } 'opening a cloud-only file hydrates it'
    $state = Core-Call 'browse' @{folder_id=$folderId;path='online-fixture'}
    $pin = @{path='online-fixture/pin.txt';sync=$true;is_dir=$false}
    Core-Call 'selection.apply' @{folder_id=$folderId;expected_ignore=@($state.ignore);rules=@($state.rules)+@($pin)} | Out-Null
    $pinned = Join-Path $source 'online-fixture/pin.txt'
    Wait-Until { (Test-Path -LiteralPath $pinned) -and (Get-Content -LiteralPath $pinned -Raw).Trim() -eq 'keep this offline' } 'pin downloads the selected file'
    $stillOnline = Join-Path $source 'online-fixture/untouched.txt'
    Assert-That (!(Test-Path -LiteralPath $stillOnline)) 'unselected sibling stays online after other files hydrate'
    $state = Core-Call 'browse' @{folder_id=$folderId;path='online-fixture'}
    Assert-That (@($state.entries | Where-Object {$_.pinned -and $_.local}).Count -eq 2) 'browse identifies both offline files'
    Test-Api PATCH "config/devices/$testPeerId" @{paused=$true} | Out-Null
    Wait-Until {!((Test-Api GET 'system/connections').connections.$testPeerId.connected)} 'on-demand test peer is offline'
    $offline = Core-Call 'local_file' @{folder_id=$folderId;path='online-fixture/pin.txt'}
    Assert-That (!$offline.pending -and (Test-Path -LiteralPath $offline.path)) 'a downloaded pin opens with the peer offline'
    Test-Api PATCH "config/devices/$testPeerId" @{paused=$false} | Out-Null
    $state = Core-Call 'browse' @{folder_id=$folderId;path='online-fixture'}
    $unpin = @{path='online-fixture/pin.txt';sync=$false;is_dir=$false}
    $rules = @($state.rules | Where-Object path -ne $unpin.path) + @($unpin)
    $selection = Core-Call 'selection.apply' @{folder_id=$folderId;expected_ignore=@($state.ignore);rules=$rules}
    Assert-That ($selection.on_demand -and (Test-Path -LiteralPath $pinned)) 'unpin preserves the downloaded file and the folder mode'
    Core-Call 'selection.mode' @{folder_id=$folderId;expected_ignore=@($selection.ignore);on_demand=$false} | Out-Null
    Wait-Until {Test-Path -LiteralPath $stillOnline} 'resuming default sync downloads the unselected sibling'
    $staleStop=Core-Call 'stop' @{folder_id=$folderId;expected_path=(Join-Path $testRoot 'wrong-folder')} -ExpectError
    Assert-That ($staleStop -match 'changed' -and (Test-Api GET "config/folders/$folderId").id -eq $folderId) 'Stop rejects a stale folder path without removing its configuration'
    $otherRoot=Join-Path $testRoot 'unrelated';New-Item -ItemType Directory -Path $otherRoot|Out-Null
    $other=Test-Api GET 'config/defaults/folder';$other.id='unrelated-fixture';$other.path=$otherRoot;$other.label='Unrelated fixture';$other.devices=@(@{deviceID=$firstId;encryptionPassword=''})
    Test-Api POST 'config/folders' $other|Out-Null
    Core-Call 'pause' @{folder_id=$folderId;paused=$true}|Out-Null;Peer-Api PATCH "config/folders/$folderId" @{paused=$true}|Out-Null
    $localHash=(Get-FileHash -LiteralPath $sourceFile).Hash;$peerHash=(Get-FileHash -LiteralPath $receiverFile).Hash
    $historyFiles=@(Get-ChildItem -LiteralPath (Join-Path $source '.stversions') -Recurse -File -Force|ForEach-Object{$_.FullName})
    $expectedPath=(Test-Api GET "config/folders/$folderId").path
    $stopped=Core-Call 'stop' @{folder_id=$folderId;expected_path=$expectedPath}
    $remaining=Test-Api GET 'config/folders'
    Assert-That ($stopped.stopped -and @($remaining|Where-Object id -eq $folderId).Count -eq 0) 'Stop removes the selected local folder from Syncthing'
    Assert-That (@($remaining|Where-Object id -eq 'unrelated-fixture').Count -eq 1) 'Stop leaves unrelated synced folders configured'
    Assert-That ((Get-FileHash -LiteralPath $sourceFile).Hash -eq $localHash -and (Get-FileHash -LiteralPath $receiverFile).Hash -eq $peerHash) 'Stop preserves existing file contents on both devices'
    Assert-That ((Peer-Api GET "config/folders/$folderId").id -eq $folderId) 'Stop does not remove the other device folder configuration'
    Assert-That (@($historyFiles|Where-Object{!(Test-Path -LiteralPath $_)}).Count -eq 0) 'Stop preserves archived version files'
    $savedStop=Get-Content -LiteralPath $stopped.backup -Raw|ConvertFrom-Json
    Assert-That ($savedStop.folder.id -eq $folderId -and $savedStop.encryption_credentials_omitted -and @($savedStop.folder.devices|Where-Object{$_.PSObject.Properties.Name -contains 'encryptionPassword'}).Count -eq 0) 'Stop saves a durable configuration backup without encryption credentials'
    $report=@{result='pass';checks=$checks;count=$checks.Count;syncthingVersion=$snapshot.version;fixture=$testRoot}
    $report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $testRoot 'report.json')
    Write-Output "PASS: $($checks.Count) real Syncthing integration checks. Report: $testRoot\report.json"
}catch{
    @{result='fail';checks=$checks;error=$_.Exception.Message}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $testRoot 'report.json')
    throw
}finally{
    if($peerDaemon){try{Peer-Api POST 'system/shutdown'|Out-Null}catch{};if(!$peerDaemon.WaitForExit(5000)){Stop-Process -Id $peerDaemon.Id -ErrorAction SilentlyContinue};$peerDaemon.Dispose()}
    if($daemon){try{Test-Api POST 'system/shutdown'|Out-Null}catch{};if(!$daemon.WaitForExit(5000)){Stop-Process -Id $daemon.Id -ErrorAction SilentlyContinue};$daemon.Dispose()}
}
