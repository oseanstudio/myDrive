using System.Text.Json;
using System.Xml;
using System.Xml.Linq;
namespace MyDrive;
public static class SyncthingService
{
    public sealed record Connection(string endpoint,string api_key,string certificate_pem);
    private static readonly SemaphoreSlim EngineLock=new(1,1);
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
    public static async Task KeepRunningAsync(CancellationToken token=default){if(!Preferences.Current.SyncthingManual)await EnsureRunning(token,true);}
    private static async Task<Connection> EnsureRunning(CancellationToken token,bool verify=false)
    {
        // Manual endpoints are explicit connections; never start an unrelated default engine.
        if(Preferences.Current.SyncthingManual)return Discover();
        await EngineLock.WaitAsync(token);
        try
        {
            var stamp=ConfigStamp();
            if(!verify&&cachedConnection is {} cached&&cachedConfig==stamp&&DateTime.UtcNow<cacheUntil)return cached;
            // Do not kill the detached engine when a UI operation is cancelled.
            var result=await CoreBridge.Call(new{action="engine.ensure",data_dir=CoreBridge.DataDir,payload=new{config_path=Preferences.Current.SyncthingConfigPath}});
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
