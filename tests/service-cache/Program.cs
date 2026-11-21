using System.Text.Json;
using MyDrive;

// This executable is also the fake sidecar. Production bridge/service sources
// are linked above; no production daemon, bookmarks or credentials are touched.
var fixture=Environment.GetEnvironmentVariable("MYDRIVE_CACHE_TEST_FIXTURE");
if(args.Contains("--test"))
{
    fixture=Path.Combine(Path.GetTempPath(),"mydrive-cache-test-"+Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(fixture);
    Environment.SetEnvironmentVariable("MYDRIVE_CACHE_TEST_FIXTURE",fixture);
    Preferences.Current.SyncthingConfigPath=Path.Combine(fixture,"config.xml");
    await File.WriteAllTextAsync(Preferences.Current.SyncthingConfigPath,"fixture");
    int Count(string action)=>File.ReadAllLines(Path.Combine(fixture,"calls.txt")).Count(x=>x==action);
    void Check(bool good,string name){if(!good)throw new Exception(name);Console.WriteLine("PASS "+name);}
    await SyncthingService.Call("snapshot");
    await Task.WhenAll(Enumerable.Range(0,12).Select(_=>SyncthingService.Call("snapshot")));
    Check(Count("engine.ensure")==1,"concurrent requests reuse one validated connection");
    File.SetLastWriteTimeUtc(Preferences.Current.SyncthingConfigPath,DateTime.UtcNow.AddMinutes(1));
    await SyncthingService.Call("snapshot");
    Check(Count("engine.ensure")==2,"config change invalidates cached connection");
    await File.WriteAllTextAsync(Path.Combine(fixture,"https-cert.pem"),"changed certificate fixture");
    await SyncthingService.Call("snapshot");
    Check(Count("engine.ensure")==3,"certificate change invalidates cached connection");
    SyncthingService.Invalidate();await SyncthingService.Call("snapshot");
    Check(Count("engine.ensure")==4,"explicit settings invalidation reconnects");
    try{await SyncthingService.Call("pause",new{fail=true});throw new Exception("Expected failure");}catch(IOException){}
    await SyncthingService.Call("snapshot");
    Check(Count("syncthing.pause")==1&&Count("engine.ensure")==5,"failed mutation is not replayed and next request reconnects");
    var before=File.ReadAllLines(Path.Combine(fixture,"calls.txt")).Length;
    using var cancelled=new CancellationTokenSource();cancelled.Cancel();
    try{await SyncthingService.Call("pause",token:cancelled.Token);throw new Exception("Expected cancellation");}catch(OperationCanceledException){}
    Check(File.ReadAllLines(Path.Combine(fixture,"calls.txt")).Length==before,"early cancellation does not start a request");
    Preferences.Current.SyncthingManual=true;
    Preferences.Current.SyncthingEndpoint="http://127.0.0.1:1";
    await SyncthingService.Call("snapshot");
    Check(Count("engine.ensure")==5,"manual mode never sends a start request");
    Check(Count("engine.closed")==1,"switching to manual mode closes the automatic engine session");
    await SyncthingService.StopAsync();
    Console.WriteLine("Fixture: "+fixture);
    return;
}
if(fixture==null)throw new Exception("Run this test helper with --test.");
if(args.Contains("--syncthing-owner"))
{
    while(await Console.In.ReadLineAsync() is {} line) Reply(line,"engine.ensure");
    Log("engine.closed");
}
else Reply(await Console.In.ReadToEndAsync());

void Log(string action)
{
    // File writes from independent children are protected by a named mutex.
    using var mutex=new Mutex(false,"Local\\myDrive-cache-test-"+Path.GetFileName(fixture));
    mutex.WaitOne();try{File.AppendAllText(Path.Combine(fixture!,"calls.txt"),action+"\n");}finally{mutex.ReleaseMutex();}
}

void Reply(string input,string? serviceAction=null)
{
    using var request=JsonDocument.Parse(input);
    var action=serviceAction??request.RootElement.GetProperty("action").GetString()!;
    Log(action);
    if(request.RootElement.TryGetProperty("payload",out var payload)&&payload.TryGetProperty("fail",out var fail)&&fail.GetBoolean())
        Console.WriteLine("{\"ok\":false,\"error\":\"simulated uncertain mutation\"}");
    else if(action=="engine.ensure")
        Console.WriteLine("{\"ok\":true,\"data\":{\"connection\":{\"endpoint\":\"http://127.0.0.1:1\",\"api_key\":\"fixture-only\",\"certificate_pem\":\"\"}}}");
    else Console.WriteLine("{\"ok\":true,\"data\":{}}");
}

namespace MyDrive
{
    public sealed class Preferences
    {
        public static Preferences Current {get;}=new();
        public string SyncthingConfigPath {get;set;}="";
        public string SyncthingEndpoint {get;set;}="";
        public bool SyncthingManual {get;set;}
    }
    public sealed class Credentials{public string password {get;set;}="";}
    public static class CredentialStore{public static Credentials Read(string id)=>new();}
    public sealed class Bookmark{public string id {get;set;}="fixture";}
    public sealed class RemoteFile{}
}
