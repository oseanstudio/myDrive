using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;

namespace MyDrive;

// New completed incoming shortcuts only. Never execute the received shortcut file itself.
public sealed class BlipLinkOpener
{
    private readonly string ledger;
    private readonly Func<Uri, Task> open;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly HashSet<string> handled;
    private string session = "";
    private int generation;
    public string LastError { get; private set; } = "";
    public int OpenedThisPass { get; private set; }
    public BlipLinkOpener(string ledgerPath, Func<Uri, Task>? browser = null)
    {
        ledger = ledgerPath; open = browser ?? OpenDefaultBrowser;
        try { handled = JsonSerializer.Deserialize<HashSet<string>>(File.ReadAllText(ledger)) ?? new(); }
        catch { handled = new(); }
    }
    public void ResetSession() { Interlocked.Increment(ref generation); session = ""; LastError = ""; }
    private static Task OpenDefaultBrowser(Uri url)
    {
        Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true });
        return Task.CompletedTask;
    }
    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    private void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(ledger))!);
        File.WriteAllText(ledger + ".tmp", JsonSerializer.Serialize(handled));
        File.Move(ledger + ".tmp", ledger, true);
    }
    public async Task ProcessAsync(BlipStatus status, IReadOnlyList<BlipTransfer> transfers, bool enabled, Func<BlipTransfer,bool>? permitted = null)
    {
        if (!status.Authenticated) return;
        await gate.WaitAsync();
        try
        {
            OpenedThisPass = 0;
            int currentGeneration = generation;
            string scope = Hash(status.UserId + ":" + status.DeviceId);
            var incoming = transfers.Where(t => t.Direction == "Incoming" && t.ConfirmedComplete && Guid.TryParseExact(t.Id, "D", out _)).ToList();
            // A fresh attachment is a baseline, not a reason to reopen transfer history.
            if (session != scope || !enabled)
            {
                bool changed = false;
                foreach (var transfer in incoming) changed |= handled.Add(Hash(scope + ":skip:" + transfer.Id));
                if (changed) Save();
                session = scope; return;
            }
            foreach (var transfer in incoming)
            {
                if (handled.Contains(Hash(scope + ":skip:" + transfer.Id))) continue;
                if (permitted?.Invoke(transfer) != true) { handled.Add(Hash(scope + ":skip:" + transfer.Id)); Save(); continue; }
                foreach (var file in transfer.LinkFiles.Take(256))
                {
                    string fileKey = Hash(scope + ":file:" + transfer.Id + ":" + file);
                    if (handled.Contains(fileKey)) continue;
                    var url = await ReadShortcutAsync(file);
                    if (currentGeneration != generation) return;
                    if (url == null) continue;
                    string key = Hash(scope + ":link:" + transfer.Id + ":" + url.AbsoluteUri);
                    if (!handled.Add(key)) { handled.Add(fileKey); Save(); continue; }
                    handled.Add(fileKey);
                    try { Save(); }
                    catch { handled.Remove(key); handled.Remove(fileKey); throw; }
                    // Persist the claim first: a failed/uncertain browser request must not replay every poll.
                    try { await open(url); OpenedThisPass++; LastError = ""; }
                    catch { LastError = "A received link could not open. Open its shortcut from Received files or Blip's download folder."; }
                }
            }
        }
        catch { LastError = "Received links could not be checked. Check the Blip download folder and local app-data access."; }
        finally { gate.Release(); }
    }
    public static async Task<Uri?> ReadShortcutAsync(string location)
    {
        try
        {
            string file = location;
            if (Uri.TryCreate(location, UriKind.Absolute, out var source) && source.IsFile)
            { if (source.IsUnc || !string.IsNullOrEmpty(source.Host)) return null; file = source.LocalPath; }
            if (!Path.IsPathFullyQualified(file) || file.StartsWith(@"\\") || file.StartsWith("//")) return null;
            string extension = Path.GetExtension(file).ToLowerInvariant();
            if (extension is not ".url" and not ".webloc") return null;
            // Reject redirected file/directory entries; never follow a received symlink or junction.
            for (FileSystemInfo? item = new FileInfo(file); item != null; item = item is FileInfo f ? f.Directory : ((DirectoryInfo)item).Parent)
                if ((item.Attributes & FileAttributes.ReparsePoint) != 0) return null;
            await using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.Asynchronous);
            if (stream.Length is <= 0 or > 65536) return null;
            using var reader = new StreamReader(stream, Encoding.UTF8, true);
            string text = await reader.ReadToEndAsync();
            string? value = null;
            if (extension == ".url")
            {
                bool section = false;
                foreach (string raw in text.Split('\n'))
                {
                    string line = raw.Trim();
                    if (line.StartsWith('[')) { section = line.Equals("[InternetShortcut]", StringComparison.OrdinalIgnoreCase); continue; }
                    if (!section || line.StartsWith(';') || line.StartsWith('#')) continue;
                    int split = line.IndexOf('=');
                    if (split >= 0 && line[..split].Trim().Equals("URL", StringComparison.OrdinalIgnoreCase))
                    { if (value != null) return null; value = line[(split + 1)..].Trim(); }
                }
            }
            else
            {
                // Apple web locations include a public plist DOCTYPE. Ignore it without resolving entities.
                using var xml = XmlReader.Create(new StringReader(text), new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null, MaxCharactersInDocument = 65536 });
                var doc = XDocument.Load(xml);
                var nodes = doc.Root?.Element("dict")?.Elements().ToList();
                if (nodes != null) for (int i = 0; i + 1 < nodes.Count; i++)
                    if (nodes[i].Name == "key" && nodes[i].Value == "URL" && nodes[i + 1].Name == "string")
                    { if (value != null) return null; value = nodes[i + 1].Value.Trim(); }
            }
            if (value == null || value.Length > 8192 || value.Any(char.IsControl) || value.Contains('\\')) return null;
            if (!Uri.TryCreate(value, UriKind.Absolute, out var url) || url.Scheme is not "http" and not "https" || string.IsNullOrWhiteSpace(url.Host) || url.UserInfo.Length != 0) return null;
            return url;
        }
        catch { return null; } // Missing, incomplete or unsupported shortcuts are never launched as files.
    }
}
