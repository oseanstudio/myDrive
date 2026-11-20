using System.Diagnostics;
using System.Text.Json;
namespace MyDrive;
public static class CoreBridge
{
    public static string DataDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"myDrive");
    private static readonly SemaphoreSlim StoreLock=new(1,1);
    public static async Task<JsonElement> Call(object request,CancellationToken cancellation=default)
    {
        cancellation.ThrowIfCancellationRequested();
        var executable=Path.Combine(AppContext.BaseDirectory,"mydrive-core.exe");
        if(!File.Exists(executable)) throw new IOException("The myDrive core is missing. Run build.ps1 to rebuild the app.");
        using var process=new Process { StartInfo=new ProcessStartInfo(executable){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,StandardOutputEncoding=System.Text.Encoding.UTF8} };
        process.Start();
        using var registration=cancellation.Register(()=>{try {if(!process.HasExited)process.Kill(true);}catch{}});
        var output=process.StandardOutput.ReadToEndAsync(cancellation);
        var errors=process.StandardError.ReadToEndAsync(cancellation);
        try
        {
            await process.StandardInput.WriteAsync(JsonSerializer.Serialize(request).AsMemory(),cancellation);
            process.StandardInput.Close();
            await process.WaitForExitAsync(cancellation);
            var result=await output;await errors;
            if(process.ExitCode!=0)throw new IOException("The connection service stopped unexpectedly. Please try again.");
            using var doc=JsonDocument.Parse(result);
            if(!doc.RootElement.GetProperty("ok").GetBoolean())throw new IOException(doc.RootElement.GetProperty("error").GetString());
            return doc.RootElement.GetProperty("data").Clone();
        }
        catch {try{if(!process.HasExited)process.Kill(true);}catch{}throw;}
    }
    public static async Task<List<Bookmark>> Load()
    {
        var data=await Call(new{action="bookmarks.load",data_dir=DataDir});
        return data.Deserialize<List<Bookmark>>()??new();
    }
    public static async Task Save(List<Bookmark> bookmarks)
    {
        await StoreLock.WaitAsync();try{await Call(new{action="bookmarks.save",data_dir=DataDir,bookmarks});}finally{StoreLock.Release();}
    }
    public static async Task<List<RemoteFile>> List(Bookmark b,string path,CancellationToken token=default)
    {
        var data=await Call(new{action="list",bookmark=b,credentials=CredentialStore.Read(b.id),path},token);
        return data.Deserialize<List<RemoteFile>>()??new();
    }
    public static Task<JsonElement> Operation(string action,Bookmark b,string path,string localPath="",string destination="",bool isDir=false,CancellationToken token=default)
        =>Call(new{action,data_dir=DataDir,bookmark=b,credentials=CredentialStore.Read(b.id),path,local_path=localPath,destination,is_dir=isDir},token);
}
