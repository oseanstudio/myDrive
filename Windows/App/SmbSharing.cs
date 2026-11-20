using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace MyDrive;

internal sealed class SmbShareHost : IDisposable
{
    internal sealed record Share(string Name, string Host, string Username, string Password, bool Writable)
    {
        public string Address => @"\\" + (Host.StartsWith('[') ?
            Host.Trim('[', ']').Replace(':', '-') + ".ipv6-literal.net" : Host) + "\\" + Name;

        public override string ToString() => Name;
    }

    internal sealed record Reply(string? Error, Share? Share, List<Share>? Shares);

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly SemaphoreSlim requests = new(1, 1);
    private Process? process;
    private bool disposed;

    public async Task<Reply> Call(object command, bool start = false)
    {
        await requests.WaitAsync();
        try
        {
            if (disposed) throw new ObjectDisposedException(nameof(SmbShareHost));
            if (process?.HasExited == true) ClosePipe();
            if (process is null && !start) return new Reply(null, null, null);
            process ??= Start();
            Reply reply;
            try
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(35));
                await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(command).AsMemory(), deadline.Token);
                var line = await process.StandardOutput.ReadLineAsync(deadline.Token);
                reply = line is null ? throw new IOException() : JsonSerializer.Deserialize<Reply>(line, Json)
                    ?? throw new IOException();
            }
            catch (Exception error) when (error is IOException or JsonException or OperationCanceledException or ObjectDisposedException)
            {
                ClosePipe();
                throw new IOException("The private SMB host stopped. Open SMB Storage and try again.");
            }
            if (reply.Error is not null) throw new IOException(reply.Error);
            return reply;
        }
        finally { requests.Release(); }
    }

    private static Process Start()
    {
        var executable = Path.Combine(AppContext.BaseDirectory, "mydrive-smb-host.exe");
        if (!File.Exists(executable)) throw new IOException("The SMB host is missing. Install the latest myDrive build.");
        return Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false)
        }) ?? throw new IOException("myDrive could not start its private SMB host.");
    }

    private void ClosePipe()
    {
        var child = process;
        process = null;
        if (child is null) return;
        try { child.StandardInput.Close(); }
        catch (IOException) { }
        child.Dispose();
    }

    public void Dispose()
    {
        disposed = true;
        ClosePipe();
    }
}

public sealed partial class MainWindow
{
    private readonly SmbShareHost smbHosting = new();

    private async Task CreatePrivateShare(string? folder = null)
    {
        if (busy || modalDepth > 0) return;
        try
        {
            if (folder is null)
            {
                var picker = new FolderPicker();
                InitializeWithWindow.Initialize(picker, hwnd);
                picker.FileTypeFilter.Add("*");
                var selected = await Modal(async () => await picker.PickSingleFolderAsync());
                if (selected is null) return;
                folder = selected.Path;
            }

            var suggested = new string(Path.GetFileName(folder.TrimEnd('\\', '/'))
                .Where(c => char.IsAsciiLetterOrDigit(c) || c is ' ' or '-' or '_').ToArray()).Trim();
            if (suggested.Length == 0 || !char.IsAsciiLetterOrDigit(suggested[0])) suggested = "Shared folder";
            var name = new TextBox { Header = "Share name", Text = suggested[..Math.Min(suggested.Length, 63)], MaxLength = 63 };
            var write = new CheckBox { Content = "Allow changes to files" };
            var form = new StackPanel { Spacing = 8 };
            form.Children.Add(Text("Your Tailscale devices can connect while myDrive is running.", 12));
            form.Children.Add(name);
            form.Children.Add(write);
            if (await ShowDialog(new ContentDialog
            {
                XamlRoot = root.XamlRoot,
                Title = "Share over encrypted SMB",
                Content = form,
                PrimaryButtonText = "Share",
                CloseButtonText = "Cancel"
            }) != ContentDialogResult.Primary) return;

            var created = await smbHosting.Call(new { action = "add", folder, name = name.Text.Trim(), writable = write.IsChecked == true }, start: true);
            if (created.Share is { } share) await ShowPrivateShares([share], manage: false);
        }
        catch (Exception error) { Error(error); }
    }

    private async Task ManagePrivateShares()
    {
        if (busy || modalDepth > 0) return;
        try
        {
            var result = await smbHosting.Call(new { action = "list" });
            await ShowPrivateShares(result.Shares ?? [], manage: true);
        }
        catch (Exception error) { Error(error); }
    }

    private async Task ShowPrivateShares(IReadOnlyList<SmbShareHost.Share> shares, bool manage)
    {
        var content = new StackPanel { Spacing = 8 };
        if (shares.Count == 0) content.Children.Add(Text("This session has no active SMB shares.", 12));
        foreach (var share in shares)
        {
            content.Children.Add(Text(share.Name + (share.Writable ? " · Read and write" : " · Read-only"), 13, true));
            var path = Text(share.Address, 12);
            path.IsTextSelectionEnabled = true;
            content.Children.Add(path);
            content.Children.Add(Text("Username: " + share.Username, 12));
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            actions.Children.Add(QuickButton("Copy address", () => CopyShareText(share.Address)));
            actions.Children.Add(QuickButton("Copy password", () => CopyShareText(share.Password)));
            content.Children.Add(actions);
        }
        var dialog = new ContentDialog
        {
            XamlRoot = root.XamlRoot,
            Title = manage ? "Tailscale SMB shares" : "Folder shared over Tailscale",
            Content = new ScrollViewer { Content = content, MaxHeight = 246 },
            PrimaryButtonText = manage && shares.Count > 0 ? "Stop all shares" : "",
            CloseButtonText = "Done"
        };
        if (await ShowDialog(dialog) == ContentDialogResult.Primary)
        {
            await smbHosting.Call(new { action = "stop" });
            Info("Sharing stopped", "All myDrive SMB shares were closed.");
        }
    }

    private static void CopyShareText(string value)
    {
        var package = new DataPackage();
        package.SetText(value);
        Clipboard.SetContent(package);
    }
}
