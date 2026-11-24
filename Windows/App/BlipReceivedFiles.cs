using System.Text;

namespace MyDrive;

public static class BlipReceivedFiles {
    public static string? LocalPath(BlipTransfer transfer,BlipReceivedItem item) {
        if(transfer.Direction!="Incoming"||!transfer.ConfirmedComplete||!transfer.ReceivedItems.Any(i=>i.Path==item.Path))return null;
        try {
            string path=item.Path;
            if(Uri.TryCreate(path,UriKind.Absolute,out var uri)&&uri.IsFile){if(uri.IsUnc||uri.Host.Length>0)return null;path=uri.LocalPath;}
            if(!System.IO.Path.IsPathFullyQualified(path)||path.StartsWith(@"\\")||path.StartsWith("//")||path.Any(char.IsControl))return null;
            path=System.IO.Path.GetFullPath(path);
            if(!(item.IsDirectory?Directory.Exists(path):File.Exists(path)))return null;
            for(FileSystemInfo? entry=item.IsDirectory?new DirectoryInfo(path):new FileInfo(path);entry!=null;entry=entry is FileInfo file?file.Directory:((DirectoryInfo)entry).Parent)
                if((entry.Attributes&FileAttributes.ReparsePoint)!=0)return null;
            return path;
        }catch{return null;}
    }
    public static bool IsText(string path)=>new[]{".txt",".md",".csv",".json",".xml",".log",".yml",".yaml",".ini",".css",".html",".htm",".svg",".js",".ts",".cs",".swift",".py",".rs"}.Contains(System.IO.Path.GetExtension(path).ToLowerInvariant());
    public static bool IsImage(string path)=>new[]{".png",".jpg",".jpeg",".gif",".bmp",".webp",".tif",".tiff",".heic",".avif"}.Contains(System.IO.Path.GetExtension(path).ToLowerInvariant());
    public static bool IsShortcut(string path)=>new[]{".url",".webloc"}.Contains(System.IO.Path.GetExtension(path).ToLowerInvariant());
    internal static async Task<string?> ClipboardTextAsync(string path)
    {
        const int limit = 16 * 1024 * 1024;
        if (!IsText(path)) return null;
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            4096, FileOptions.Asynchronous);
        long size = file.Length;
        if (size > limit) return null;
        var bytes = new byte[(int)size];
        await file.ReadExactlyAsync(bytes);
        if (file.ReadByte() != -1) return null;

        static bool StartsWith(byte[] data, params byte[] prefix) => data.AsSpan().StartsWith(prefix);
        (Encoding encoding, int prefixLength) = bytes switch
        {
            _ when StartsWith(bytes, 0xff, 0xfe, 0, 0) => (new UTF32Encoding(false, false, true), 4),
            _ when StartsWith(bytes, 0, 0, 0xfe, 0xff) => (new UTF32Encoding(true, false, true), 4),
            _ when StartsWith(bytes, 0xff, 0xfe) => (new UnicodeEncoding(false, false, true), 2),
            _ when StartsWith(bytes, 0xfe, 0xff) => (new UnicodeEncoding(true, false, true), 2),
            _ when StartsWith(bytes, 0xef, 0xbb, 0xbf) => (new UTF8Encoding(false, true), 3),
            _ => (new UTF8Encoding(false, true), 0)
        };
        try
        {
            string text = encoding.GetString(bytes, prefixLength, bytes.Length - prefixLength);
            return text.Contains('\0') ? null : text;
        }
        catch (DecoderFallbackException) { return null; }
    }

    public static async Task<string> TextPreviewAsync(string path) {
        await using var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite,4096,FileOptions.Asynchronous);
        using var reader=new StreamReader(stream,System.Text.Encoding.UTF8,true);
        var buffer=new char[4096];int count=await reader.ReadAsync(buffer);
        string text=new(buffer,0,count);if(text.Contains('\0'))return "Preview unavailable";
        return string.Join("\n",text.Replace("\r\n","\n").Split('\n').Take(6));
    }
}
