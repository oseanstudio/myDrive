param([string]$Syncthing=(Join-Path $env:APPDATA 'SyncTrayzor/syncthing.exe'),[Parameter(Mandatory)][string]$Core,[Parameter(Mandatory)][string]$Scratch)
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetFullPath($Scratch)) ('nested-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force|Out-Null
$nodes=[Collections.Generic.List[object]]::new();$checks=[Collections.Generic.List[string]]::new()
function Check($condition,$name){if(!$condition){throw "Failed: $name"};$checks.Add($name)}
function Port{$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop();$port}
function Api($node,$method,$resource,$body=$null){$apiArguments=@{Uri=$node.base+'/rest/'+$resource;Method=$method;Headers=@{'X-API-Key'=$node.key};TimeoutSec=10};if($null -ne $body){$apiArguments.Body=ConvertTo-Json -InputObject $body -Depth 50 -Compress;$apiArguments.ContentType='application/json'};Invoke-RestMethod @apiArguments}
function Until($test,$name){for($i=0;$i -lt 180;$i++){try{if(&$test){$checks.Add($name);return}}catch{};Start-Sleep -Milliseconds 200};throw "Timed out: $name"}
function Start-Node($name){
    $fixtureHome=Join-Path $root $name;New-Item -ItemType Directory -Path $fixtureHome|Out-Null
    & $Syncthing generate --home $fixtureHome --no-port-probing *> (Join-Path $fixtureHome 'generate.log');if($LASTEXITCODE -ne 0){throw 'Fixture generation failed'}
    [xml]$config=Get-Content -LiteralPath (Join-Path $fixtureHome 'config.xml') -Raw
    @($config.configuration.SelectNodes('folder'))|ForEach-Object{$config.configuration.RemoveChild($_)|Out-Null}
    foreach($name in @('globalAnnounceEnabled','localAnnounceEnabled','relaysEnabled','natEnabled','startBrowser','crashReportingEnabled')){
        $element=$config.configuration.options.SelectSingleNode($name);if(!$element){$element=$config.CreateElement($name);$config.configuration.options.AppendChild($element)|Out-Null};$element.InnerText='false'
    }
    $config.configuration.options.autoUpgradeIntervalH='0'
    @($config.configuration.options.SelectNodes('listenAddress'))|ForEach-Object{$config.configuration.options.RemoveChild($_)|Out-Null}
    $sync=Port;$element=$config.CreateElement('listenAddress');$element.InnerText="tcp://127.0.0.1:$sync";$config.configuration.options.AppendChild($element)|Out-Null
    $gui=Port;$config.configuration.gui.address="127.0.0.1:$gui";$config.Save((Join-Path $fixtureHome 'config.xml'))
    $id=(& $Syncthing device-id --home $fixtureHome).Trim()
    $process=Start-Process -FilePath $Syncthing -ArgumentList "serve --home `"$fixtureHome`" --no-browser --no-restart" -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $fixtureHome 'stdout.log') -RedirectStandardError (Join-Path $fixtureHome 'stderr.log')
    $node=@{home=$fixtureHome;base="http://127.0.0.1:$gui";sync=$sync;key=[string]$config.configuration.gui.apikey;id=$id;process=$process}
    $nodes.Add($node);Until {((Api $node GET 'system/ping').ping -eq 'pong')} 'isolated daemon ready';return $node
}
function Connect($from,$to){$device=Api $from GET 'config/defaults/device';$device.deviceID=$to.id;$device.name='Fixture peer';$device.addresses=@("tcp://127.0.0.1:$($to.sync)");$device.introducer=$false;$device.autoAcceptFolders=$false;Api $from POST 'config/devices' $device|Out-Null}
function Call-Core($node,$action,$payload,[switch]$Reject){
    $info=[Diagnostics.ProcessStartInfo]::new($Core);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $p=[Diagnostics.Process]::Start($info)
    try{$request=@{action="syncthing.$action";syncthing=@{endpoint=$node.base;api_key=$node.key};payload=$payload;data_dir=(Join-Path $root 'mydrive')};$p.StandardInput.Write((ConvertTo-Json -InputObject $request -Depth 50 -Compress));$p.StandardInput.Close();$output=$p.StandardOutput.ReadToEnd();$stderr=$p.StandardError.ReadToEnd();$p.WaitForExit();if($p.ExitCode -ne 0){throw 'Core fixture process failed'};$result=$output|ConvertFrom-Json;if($Reject){Check (!$result.ok) 'overlap rejected before mutation';return $result.error};if(!$result.ok){throw $result.error};return $result.data}finally{$p.Dispose()}
}
function Accept($node,$id,$path,$other){$folder=Api $node GET 'config/defaults/folder';$folder.id=$id;$folder.label='Fixture share';$folder.path=$path;$folder.devices=@(@{deviceID=$node.id;encryptionPassword=''},@{deviceID=$other.id;encryptionPassword=''});Api $node POST 'config/folders' $folder|Out-Null}
function Scan($node,$id){Api $node POST "db/scan?folder=$id"|Out-Null}
function Text-Is($path,$value){(Test-Path -LiteralPath $path) -and (Get-Content -LiteralPath $path -Raw).Trim() -eq $value}
try {
    $hub=Start-Node 'hub';$laptop=Start-Node 'laptop';$desktop=Start-Node 'desktop'
    Connect $hub $laptop;Connect $laptop $hub;Connect $hub $desktop;Connect $desktop $hub
    $parent=Join-Path $root 'github';$child=Join-Path $parent 'project';$laptopRoot=Join-Path $root 'laptop-files';$desktopRoot=Join-Path $root 'desktop-files'
    New-Item -ItemType Directory -Path $child,$laptopRoot,$desktopRoot -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $parent 'other-project.txt') 'parent-only'
    Set-Content -LiteralPath (Join-Path $child 'hello.txt') 'initial'
    $parentShare=Call-Core $hub share @{local_path=$parent;device_id=$laptop.id;skip_build=$true}
    Accept $laptop $parentShare.folder_id $laptopRoot $hub
    $before=Api $hub GET "config/folders/$($parentShare.folder_id)"|ConvertTo-Json -Depth 50 -Compress
    $ignoreBefore=Api $hub GET "db/ignores?folder=$($parentShare.folder_id)"|ConvertTo-Json -Depth 50 -Compress
    $preview=Call-Core $hub share.preview @{local_path=$child;device_id=$desktop.id;skip_build=$true}
    Check ($preview.nested -and $preview.created -and !$preview.offered) 'subfolder preview identifies nesting without sharing'
    $childShare=Call-Core $hub share @{local_path=$child;device_id=$desktop.id;skip_build=$true}
    Accept $desktop $childShare.folder_id $desktopRoot $hub
    Check ($before -eq (Api $hub GET "config/folders/$($parentShare.folder_id)"|ConvertTo-Json -Depth 50 -Compress)) 'child sharing preserves complete parent configuration'
    Check ($ignoreBefore -eq (Api $hub GET "db/ignores?folder=$($parentShare.folder_id)"|ConvertTo-Json -Depth 50 -Compress)) 'child sharing preserves parent ignore rules'
    $childConfig=Api $hub GET "config/folders/$($childShare.folder_id)"
    Check (@($childConfig.devices).Count -eq 2 -and @($childConfig.devices|Where-Object deviceID -eq $laptop.id).Count -eq 0) 'child share contains only hub and selected desktop'
    Until {(Text-Is (Join-Path $laptopRoot 'project/hello.txt') 'initial') -and (Text-Is (Join-Path $desktopRoot 'hello.txt') 'initial')} 'parent and child transfer to their separate devices'
    Check (!(Test-Path -LiteralPath (Join-Path $desktopRoot 'other-project.txt'))) 'desktop receives no parent sibling files'
    Set-Content -LiteralPath (Join-Path $desktopRoot 'hello.txt') 'from desktop';Scan $desktop $childShare.folder_id
    Until {(Text-Is (Join-Path $child 'hello.txt') 'from desktop') -and (Text-Is (Join-Path $laptopRoot 'project/hello.txt') 'from desktop')} 'desktop edit relays through child into parent share'
    Set-Content -LiteralPath (Join-Path $laptopRoot 'project/hello.txt') 'from laptop';Scan $laptop $parentShare.folder_id
    Until {(Text-Is (Join-Path $child 'hello.txt') 'from laptop') -and (Text-Is (Join-Path $desktopRoot 'hello.txt') 'from laptop')} 'laptop edit relays through parent into child share'
    Check (((Get-FileHash -LiteralPath (Join-Path $child 'hello.txt')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $desktopRoot 'hello.txt')).Hash)) 'relayed file checksums agree'
    Set-Content -LiteralPath (Join-Path $desktopRoot 'delete-test.txt') 'generated deletion fixture';Scan $desktop $childShare.folder_id
    Until {Test-Path -LiteralPath (Join-Path $laptopRoot 'project/delete-test.txt')} 'generated child file reaches laptop'
    Remove-Item -LiteralPath (Join-Path $desktopRoot 'delete-test.txt');Scan $desktop $childShare.folder_id
    Until {!(Test-Path -LiteralPath (Join-Path $child 'delete-test.txt')) -and !(Test-Path -LiteralPath (Join-Path $laptopRoot 'project/delete-test.txt'))} 'child deletion propagates without resurrecting generated file'
    $allBefore=Api $hub GET 'config/folders'|ConvertTo-Json -Depth 50 -Compress
    $rejection=Call-Core $hub share @{local_path=$child;device_id=$laptop.id} -Reject;Check ($rejection -match 'same device') 'same-peer child expansion explains the conflict'
    $null=Call-Core $hub share @{local_path=$parent;device_id=$desktop.id} -Reject
    Check ($allBefore -eq (Api $hub GET 'config/folders'|ConvertTo-Json -Depth 50 -Compress)) 'rejected parent and child expansions preserve all configured shares'
    $null=Call-Core $hub stop @{folder_id=$childShare.folder_id;expected_path=$child}
    Check ((Api $hub GET "config/folders/$($parentShare.folder_id)").id -eq $parentShare.folder_id) 'stopping child leaves parent configured'
    Check (Text-Is (Join-Path $child 'hello.txt') 'from laptop') 'stopping child keeps local files'
    Set-Content -LiteralPath (Join-Path $laptopRoot 'project/hello.txt') 'parent still syncing';Scan $laptop $parentShare.folder_id
    Until {Text-Is (Join-Path $child 'hello.txt') 'parent still syncing'} 'parent continues syncing after child stops'
    Check (Text-Is (Join-Path $desktopRoot 'hello.txt') 'from laptop') 'stopped child retains its last desktop copy'
    @{result='pass';checks=$checks;count=$checks.Count}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $root 'report.json')
    "PASS: $($checks.Count) nested real-transfer checks. Report: $root\report.json"
} catch {@{result='fail';checks=$checks;error=$_.Exception.Message}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $root 'report.json');throw}
finally {foreach($node in $nodes){try{Api $node POST 'system/shutdown'|Out-Null}catch{};if(!$node.process.WaitForExit(5000)){Stop-Process -Id $node.process.Id -ErrorAction SilentlyContinue};$node.process.Dispose()}}
