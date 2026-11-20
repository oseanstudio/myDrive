using System.IO.Pipes;
using System.Text;
namespace MyDrive;
public sealed class SingleInstance : IDisposable
{
    private readonly Mutex mutex;
    private readonly CancellationTokenSource cancellation=new();
    public bool IsPrimary {get;}
    private static string Name=>"myDrive.ui."+Environment.UserName;
    public SingleInstance(){mutex=new Mutex(true,"Local\\"+Name,out var created);IsPrimary=created;}
    public async Task Redirect()
    {
        try{using var client=new NamedPipeClientStream(".",Name,PipeDirection.Out,PipeOptions.Asynchronous);await client.ConnectAsync(3000);var bytes=Encoding.UTF8.GetBytes("show\n");await client.WriteAsync(bytes);}catch{}
    }
    public void Listen(Action activate)=>_=Task.Run(async()=>
    {
        while(!cancellation.IsCancellationRequested)
        {
            try{await using var server=new NamedPipeServerStream(Name,PipeDirection.In,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous|PipeOptions.CurrentUserOnly);await server.WaitForConnectionAsync(cancellation.Token);using var reader=new StreamReader(server);var command=await reader.ReadLineAsync(cancellation.Token);if(command=="show")activate();}
            catch(OperationCanceledException){break;}catch{await Task.Delay(250,cancellation.Token);}
        }
    });
    public void Dispose(){cancellation.Cancel();if(IsPrimary)try{mutex.ReleaseMutex();}catch{}mutex.Dispose();cancellation.Dispose();}
}
