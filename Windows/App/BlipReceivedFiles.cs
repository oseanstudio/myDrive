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
    public static async Task<string> TextPreviewAsync(string path) {
        await using var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite,4096,FileOptions.Asynchronous);
        using var reader=new StreamReader(stream,System.Text.Encoding.UTF8,true);
        var buffer=new char[4096];int count=await reader.ReadAsync(buffer);
        string text=new(buffer,0,count);if(text.Contains('\0'))return "Preview unavailable";
        return string.Join("\n",text.Replace("\r\n","\n").Split('\n').Take(6));
    }
}
