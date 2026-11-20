param([Parameter(Mandatory=$true)][string]$ProcessIds)
$ErrorActionPreference='Stop'
# Separate, windowless helper: attach only to explicitly supplied fixture engines.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FixtureConsole {
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool AttachConsole(uint process);
 [DllImport("kernel32.dll")] public static extern bool FreeConsole();
 [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
}
'@
$visible=$false
foreach($targetId in $ProcessIds.Split(',')){
    Get-Process -Id ([int]$targetId) -ErrorAction Stop|Out-Null
    [FixtureConsole]::FreeConsole()|Out-Null
    if([FixtureConsole]::AttachConsole([uint32]$targetId)){
        $window=[FixtureConsole]::GetConsoleWindow()
        $visible=$visible -or ($window -ne [IntPtr]::Zero -and [FixtureConsole]::IsWindowVisible($window))
        [FixtureConsole]::FreeConsole()|Out-Null
    }else{
        $errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if($errorCode -ne 6){throw "Cannot inspect the fixture console: $errorCode"}
    }
}
@{visible_console=$visible}|ConvertTo-Json -Compress
