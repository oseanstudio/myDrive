param(
    [string]$Syncthing=(Join-Path $env:APPDATA 'SyncTrayzor/syncthing.exe'),
    [string]$Core=(Join-Path $PSScriptRoot '../build/windows/mydrive-core.exe')
)
$ErrorActionPreference='Stop'
$testStorageRoot=if($env:OSEAN_STUDIO_DATA){Join-Path $env:OSEAN_STUDIO_DATA 'Validation/myDrive'}else{Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'myDrive/Validation'}
$root=Join-Path $testStorageRoot ('engine-test-'+[Guid]::NewGuid().ToString('N'))
$fixtureHome=Join-Path $root 'config'
$data=Join-Path $root 'mydrive-data'
New-Item -ItemType Directory -Force $fixtureHome,$data|Out-Null
$caller=Join-Path $root 'temporary-caller'
New-Item -ItemType Directory -Force $caller|Out-Null
$checks=[System.Collections.Generic.List[string]]::new()
function Check($value,[string]$label){if(!$value){throw "FAILED: $label"};$checks.Add($label)}
function Begin-Core($payload){
    $s=[Diagnostics.ProcessStartInfo]::new($Core);$s.UseShellExecute=$false;$s.CreateNoWindow=$true;$s.RedirectStandardInput=$true;$s.RedirectStandardOutput=$true;$s.RedirectStandardError=$true
    $s.WorkingDirectory=if(Test-Path -LiteralPath $caller){$caller}else{$root}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$s;$p.Start()|Out-Null
    $p.StandardInput.Write((@{action='engine.ensure';data_dir=$data;payload=$payload}|ConvertTo-Json -Compress));$p.StandardInput.Close();return $p
}
function End-Core($p){try{$out=$p.StandardOutput.ReadToEnd();$err=$p.StandardError.ReadToEnd();$p.WaitForExit();if($p.ExitCode){throw 'Core failed'};return ($out|ConvertFrom-Json)}finally{$p.Dispose()}}
function Call($payload){$r=End-Core (Begin-Core $payload);if(!$r.ok){throw $r.error};return $r.data}
function Api($method,$path,$body=$null){$a=@{Uri="$base/rest/$path";Method=$method;Headers=$headers;TimeoutSec=4};if($null -ne $body){$a.Body=ConvertTo-Json -Depth 30 -Compress -InputObject $body;$a.ContentType='application/json'};Invoke-RestMethod @a}
function Wait-Off {for($i=0;$i -lt 60;$i++){try{Api GET system/ping|Out-Null}catch{return};Start-Sleep -Milliseconds 200};throw 'Fixture did not stop'}
try{
    & $Syncthing generate --home $fixtureHome --no-port-probing 2>&1|Out-Null
    if($LASTEXITCODE){throw 'Fixture generation failed'}
    [xml]$config=Get-Content (Join-Path $fixtureHome config.xml) -Raw
    @($config.configuration.SelectNodes('folder'))|ForEach-Object{$config.configuration.RemoveChild($_)|Out-Null}
    foreach($name in @('globalAnnounceEnabled','localAnnounceEnabled','relaysEnabled','natEnabled','startBrowser','crashReportingEnabled')){$config.configuration.options.SelectSingleNode($name).InnerText='false'}
    $config.configuration.options.autoUpgradeIntervalH='0'
    @($config.configuration.options.SelectNodes('listenAddress'))|ForEach-Object{$config.configuration.options.RemoveChild($_)|Out-Null}
    $listen=$config.CreateElement('listenAddress');$listen.InnerText='tcp://127.0.0.1:0';$config.configuration.options.AppendChild($listen)|Out-Null
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
    $config.configuration.gui.address="127.0.0.1:$port"
    $config.Save((Join-Path $fixtureHome config.xml))
    $base="http://127.0.0.1:$port";$headers=@{'X-API-Key'=[string]$config.configuration.gui.apikey}
    $payload=@{config_path=(Join-Path $fixtureHome config.xml);binary_path=$Syncthing}
    $p1=Begin-Core $payload;$p2=Begin-Core $payload
    $one=End-Core $p1;$two=End-Core $p2
    Check ($one.ok -and $two.ok) 'concurrent startup requests succeed'
    Check ((@($one.data.state,$two.data.state)|Sort-Object) -join ',' -eq 'running,started') 'one engine starts and the competing request reuses it'
    Check ((Api GET system/ping).ping -eq 'pong') 'engine survives both requesting core processes exiting'
    $fixtureProcesses=@(Get-CimInstance Win32_Process -Filter "Name='syncthing.exe'"|Where-Object{$_.CommandLine -like "*$fixtureHome*"})
    Check ($fixtureProcesses.Count -gt 0 -and @($fixtureProcesses|Where-Object{$_.CommandLine -notmatch '\-\-no-console'}).Count -eq 0) 'no-console option reaches engine monitor and worker'
    $probeStart=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$probeStart.UseShellExecute=$false;$probeStart.CreateNoWindow=$true;$probeStart.RedirectStandardOutput=$true;$probeStart.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'console-probe.ps1'),'-ProcessIds',($fixtureProcesses.ProcessId -join ','))){$probeStart.ArgumentList.Add($arg)}
    $probe=[Diagnostics.Process]::Start($probeStart);try{$probeOut=$probe.StandardOutput.ReadToEnd();$probeError=$probe.StandardError.ReadToEnd();$probe.WaitForExit();if($probe.ExitCode){throw $probeError};$console=$probeOut|ConvertFrom-Json;Check ($null -ne $console -and $console.visible_console -is [bool] -and !$console.visible_console) 'engine monitor and worker have no visible console'}finally{$probe.Dispose()}
    Remove-Item -LiteralPath $caller
    Check (!(Test-Path -LiteralPath $caller)) 'background engine releases the temporary caller directory'
    $id=(Api GET system/status).myID
    $folder=Api GET config/defaults/folder;$folder.id='engine-fixture';$folder.label='Keep engine fixture';$folder.path=Join-Path $root 'files';New-Item -ItemType Directory -Force $folder.path|Out-Null
    Set-Content (Join-Path $folder.path keep.txt) 'retained file'
    Api POST config/folders $folder|Out-Null
    $running=Call $payload
    Check ($running.state -eq 'running') 'running instance is reused without a new launch'
    Api POST system/shutdown|Out-Null;Wait-Off
    $restarted=Call $payload
    Check ($restarted.state -eq 'started') 'closed engine restarts without a GUI'
    Check ((Api GET system/status).myID -eq $id) 'device identity survives restart'
    Check ((Api GET config/folders/engine-fixture).path -eq $folder.path) 'folder configuration survives restart'
    Check ((Get-Content (Join-Path $folder.path keep.txt) -Raw).Trim() -eq 'retained file') 'local files survive restart'
    Api POST system/shutdown|Out-Null;Wait-Off
    $detected=Call @{config_path=$payload.config_path}
    Check ($detected.state -eq 'started') 'installed binary is discovered without an explicit executable path'
    Check ((Resolve-Path $detected.binary_path).Path -eq (Resolve-Path $Syncthing).Path) 'existing installed binary is preferred over downloading'
    Api POST system/shutdown|Out-Null;Wait-Off
    $bad=End-Core (Begin-Core @{config_path=(Join-Path $root missing.xml)})
    Check (!$bad.ok) 'missing explicitly selected configuration is not silently replaced'
    # An unrelated listener must not trigger a second engine or a config reset.
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);$listener.Start()
    try{$blocked=End-Core (Begin-Core $payload);Check (!$blocked.ok -and $blocked.error -match 'already in use') 'occupied API port refuses a competing engine'}finally{$listener.Stop()}
    $report=@{result='pass';checks=$checks;count=$checks.Count}
    $out=Join-Path $testStorageRoot 'syncthing-engine.json';New-Item -ItemType Directory -Force (Split-Path $out)|Out-Null;$report|ConvertTo-Json -Depth 5|Set-Content $out
    $report|ConvertTo-Json -Depth 5
}finally{
    # Only the isolated engine authenticated by its generated fixture key is stopped.
    if($headers){try{Api POST system/shutdown|Out-Null}catch{}}
    # Kill only fixture processes if startup failed before its API was available.
    Get-CimInstance Win32_Process -Filter "Name='syncthing.exe'"|Where-Object{$_.CommandLine -like "*$fixtureHome*"}|ForEach-Object{Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue}
}
