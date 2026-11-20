using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;
namespace MyDrive;

internal sealed record BlipClipboardPayload(List<string> Paths,string Description,string? StagingDirectory=null,string? OutboxRoot=null)
{
    // Cancel removes only our one generated file; copied user files are never removed.
    public void Discard() {
        if(StagingDirectory==null)return;
        string root=Path.GetFullPath(OutboxRoot??BlipClipboard.Outbox)+Path.DirectorySeparatorChar;
        string stage=Path.GetFullPath(StagingDirectory);
        if(!stage.StartsWith(root,StringComparison.OrdinalIgnoreCase)||Path.GetDirectoryName(stage)!=root.TrimEnd(Path.DirectorySeparatorChar)||!Guid.TryParseExact(Path.GetFileName(stage),"N",out _))return;
        foreach(string path in Paths)if(Path.GetDirectoryName(Path.GetFullPath(path))==stage&&File.Exists(path))File.Delete(path);
        if(Directory.Exists(stage)&&!Directory.EnumerateFileSystemEntries(stage).Any())Directory.Delete(stage,false);
    }
}
internal static class BlipClipboard
{
    internal static string Outbox=>Path.Combine(CoreBridge.DataDir,"Blip","outbox");
    internal static async Task<BlipClipboardPayload> PrepareTextAsync(string text,string outbox) {
        string directory=Path.Combine(outbox,Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var lines = text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Trim()).Where(line => line.Length > 0).Take(17).ToList();
        bool web = lines.Count is > 0 and <= 16 && lines.All(line => line.Length <= 8192 &&
            !line.Any(char.IsControl) && !line.Contains('\\') && !line.Any(char.IsWhiteSpace) &&
            Uri.TryCreate(line, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" &&
            uri.Host.Length > 0 && uri.UserInfo.Length == 0);
        var files = web ? lines.Select((_, index) => Path.Combine(directory,
            lines.Count == 1 ? "Clipboard link.url" : $"Clipboard link {index + 1:00}.url")).ToList()
            : new List<string>{Path.Combine(directory, "Clipboard text.txt")};
        var description = web ? lines.Count == 1 ? "Web link from clipboard" : $"{lines.Count} web links from clipboard"
            : $"Clipboard text · {text.Length:N0} characters";
        var payload = new BlipClipboardPayload(files, description, directory, outbox);
        try {
            for (int index = 0; index < files.Count; index++)
                await File.WriteAllTextAsync(files[index], web ? "[InternetShortcut]\r\nURL=" + lines[index] + "\r\n" : text);
            return payload;
        }
        catch{payload.Discard();throw;}
    }
    public static async Task<BlipClipboardPayload> ReadAsync() {
        var clipboard=Clipboard.GetContent();
        if(clipboard.Contains(StandardDataFormats.StorageItems)) {
            var items=await clipboard.GetStorageItemsAsync();var paths=items.Select(i=>i.Path).Where(p=>!string.IsNullOrEmpty(p)&&(File.Exists(p)||Directory.Exists(p))).ToList();
            if(paths.Count>0)return new(paths,paths.Count==1?Path.GetFileName(paths[0]):$"{paths.Count} copied files or folders");
        }
        string? text=null;
        if(clipboard.Contains(StandardDataFormats.WebLink))text=(await clipboard.GetWebLinkAsync()).AbsoluteUri;
        else if(clipboard.Contains(StandardDataFormats.Text))text=await clipboard.GetTextAsync();
        if(!string.IsNullOrEmpty(text))return await PrepareTextAsync(text,Outbox);
        if(clipboard.Contains(StandardDataFormats.Bitmap)) {
            string directory=Path.Combine(Outbox,Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);string file=Path.Combine(directory,"Clipboard image.png");
            var payload=new BlipClipboardPayload(new(){file},"Image from clipboard",directory,Outbox);
            try {
            using var input=await (await clipboard.GetBitmapAsync()).OpenReadAsync();var decoder=await BitmapDecoder.CreateAsync(input);using var bitmap=await decoder.GetSoftwareBitmapAsync();
            // Create the output before opening a WinRT image stream.
            using(File.Create(file)){}
            var storage=await StorageFile.GetFileFromPathAsync(file);using var output=await storage.OpenAsync(FileAccessMode.ReadWrite);var encoder=await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId,output);encoder.SetSoftwareBitmap(bitmap);await encoder.FlushAsync();
            return payload;
            }catch{payload.Discard();throw;}
        }
        throw new IOException("The clipboard has no supported text, web link, image, files or folder. Copy something first, then choose Paste and send.");
    }
}
