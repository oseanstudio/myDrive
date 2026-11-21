using System.Diagnostics;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;
namespace MyDrive;
public static class SyncthingService
{
    public sealed record Connection(string endpoint,string api_key,string certificate_pem);
    private static readonly SemaphoreSlim EngineLock=new(1,1);
    private static readonly object OwnerGate=new();
    private static Process? owner;
    private static bool stopping;
    private static Connection? cachedConnection;
    private static string cachedConfig="";
    private static DateTime cacheUntil;
    public static void Invalidate(){cachedConnection=null;cachedConfig="";}
    private static string ConfigStamp()
    {
        var path=FindConfig();
        string Stamp(string file){if(string.IsNullOrEmpty(file))return "missing";var info=new FileInfo(file);return info.Exists?$"{info.Length}:{info.LastWriteTimeUtc.Ticks}":"missing";}
        return path+"|"+Stamp(path)+"|"+Stamp(Path.Combine(Path.GetDirectoryName(path)??"","https-cert.pem"));
    }
    public static async Task StopAsync(bool quit=true)
    {
        Process? process;
        lock(OwnerGate)
        {
            if(quit)stopping=true;
            process=owner;
            owner=null;
            if(process!=null)try{process.StandardInput.Close();}catch(IOException){}
        }
        Invalidate();
        if(process==null)return;
        try{await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(6));}
        catch(TimeoutException){} // The closed pipe still ends the session after startup.
        finally{process.Dispose();}
    }

    private static async Task<JsonElement> RequestOwner()
    {
        Process process;
        lock(OwnerGate)
        {
            if(stopping)throw new OperationCanceledException();
            if(owner==null||owner.HasExited)
            {
                owner?.Dispose();
                var start=new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory,"mydrive-core.exe"))
                {
                    UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,
                    RedirectStandardOutput=true,StandardOutputEncoding=System.Text.Encoding.UTF8,
                    StandardInputEncoding=new System.Text.UTF8Encoding(false)
                };
                start.ArgumentList.Add("--syncthing-owner");
                owner=Process.Start(start)??throw new IOException("Could not start the myDrive Syncthing service.");
            }
            process=owner;
            process.StandardInput.WriteLine(JsonSerializer.Serialize(new{data_dir=CoreBridge.DataDir,payload=new{config_path=Preferences.Current.SyncthingConfigPath}}));
        }
        var line=await process.StandardOutput.ReadLineAsync();
        if(line==null)throw new IOException("The myDrive Syncthing service stopped. Refresh Sync to reconnect.");
        using var doc=JsonDocument.Parse(line);
        if(!doc.RootElement.GetProperty("ok").GetBoolean())throw new IOException(doc.RootElement.GetProperty("error").GetString());
        return doc.RootElement.GetProperty("data").Clone();
    }

    private static async Task<Connection> EnsureRunning(CancellationToken token)
    {
        // Manual endpoints are explicit connections; never start an unrelated default engine.
        if(Preferences.Current.SyncthingManual){await StopAsync(false);return Discover();}
        await EngineLock.WaitAsync(token);
        try
        {
            var stamp=ConfigStamp();
            if(cachedConnection is {} cached&&cachedConfig==stamp&&DateTime.UtcNow<cacheUntil)return cached;
            token.ThrowIfCancellationRequested();
            var result=await RequestOwner();
            token.ThrowIfCancellationRequested();
            var connection=result.GetProperty("connection").Deserialize<Connection>()??throw new IOException("Cannot read the background engine connection.");
            if(stamp==ConfigStamp()){cachedConnection=connection;cachedConfig=stamp;cacheUntil=DateTime.UtcNow.AddMinutes(5);}
            return connection;
        }
        finally{EngineLock.Release();}
    }
    public static string FindConfig()
    {
        if(!string.IsNullOrEmpty(Preferences.Current.SyncthingConfigPath))return Preferences.Current.SyncthingConfigPath;
        var candidates=new[]{
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Syncthing","config.xml"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),"Syncthing","config.xml"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".local","state","syncthing","config.xml"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".config","syncthing","config.xml")};
        return candidates.FirstOrDefault(File.Exists)??"";
    }
    public static Connection Discover()
    {
        if(Preferences.Current.SyncthingManual)return new(Preferences.Current.SyncthingEndpoint,CredentialStore.Read("syncthing-local-api").password,"");
        var path=FindConfig();if(path.Length==0)throw new IOException("Syncthing is being set up. Refresh Sync to finish connecting.");
        using var reader=XmlReader.Create(path,new XmlReaderSettings{DtdProcessing=DtdProcessing.Prohibit,XmlResolver=null});
        var doc=XDocument.Load(reader);var gui=doc.Root?.Element("gui")??throw new IOException("This file does not contain Syncthing GUI settings.");
        if((string?)gui.Attribute("enabled")=="false")throw new IOException("Syncthing's local GUI/API is disabled.");
        var address=(string?)gui.Element("address")??"127.0.0.1:8384";var tls=(string?)gui.Attribute("tls")=="true";
        if(address.StartsWith("0.0.0.0:"))address="127.0.0.1:"+address[8..];if(address.StartsWith("[::]:"))address="[::1]:"+address[5..];
        var endpoint=$"{(tls?"https":"http")}://{address}";var key=(string?)gui.Element("apikey")??"";
        var certificatePath=Path.Combine(Path.GetDirectoryName(path)!,"https-cert.pem");var certificate=tls&&File.Exists(certificatePath)?File.ReadAllText(certificatePath):"";
        return new(endpoint,key,certificate);
    }
    public static async Task<JsonElement> Call(string action,object? payload=null,CancellationToken token=default)
    {
        var connection=await EnsureRunning(token);
        try{return await CoreBridge.Call(new{action="syncthing."+action,syncthing=connection,payload=payload??new{},data_dir=CoreBridge.DataDir},token);}
        catch(IOException){Invalidate();throw;} // A failed mutation must never be replayed automatically.
    }
    public static string ProjectFolder()
    {
        for(var folder=new DirectoryInfo(AppContext.BaseDirectory);folder!=null;folder=folder.Parent)
            if(File.Exists(Path.Combine(folder.FullName,"PLAN.md"))&&Directory.Exists(Path.Combine(folder.FullName,"Core")))return folder.FullName;
        return Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
    }
}
