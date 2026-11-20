using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
namespace MyDrive;
public static class CredentialStore
{
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct Credential { public uint Flags,Type;public string TargetName,Comment;public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;public uint CredentialBlobSize;public IntPtr CredentialBlob;public uint Persist,AttributeCount;public IntPtr Attributes;public string TargetAlias,UserName; }
    [DllImport("advapi32.dll",EntryPoint="CredWriteW",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool CredWrite(ref Credential credential,uint flags);
    [DllImport("advapi32.dll",EntryPoint="CredReadW",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool CredRead(string target,uint type,uint flags,out IntPtr credential);
    [DllImport("advapi32.dll",EntryPoint="CredDeleteW",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool CredDelete(string target,uint type,uint flags);
    [DllImport("advapi32.dll")] private static extern void CredFree(IntPtr buffer);
    public static void Save(string id,string user,Credentials secrets)
    {
        byte[] bytes=Encoding.UTF8.GetBytes(JsonSerializer.Serialize(secrets));
        if(bytes.Length>2560)throw new IOException("The credential is too large for Windows Credential Manager.");
        var memory=Marshal.AllocCoTaskMem(bytes.Length);
        try {Marshal.Copy(bytes,0,memory,bytes.Length);var c=new Credential{Type=1,TargetName=$"myDrive/{id}",Comment="myDrive connection",CredentialBlobSize=(uint)bytes.Length,CredentialBlob=memory,Persist=2,UserName=user,TargetAlias=""};if(!CredWrite(ref c,0))throw new Win32Exception(Marshal.GetLastWin32Error());}
        finally {Marshal.Copy(new byte[bytes.Length],0,memory,bytes.Length);Marshal.FreeCoTaskMem(memory);Array.Clear(bytes);}
    }
    public static Credentials Read(string id)
    {
        if(!CredRead($"myDrive/{id}",1,0,out var pointer)){var error=Marshal.GetLastWin32Error();if(error==1168)return new();throw new Win32Exception(error);}
        try {var c=Marshal.PtrToStructure<Credential>(pointer);var bytes=new byte[c.CredentialBlobSize];Marshal.Copy(c.CredentialBlob,bytes,0,bytes.Length);try{return JsonSerializer.Deserialize<Credentials>(bytes)??new();}finally{Array.Clear(bytes);}}
        finally {CredFree(pointer);}
    }
    public static void Delete(string id){if(!CredDelete($"myDrive/{id}",1,0)&&Marshal.GetLastWin32Error()!=1168)throw new Win32Exception(Marshal.GetLastWin32Error());}
}
