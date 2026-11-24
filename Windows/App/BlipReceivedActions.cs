using System.Runtime.InteropServices;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;
using Windows.System;
namespace MyDrive;

internal enum BlipFileAction {Open,OpenWith,Copy,CopyFile,CopyPath,OpenFolder,ShowInFolder,CopyListedFiles,CopyListedPaths}
internal static class BlipReceivedActions {
    private static string Require(BlipTransfer transfer,BlipReceivedItem item)=>BlipReceivedFiles.LocalPath(transfer,item)??throw new IOException("This received file is unavailable or has moved.");
    private static async Task<IStorageItem> StorageItem(BlipReceivedItem item,string path)=>item.IsDirectory?await StorageFolder.GetFolderFromPathAsync(path):await StorageFile.GetFileFromPathAsync(path);
    internal static async Task<DataPackage> CopyData(BlipFileAction action, BlipTransfer transfer, BlipReceivedItem item, string path)
    {
        var data = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
        if (action == BlipFileAction.Copy && !item.IsDirectory &&
            await BlipReceivedFiles.ClipboardTextAsync(path) is { } text)
        {
            data.SetText(text);
            return data;
        }

        BlipReceivedItem[] chosen = action == BlipFileAction.CopyListedFiles ? transfer.ReceivedItems.Take(256).ToArray() : [item];
        var items = new List<IStorageItem>();
        foreach (var entry in chosen) items.Add(await StorageItem(entry, Require(transfer, entry)));
        data.SetStorageItems(items);
        if (chosen.Length == 1 && !item.IsDirectory)
        {
            var file = (StorageFile)items[0];
            if (BlipReceivedFiles.IsImage(path)) data.SetBitmap(RandomAccessStreamReference.CreateFromFile(file));
            if (BlipReceivedFiles.IsShortcut(path) && await BlipLinkOpener.ReadShortcutAsync(path) is { } url)
            {
                data.SetText(url.AbsoluteUri);
                data.SetWebLink(url);
            }
        }
        return data;
    }

    public static async Task Execute(BlipFileAction action,BlipTransfer transfer,BlipReceivedItem item,nint owner) {
        string path=Require(transfer,item);
        if(action==BlipFileAction.CopyPath||action==BlipFileAction.CopyListedPaths) {
            var data=new DataPackage();data.SetText(action==BlipFileAction.CopyPath?path:string.Join(Environment.NewLine,transfer.ReceivedItems.Take(256).Select(i=>Require(transfer,i))));Clipboard.SetContent(data);Clipboard.Flush();return;
        }
        if(action is BlipFileAction.Copy or BlipFileAction.CopyFile or BlipFileAction.CopyListedFiles) {
            Clipboard.SetContent(await CopyData(action,transfer,item,path));Clipboard.Flush();return;
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
        throw new IOException("The selected file action is unavailable.");
    }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]private struct OpenAsInfo{[MarshalAs(UnmanagedType.LPWStr)]public string File;[MarshalAs(UnmanagedType.LPWStr)]public string? Class;public uint Flags;}
    [DllImport("shell32.dll",CharSet=CharSet.Unicode)]private static extern int SHOpenWithDialog(nint owner,ref OpenAsInfo info);
}
