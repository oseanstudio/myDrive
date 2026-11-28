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
    internal static bool IsText(BlipReceivedItem item, string? path = null) =>
        !item.IsDirectory && (IsText(item.Name) || IsText(path ?? item.Path));

    internal static async Task<string?> ClipboardTextAsync(string path)
    {
        const int limit = 16 * 1024 * 1024;
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            4096, FileOptions.Asynchronous);
        long size = file.Length;
        if (size > limit) return null;
        var bytes = new byte[(int)size];
        await file.ReadExactlyAsync(bytes);
        if (file.ReadByte() != -1) return null;

        static bool StartsWith(byte[] data, params byte[] prefix) => data.AsSpan().StartsWith(prefix);
        var utf8 = new UTF8Encoding(false, true);
        var littleEndian = new UnicodeEncoding(false, false, true);
        var bigEndian = new UnicodeEncoding(true, false, true);
        (Encoding Decoder, int PrefixLength) format = bytes switch
        {
            _ when StartsWith(bytes, 0xff, 0xfe, 0, 0) => (new UTF32Encoding(false, false, true), 4),
            _ when StartsWith(bytes, 0, 0, 0xfe, 0xff) => (new UTF32Encoding(true, false, true), 4),
            _ when StartsWith(bytes, 0xff, 0xfe) => (littleEndian, 2),
            _ when StartsWith(bytes, 0xfe, 0xff) => (bigEndian, 2),
            _ when StartsWith(bytes, 0xef, 0xbb, 0xbf) => (utf8, 3),
            _ => (utf8, 0)
        };
        if (format.PrefixLength == 0 && bytes.Length % 2 == 0)
        {
            bool evenZero = false, oddZero = false;
            for (int i = 0; i < bytes.Length; i += 2)
            {
                evenZero |= bytes[i] == 0;
                oddZero |= bytes[i + 1] == 0;
                if (evenZero && oddZero) break;
            }
            if (evenZero != oddZero) format.Decoder = evenZero ? bigEndian : littleEndian;
        }
        string? Decode(Encoding? encoding, int prefix)
        {
            try { return encoding?.GetString(bytes, prefix, bytes.Length - prefix); }
            catch (DecoderFallbackException) { return null; }
        }

        var text = Decode(format.Decoder, format.PrefixLength);
        if (text == null && format.PrefixLength == 0 && format.Decoder == utf8 && !bytes.Contains((byte)0))
            text = Decode(CodePagesEncodingProvider.Instance.GetEncoding(1252), 0);
        return text != null && !text.Any(c => char.IsControl(c) && c is not ('\r' or '\n' or '\t' or '\f'))
            ? text : null;
    }

    public static async Task<string> TextPreviewAsync(string path) {
        await using var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite,4096,FileOptions.Asynchronous);
        using var reader=new StreamReader(stream,System.Text.Encoding.UTF8,true);
        var buffer=new char[4096];int count=await reader.ReadAsync(buffer);
        string text=new(buffer,0,count);if(text.Contains('\0'))return "Preview unavailable";
        return string.Join("\n",text.Replace("\r\n","\n").Split('\n').Take(12));
    }
}
