using System.Runtime.InteropServices;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;
using Windows.System;
namespace MyDrive;

internal enum BlipFileAction {Open,OpenWith,Copy,CopyPath,OpenFolder,ShowInFolder,Print,Properties,CopyListedFiles,CopyListedPaths}
internal static class BlipReceivedActions {
    private static string Require(BlipTransfer transfer,BlipReceivedItem item)=>BlipReceivedFiles.LocalPath(transfer,item)??throw new IOException("This received file is unavailable or has moved.");
    private static async Task<IStorageItem> StorageItem(BlipReceivedItem item,string path)=>item.IsDirectory?await StorageFolder.GetFolderFromPathAsync(path):await StorageFile.GetFileFromPathAsync(path);
    public static bool CanPrint(BlipReceivedItem item) {
        if(item.IsDirectory||BlipReceivedFiles.IsShortcut(item.Path))return false;
        try{uint size=0;AssocQueryString(0,1,Path.GetExtension(item.Path),"print",null,ref size);return size>1&&size<32768;}catch{return false;}
    }
    public static async Task Execute(BlipFileAction action,BlipTransfer transfer,BlipReceivedItem item,nint owner) {
        string path=Require(transfer,item);
        if(action==BlipFileAction.CopyPath||action==BlipFileAction.CopyListedPaths) {
            var data=new DataPackage();data.SetText(action==BlipFileAction.CopyPath?path:string.Join(Environment.NewLine,transfer.ReceivedItems.Take(256).Select(i=>Require(transfer,i))));Clipboard.SetContent(data);Clipboard.Flush();return;
        }
        if(action==BlipFileAction.Copy||action==BlipFileAction.CopyListedFiles) {
            var chosen=action==BlipFileAction.Copy?new[]{item}:transfer.ReceivedItems.Take(256).ToArray();
            var items=new List<IStorageItem>();foreach(var entry in chosen)items.Add(await StorageItem(entry,Require(transfer,entry)));
            var data=new DataPackage{RequestedOperation=DataPackageOperation.Copy};data.SetStorageItems(items);
            if(chosen.Length==1&&!item.IsDirectory) {
                var file=(StorageFile)items[0];
                if(BlipReceivedFiles.IsImage(path))data.SetBitmap(RandomAccessStreamReference.CreateFromFile(file));
                if(BlipReceivedFiles.IsShortcut(path)&&await BlipLinkOpener.ReadShortcutAsync(path) is {} url){data.SetText(url.AbsoluteUri);data.SetWebLink(url);}
            }
            Clipboard.SetContent(data);Clipboard.Flush();return;
        }
        if(action==BlipFileAction.Open) {
            bool opened;
            if(item.IsDirectory)opened=await Launcher.LaunchFolderAsync(await StorageFolder.GetFolderFromPathAsync(path));
            else if(BlipReceivedFiles.IsShortcut(path)){var url=await BlipLinkOpener.ReadShortcutAsync(path)??throw new IOException("This shortcut does not contain a supported web link.");opened=await Launcher.LaunchUriAsync(url);}
            else opened=await Launcher.LaunchFileAsync(await StorageFile.GetFileFromPathAsync(path));
            if(!opened)throw new IOException("The default app could not open this received item.");return;
        }
        if(action is BlipFileAction.OpenFolder or BlipFileAction.ShowInFolder) {
            string folder=action==BlipFileAction.OpenFolder&&item.IsDirectory?path:Path.GetDirectoryName(path)??path;
            var directory=await StorageFolder.GetFolderFromPathAsync(folder);var options=new FolderLauncherOptions();
            if(action==BlipFileAction.ShowInFolder)options.ItemsToSelect.Add(await StorageItem(item,path));
            if(!await Launcher.LaunchFolderAsync(directory,options))throw new IOException("The received folder could not open.");return;
        }
        if(action==BlipFileAction.OpenWith) {
            if(item.IsDirectory||BlipReceivedFiles.IsShortcut(path))throw new IOException("Choose Open for folders and web links.");
            var info=new OpenAsInfo{File=path,Flags=4};int result=SHOpenWithDialog(owner,ref info);
            if(result<0&&result!=unchecked((int)0x800704C7))Marshal.ThrowExceptionForHR(result);return;
        }
        var shell=new ShellExecuteInfo{Size=(uint)Marshal.SizeOf<ShellExecuteInfo>(),Mask=0xC,Owner=owner,Verb=action==BlipFileAction.Print?"print":"properties",File=path,Show=1};
        if(!ShellExecuteEx(ref shell))throw new IOException("The selected file action is unavailable.");
    }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]private struct OpenAsInfo{[MarshalAs(UnmanagedType.LPWStr)]public string File;[MarshalAs(UnmanagedType.LPWStr)]public string? Class;public uint Flags;}
    [DllImport("shell32.dll",CharSet=CharSet.Unicode)]private static extern int SHOpenWithDialog(nint owner,ref OpenAsInfo info);
    [DllImport("shlwapi.dll",CharSet=CharSet.Unicode,EntryPoint="AssocQueryStringW")]private static extern int AssocQueryString(uint flags,uint text,string association,string extra,System.Text.StringBuilder? output,ref uint count);
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]private struct ShellExecuteInfo {
        public uint Size,Mask;public nint Owner;[MarshalAs(UnmanagedType.LPWStr)]public string? Verb;[MarshalAs(UnmanagedType.LPWStr)]public string? File;[MarshalAs(UnmanagedType.LPWStr)]public string? Parameters;[MarshalAs(UnmanagedType.LPWStr)]public string? Directory;public int Show;public nint Instance,IdList;[MarshalAs(UnmanagedType.LPWStr)]public string? Class;public nint ClassKey;public uint HotKey;public nint Icon,Process;
    }
    [DllImport("shell32.dll",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="ShellExecuteExW")][return:MarshalAs(UnmanagedType.Bool)]private static extern bool ShellExecuteEx(ref ShellExecuteInfo info);
}
