using System.IO.Pipes;
using System.Text;
using System.Text.Json;
namespace MyDrive;
public sealed class SingleInstance : IDisposable
{
    private readonly Mutex mutex;
    private readonly CancellationTokenSource cancellation=new();
    public bool IsPrimary {get;}
    private static string Name=>"myDrive.ui."+Environment.UserName;
    public SingleInstance(){mutex=new Mutex(true,"Local\\"+Name,out var created);IsPrimary=created;}
    private const int MaxRequestBytes = 1024 * 1024;
    public async Task Redirect(string[]? paths)
    {
        try
        {
            var command = paths == null ? "show\n" : "send\n" + JsonSerializer.Serialize(paths);
            var bytes = Encoding.UTF8.GetBytes(command);
            if (bytes.Length > MaxRequestBytes) return;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            using var client = new NamedPipeClientStream(".", Name, PipeDirection.Out,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await client.ConnectAsync(timeout.Token);
            await client.WriteAsync(bytes, timeout.Token);
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or UnauthorizedAccessException) {}
    }
    public void Listen(Action activate, Action<string[]> send)=>_=Task.Run(async()=>
    {
        while(!cancellation.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(Name, PipeDirection.In, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(cancellation.Token);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(3));
                using var request = new MemoryStream();
                var buffer = new byte[4096];
                int size;
                while ((size = await server.ReadAsync(buffer.AsMemory(), timeout.Token)) > 0)
                {
                    if (request.Length + size > MaxRequestBytes) break;
                    request.Write(buffer, 0, size);
                }
                if (size != 0) continue;
                var command = Encoding.UTF8.GetString(request.GetBuffer(), 0, (int)request.Length);
                if (command == "show\n") activate();
                else if (command.StartsWith("send\n", StringComparison.Ordinal) &&
                         JsonSerializer.Deserialize<string[]>(command[5..]) is { Length: > 0 and <= 256 } paths)
                    send(paths);
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { break; }
            catch (OperationCanceledException) {}
            catch (JsonException) {}
            catch (IOException) { await Task.Delay(250, cancellation.Token); }
        }
    });
    public void Dispose(){cancellation.Cancel();if(IsPrimary)try{mutex.ReleaseMutex();}catch{}mutex.Dispose();cancellation.Dispose();}
}
