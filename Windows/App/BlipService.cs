using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace MyDrive;

// Owns only myDrive's helpers. The native election arbitrates the shared Blip host.
public sealed class BlipService : IAsyncDisposable
{
    private readonly string bundle, runtime, profile, node;
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private Process? host;
    private Task? observer;
    private bool stopping;
    private string? attachedSocket;
    private readonly string desktopSocket;
    public string LastError { get; private set; } = "";
    public string ProfileDirectory => profile;
    public string DownloadsDirectory => Path.Combine(profile, "downloads");
    public bool RuntimeAvailable => File.Exists(node) && File.Exists(Path.Combine(bundle, "cli.mjs"));
    public bool UsesDesktopSession => attachedSocket != null;
    public bool DesktopAvailable => RuntimeAvailable;
    public bool IsRunning { get { try { return host is { HasExited: false }; } catch { return false; } } }
    public static string BundleDirectory => Path.Combine(AppContext.BaseDirectory, "Blip");
    public static string DefaultRuntimeDirectory
    {
        get
        {
            var root = Environment.GetEnvironmentVariable("OSEAN_STUDIO_DATA");
            if (string.IsNullOrWhiteSpace(root))
            {
                try
                {
                    using var config = JsonDocument.Parse(File.ReadAllText(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OseanStudio", "storage.json")));
                    root = config.RootElement.GetProperty("root").GetString();
                }
                catch { }
            }
            return Path.Combine(root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OseanStudio"), "Runtimes", "myDrive Blip");
        }
    }
    public BlipService(string bundleDirectory, string runtimeDirectory, string profileDirectory, string? nodeExecutable = null, string? desktopSocketPath = null)
    {
        bundle = Path.GetFullPath(bundleDirectory); runtime = Path.GetFullPath(runtimeDirectory); profile = Path.GetFullPath(profileDirectory);
        node = nodeExecutable ?? Path.Combine(runtime, OperatingSystem.IsWindows() ? "node.exe" : "node");
        desktopSocket = Path.GetFullPath(desktopSocketPath ?? Path.Combine(Path.GetTempPath(), "net.blip.desktop", "sock"));
    }
    private Process NewProcess(string command, IEnumerable<string>? arguments = null)
    {
        if (!RuntimeAvailable) throw new IOException("Blip's transfer engine is not prepared. See the Blip setup instructions included with myDrive.");
        var info = new ProcessStartInfo(node)
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = bundle,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        info.ArgumentList.Add(Path.Combine(bundle, "cli.mjs")); info.ArgumentList.Add(command);
        info.ArgumentList.Add("--profile"); info.ArgumentList.Add(profile);
        if (attachedSocket != null && command is "status" or "devices" or "transfers" or "poll" or "send" or "accept")
        { info.ArgumentList.Add("--socket"); info.ArgumentList.Add(attachedSocket); }
        if (arguments != null) foreach (var arg in arguments) info.ArgumentList.Add(arg);
        info.Environment["MYDRIVE_BLIP_RUNTIME"] = runtime;
        info.Environment["MYDRIVE_BLIP_JSONL"] = "1";
        return new Process { StartInfo = info };
    }
    private static void KillOwned(Process process) { try { if (!process.HasExited) process.Kill(true); } catch { } }
    private static async Task<string> ReadBounded(StreamReader stream, CancellationToken token)
    {
        var result = new StringBuilder(); var buffer = new char[4096];
        while (true)
        {
            int count = await stream.ReadAsync(buffer.AsMemory(), token);
            if (count == 0) return result.ToString();
            if (result.Length + count > 1024 * 1024) throw new IOException("Blip returned more data than expected. Refresh to check its state.");
            result.Append(buffer, 0, count);
        }
    }
    internal async Task<JsonElement> CommandAsync(string command, IEnumerable<string>? args = null, string input = "", CancellationToken token = default)
    {
        token.ThrowIfCancellationRequested();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(35));
        using var process = NewProcess(command, args);
        process.Start();
        using var cancellation = timeout.Token.Register(() => KillOwned(process));
        var stdout = ReadBounded(process.StandardOutput, timeout.Token);
        var stderr = ReadBounded(process.StandardError, timeout.Token); // Drain, but never expose native diagnostics/codes.
        _ = stdout.ContinueWith(_ => KillOwned(process), CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
        _ = stderr.ContinueWith(_ => KillOwned(process), CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
        try
        {
            await process.StandardInput.WriteAsync(input.AsMemory(), timeout.Token); process.StandardInput.Close();
            await process.WaitForExitAsync(timeout.Token);
            string text = await stdout; await stderr;
            using var result = JsonDocument.Parse(text);
            var data = result.RootElement;
            if(command=="accept")SaveReceiveResult(data);
            if (process.ExitCode != 0 || !data.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True)
                throw new IOException(data.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String ? FriendlyError(error.GetString()) : "Blip could not confirm the request. Refresh before trying again.");
            return data.Clone();
        }
        catch (OperationCanceledException)
        {
            KillOwned(process);
            throw new IOException("The Blip request stopped before its result was confirmed. Refresh transfers before retrying; the background engine was kept running.");
        }
        catch { KillOwned(process); throw; }
        finally { try { await Task.WhenAll(stdout, stderr); } catch { } }
    }
    private void SaveReceiveResult(JsonElement data) {
        // Keep only bounded machine status; never persist IDs, paths, names or received contents.
        try {
            var result=new Dictionary<string,object>{{"at",DateTimeOffset.UtcNow},{"ok",data.TryGetProperty("ok",out var ok)&&ok.ValueKind==JsonValueKind.True}};
            foreach(string key in new[]{"phase","error","native_status"})if(data.TryGetProperty(key,out var value)&&value.ValueKind==JsonValueKind.String&&value.GetString() is {} text&&text.Length<=80&&text.All(c=>char.IsAsciiLetterOrDigit(c)||c=='_'))result[key]=text;
            Directory.CreateDirectory(profile);File.WriteAllText(Path.Combine(profile,"last-receive-result.json"),JsonSerializer.Serialize(result));
        }catch { }
    }
    private static string FriendlyError(string? error) => error switch
    {
        "IllegalStateException" => "Blip is not ready for this action. Check the account and transfer status, then refresh.",
        "IllegalArgumentException" => "Blip rejected the selected device, file or transfer. Refresh the list and select it again.",
        "registration_failed" => "Blip could not complete sign-in. Check the code or request a new one.",
        "acceptance_unconfirmed" => "Blip has not confirmed receiving. Check Transfers before trying Receive again.",
        "accept_not_waiting" => "This transfer is no longer waiting to receive. Refresh Transfers to see its current state.",
        "desktop_profile_missing" => "Open and sign in to Blip once on this computer, then reconnect myDrive. No new account is needed.",
        _ => "Blip could not confirm the request. Refresh before trying again."
    };
    public async Task StartAsync(CancellationToken token = default)
    {
        await lifecycle.WaitAsync(token);
        try
        {
            if (UsesDesktopSession) throw new IOException("Disconnect desktop Blip before starting a separate engine.");
            if (IsRunning) return;
            LastError = ""; stopping = false;
            await PrepareAsync(token);
            var process = NewProcess("serve"); var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            host?.Dispose(); host = process; process.Start(); observer = ObserveHost(process, ready);
            try { await ready.Task.WaitAsync(TimeSpan.FromSeconds(20), token); }
            catch { await StopOwned(process); throw new IOException("Blip could not start. Check that the prepared engine matches this build and that its profile path is short enough."); }
        }
        finally { lifecycle.Release(); }
    }
    private async Task PrepareAsync(CancellationToken token)
    {
        await CommandAsync("doctor", token: token);
        if (!Directory.Exists(profile)) await CommandAsync("init", new[] { "--name", "myDrive" }, token: token);
        if (!File.Exists(Path.Combine(profile, "mydrive-profile.json"))) throw new IOException("The myDrive Blip folder must be a myDrive profile. Use desktop Blip through its local connection, not its account folder.");
    }
    public async Task UseDesktopAsync(CancellationToken token = default)
    {
        await lifecycle.WaitAsync(token);
        try
        {
            if (UsesDesktopSession){if(IsRunning)return;attachedSocket=null;}
            if (IsRunning) throw new IOException("Stop myDrive's separate Blip engine before connecting to desktop Blip.");
            await PrepareAsync(token);
            // A managed helper joins Blip's native host election using the existing device.
            // Desktop Blip can quit or reopen; the native mutex prevents competing writers.
            stopping=false;
            var process=NewProcess("desktop-serve");var ready=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            host?.Dispose();host=process;process.Start();observer=ObserveHost(process,ready);
            JsonElement status;
            try {await ready.Task.WaitAsync(TimeSpan.FromSeconds(20),token);status=await CommandAsync("status",new[]{"--socket",desktopSocket},token:token);
                if(!status.TryGetProperty("desktop_session",out var desktop)||desktop.ValueKind!=JsonValueKind.True)throw new IOException("Desktop identity could not be verified.");}
            catch {await StopOwned(process);throw new IOException("Background Blip could not start. Open and sign in to Blip once, then reconnect myDrive.");}
            attachedSocket = desktopSocket; LastError = "";
        }
        finally { lifecycle.Release(); }
    }
    private async Task ObserveHost(Process process, TaskCompletionSource ready)
    {
        async Task ReadEvents()
        {
            while (await process.StandardOutput.ReadLineAsync() is { } line)
            {
                if (line.Length > 65536) throw new IOException("Unexpected Blip event size.");
                try
                {
                    using var message = JsonDocument.Parse(line);
                    if (!message.RootElement.TryGetProperty("event", out var name)) continue;
                    if (name.GetString() == "host_ready") ready.TrySetResult();
                    if (name.GetString() == "receive_policy_unconfirmed") LastError = "Blip stopped because its receiving settings could not be verified. Refresh before testing a transfer.";
                }
                catch (JsonException) { }
            }
        }
        var events = ReadEvents(); var errors = ReadBounded(process.StandardError, CancellationToken.None);
        try
        {
            await process.WaitForExitAsync(); await events; await errors;
            if (!stopping && process.ExitCode != 0 && LastError.Length == 0) LastError = "Blip's background engine stopped. Your existing files are kept; start it again to check transfer status.";
        }
        catch { KillOwned(process); if (!stopping) LastError = "The Blip engine stopped unexpectedly."; }
        finally { ready.TrySetException(new IOException("Blip exited before it was ready.")); }
    }
    private static async Task StopOwned(Process process)
    {
        try
        {
            if (process.HasExited) return;
            await process.StandardInput.WriteLineAsync("STOP"); await process.StandardInput.FlushAsync(); process.StandardInput.Close();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
        }
        catch { KillOwned(process); try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(3)); } catch { } }
    }
    public async Task StopAsync()
    {
        await lifecycle.WaitAsync();
        try
        {
            stopping = true;
            attachedSocket = null;
            if (host is { } process) { await StopOwned(process); if (observer != null) await observer; process.Dispose(); host = null; }
        }
        finally { lifecycle.Release(); }
    }
    private void RequireRunning() { if (!IsRunning) throw new IOException("Start Blip in Transfers first."); }
    public async Task<BlipSnapshot> PollAsync(CancellationToken token = default)
    {
        RequireRunning();
        var data = await CommandAsync("poll", token: token);
        return new(data.GetProperty("status").Deserialize<BlipStatus>() ?? new(), data.TryGetProperty("devices",out var devices)?devices.Deserialize<List<BlipDevice>>()??new():new(), data.GetProperty("transfers").Deserialize<List<BlipTransfer>>() ?? new());
    }
    public async Task<BlipSnapshot> SnapshotAsync(CancellationToken token = default)
    {
        return await PollAsync(token);
    }
    public async Task LoginAsync(string email, CancellationToken token = default)
    {
        RequireRunning();
        if (UsesDesktopSession) throw new IOException("Manage sign-in in the Blip desktop app.");
        if (!System.Net.Mail.MailAddress.TryCreate(email, out var parsed) || parsed.Address != email) throw new IOException("Enter a valid Blip email address.");
        await CommandAsync("login", new[] { "--email", email }, token: token);
    }
    public async Task VerifyAsync(string code, CancellationToken token = default)
    {
        RequireRunning(); if (UsesDesktopSession) throw new IOException("Manage sign-in in the Blip desktop app.");
        if (!Regex.IsMatch(code, "^[a-zA-Z0-9-]{4,16}$")) throw new IOException("Enter the sign-in code from Blip.");
        await CommandAsync("verify", input: code + "\n", token: token);
    }
    public static void ValidatePeer(string peer)
    {
        var parts = peer.Split(':'); if (parts.Length != 2 || !parts.All(p => Guid.TryParseExact(p, "D", out _))) throw new IOException("Select an exact Blip device before sending.");
    }
    public async Task<string> SendAsync(string peer, IReadOnlyList<string> files, CancellationToken token = default, string? requestId = null)
    {
        RequireRunning(); ValidatePeer(peer); if (files.Count == 0 || files.Any(p => !File.Exists(p) && !Directory.Exists(p))) throw new IOException("Select existing files or a folder.");
        // No automatic retries: interruption after dispatch has an uncertain outcome.
        var args = new List<string> { "--peer", peer, "--execute" };
        if (requestId != null) {
            if (!Guid.TryParseExact(requestId, "D", out _)) throw new IOException("Invalid relay transfer identifier.");
            args.AddRange(new[] { "--id", requestId });
        }
        args.Add("--");
        args.AddRange(files.Select(Path.GetFullPath));
        var response = await CommandAsync("send", args, token: token);
        return response.GetProperty("transfer_id").GetString() ?? throw new IOException("Blip did not provide a transfer identifier. Refresh before retrying.");
    }
    public async Task AcceptAsync(string id, CancellationToken token = default)
    {
        RequireRunning(); if (!Guid.TryParseExact(id, "D", out _)) throw new IOException("Select a pending incoming transfer.");
        await CommandAsync("accept", new[] { "--id", id, "--execute" }, token: token);
    }
    public async Task TrustAsync(string peer, CancellationToken token = default)
    {
        RequireRunning(); if (UsesDesktopSession) throw new IOException("Manage automatic receiving in the Blip desktop app.");
        ValidatePeer(peer); await CommandAsync("trust", new[] { "--peer", peer }, token: token);
    }
    public async ValueTask DisposeAsync() => await StopAsync();
}
