using System;
using System.IO;
using System.Collections.Generic;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ChatGPTtMigration {
 public sealed class FileRow {
  public string Relative; public long Length; public DateTime WriteUtc; public FileAttributes Attributes;
 }
 public sealed class Snapshot {
  public FileRow[] Files; public string[] Directories; public long Bytes;
 }
 public static class Engine {
  public static string Full(string path) { string p=Path.GetFullPath(path),r=Path.GetPathRoot(p);return p.TrimEnd('\\').Equals(r.TrimEnd('\\'),StringComparison.OrdinalIgnoreCase)?r:p.TrimEnd('\\'); }
  public static string Long(string path) {
   string p=Full(path); if(p.StartsWith(@"\\?\"))return p;
   if(p.StartsWith(@"\\"))throw new IOException("Only local paths are supported.");
   return @"\\?\"+p;
  }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,System.Text.StringBuilder buffer,uint size,uint flags);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern bool MoveFileEx(string source,string destination,uint flags);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern bool SetFileSecurity(string path,uint information,byte[] descriptor);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern bool GetFileSecurity(string path,uint information,byte[] descriptor,uint size,out uint needed);
  [DllImport("advapi32.dll",SetLastError=true)]
  static extern bool GetSecurityDescriptorControl(byte[] descriptor,out ushort control,out uint revision);
  public static void SetDacl(string path,byte[] descriptor) {
   // DACL only: do not request SACL/audit privileges that ordinary users do not have.
   if(!SetFileSecurity(Long(path),0x80000004,descriptor))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Cannot protect destination directory.");
  }
  static void CopyDacl(string source,string target) {
   uint needed;GetFileSecurity(source,4,null,0,out needed);
   if(needed==0)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Cannot read source access rules.");
   var descriptor=new byte[needed];
   if(!GetFileSecurity(source,4,descriptor,needed,out needed))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
   ushort control;uint revision;
   if(!GetSecurityDescriptorControl(descriptor,out control,out revision))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
   uint information=4u|(((control&0x1000)!=0)?0x80000000u:0x20000000u);
   if(!SetFileSecurity(target,information,descriptor))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Cannot preserve access rules.");
  }
  public static string Canonical(string path) {
   using(var h=CreateFile(Long(path),0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
    if(h.IsInvalid)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),path);
    var b=new System.Text.StringBuilder(32768); uint n=GetFinalPathNameByHandle(h,b,(uint)b.Capacity,0);
    if(n==0 || n>=b.Capacity)throw new IOException("Cannot resolve path: "+path);
    return Full(b.ToString().Replace(@"\\?\",""));
   }
  }
  public static bool IsLink(string path) { return (File.GetAttributes(Long(path))&FileAttributes.ReparsePoint)!=0; }
  public static Snapshot Scan(string path,Action<string,int,int,string> progress) {
   string root=Long(path);var pending=new Queue<string>();pending.Enqueue(root);
   var files=new List<FileRow>();var dirs=new List<string>();long bytes=0;var timer=Stopwatch.StartNew();
   while(pending.Count>0) {
    foreach(string child in Directory.GetFileSystemEntries(pending.Dequeue())) {
     FileAttributes a=File.GetAttributes(child);
     if((a&FileAttributes.ReparsePoint)!=0)throw new IOException("Nested link or cloud placeholder needs manual handling: "+child);
     string relative=child.Substring(root.Length).TrimStart('\\');
     if((a&FileAttributes.Directory)!=0){dirs.Add(relative);pending.Enqueue(child);}
     else {var f=new FileInfo(child);files.Add(new FileRow{Relative=relative,Length=f.Length,WriteUtc=f.LastWriteTimeUtc,Attributes=a});bytes+=f.Length;}
     if(progress!=null && timer.ElapsedMilliseconds>=500){progress("scanning",files.Count,0,relative);timer.Restart();}
    }
   }
   if(progress!=null)progress("scanning",files.Count,files.Count,"");
   return new Snapshot{Files=files.ToArray(),Directories=dirs.ToArray(),Bytes=bytes};
  }
  public static void Copy(string source,string destination,Action<string,int,int,string> progress) {
   Snapshot s=Scan(source,null);string root=Long(destination);Directory.CreateDirectory(root);
   if(IsLink(destination))throw new IOException("Destination root is a link.");
   Scan(destination,null); // Reject links in a partial copy before overwriting anything.
   foreach(string d in s.Directories)Directory.CreateDirectory(Path.Combine(root,d));
   var timer=Stopwatch.StartNew();int count=0;
   if(progress!=null)progress("copying",0,s.Files.Length,"");
   foreach(FileRow f in s.Files) {
    string from=Path.Combine(Long(source),f.Relative),to=Path.Combine(root,f.Relative);
    Directory.CreateDirectory(Path.GetDirectoryName(to));
    if(File.Exists(to))File.SetAttributes(to,File.GetAttributes(to)&~FileAttributes.ReadOnly);
    File.Copy(from,to,true);
    File.SetAttributes(to,File.GetAttributes(to)&~FileAttributes.ReadOnly);
    File.SetLastWriteTimeUtc(to,f.WriteUtc);File.SetAttributes(to,f.Attributes);CopyDacl(from,to);count++;
    if(progress!=null && timer.ElapsedMilliseconds>=500){progress("copying",count,s.Files.Length,f.Relative);timer.Restart();}
   }
   foreach(string d in s.Directories)CopyDacl(Path.Combine(Long(source),d),Path.Combine(root,d));
   if(progress!=null)progress("copying",count,s.Files.Length,"");
  }
  public static long Verify(string source,string destination,Action<string,int,int,string> progress) {
   Snapshot a=Scan(source,null),b=Scan(destination,null);
   if(a.Files.Length!=b.Files.Length)throw new IOException("File count mismatch: "+a.Files.Length+" / "+b.Files.Length);
   var directories=new HashSet<string>(a.Directories,StringComparer.OrdinalIgnoreCase);
   if(!directories.SetEquals(b.Directories))throw new IOException("Directory structure mismatch.");
   var timer=Stopwatch.StartNew();int count=0;
   using(var sha=SHA256.Create()) {
    foreach(FileRow row in a.Files) {
     string p=Path.Combine(Long(source),row.Relative),q=Path.Combine(Long(destination),row.Relative);
     var other=new FileInfo(q);if(!other.Exists || other.Length!=row.Length)throw new IOException("Missing file or size mismatch: "+row.Relative);
     byte[] first,second;
     // Read-sharing is deliberately strict: existing writers must exit before migration.
     using(var stream=new FileStream(p,FileMode.Open,FileAccess.Read,FileShare.Read))first=sha.ComputeHash(stream);
     using(var stream=new FileStream(q,FileMode.Open,FileAccess.Read,FileShare.Read))second=sha.ComputeHash(stream);
     for(int i=0;i<first.Length;i++)if(first[i]!=second[i])throw new IOException("SHA256 mismatch: "+row.Relative);
     var refreshed=new FileInfo(p);
     if(refreshed.Length!=row.Length || refreshed.LastWriteTimeUtc!=row.WriteUtc)throw new IOException("Source changed during verification: "+row.Relative);
     count++;
     if(progress!=null && timer.ElapsedMilliseconds>=500){progress("verifying",count,a.Files.Length,row.Relative);timer.Restart();}
    }
   }
   if(progress!=null)progress("verifying",count,a.Files.Length,"");return a.Bytes;
  }
  public static void MoveDirectory(string source,string destination) {
   if(!MoveFileEx(Long(source),Long(destination),8))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Directory switch failed.");
  }
  public static void DeleteTree(string path) {
   if(IsLink(path))throw new IOException("Refusing recursive deletion of a link.");
   Snapshot s=Scan(path,null);string root=Long(path);
   foreach(FileRow f in s.Files){string p=Path.Combine(root,f.Relative);File.SetAttributes(p,FileAttributes.Normal);File.Delete(p);}
   Array.Sort(s.Directories,delegate(string a,string b){return b.Length.CompareTo(a.Length);});
   foreach(string d in s.Directories){string p=Path.Combine(root,d);File.SetAttributes(p,FileAttributes.Directory);Directory.Delete(p);}
   Directory.Delete(root);
  }
  public static void AtomicWrite(string path,string text) {
   Directory.CreateDirectory(Path.GetDirectoryName(Full(path)));
   string temporary=path+"."+Guid.NewGuid().ToString("N")+".tmp";
   File.WriteAllText(Long(temporary),text,new System.Text.UTF8Encoding(true));
   if(!MoveFileEx(Long(temporary),Long(path),1|8))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Status write failed.");
  }
 }
 public sealed class LockOwner { public int ProcessId; public string Name; public string Service; }
 public static class Locks {
  [StructLayout(LayoutKind.Sequential)]struct UniqueProcess {public uint Id;public System.Runtime.InteropServices.ComTypes.FILETIME Start;}
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct Info {
   public UniqueProcess Process;
   [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)]public string Name;
   [MarshalAs(UnmanagedType.ByValTStr,SizeConst=64)]public string Service;
   public uint Type,Status,Session;[MarshalAs(UnmanagedType.Bool)]public bool Restartable;
  }
  [DllImport("rstrtmgr.dll",CharSet=CharSet.Unicode)]static extern int RmStartSession(out uint session,int flags,string key);
  [DllImport("rstrtmgr.dll",CharSet=CharSet.Unicode)]static extern int RmRegisterResources(uint s,uint n,string[] files,uint apps,IntPtr appList,uint services,IntPtr serviceList);
  [DllImport("rstrtmgr.dll")]static extern int RmGetList(uint s,out uint needed,ref uint count,[In,Out] Info[] list,ref uint reboot);
  [DllImport("rstrtmgr.dll")]static extern int RmEndSession(uint s);
  public static LockOwner[] Query(string file) {
   uint s;int error=RmStartSession(out s,0,Guid.NewGuid().ToString("N"));if(error!=0)throw new IOException("Restart Manager: "+error);
   try {
    error=RmRegisterResources(s,1,new string[]{Engine.Full(file)},0,IntPtr.Zero,0,IntPtr.Zero);if(error!=0)throw new IOException("Register lock resource: "+error);
    uint need=0,count=0,reboot=0;error=RmGetList(s,out need,ref count,null,ref reboot);if(error==0)return new LockOwner[0];
    if(error!=234)throw new IOException("Query locks: "+error);
    var list=new Info[need];count=need;error=RmGetList(s,out need,ref count,list,ref reboot);if(error!=0)throw new IOException("Read locks: "+error);
    var result=new List<LockOwner>();for(int i=0;i<count;i++)result.Add(new LockOwner{ProcessId=(int)list[i].Process.Id,Name=list[i].Name,Service=list[i].Service});return result.ToArray();
   }finally{RmEndSession(s);}
  }
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern IntPtr OpenSCManager(string a,string b,uint access);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern IntPtr OpenService(IntPtr s,string name,uint access);
  [DllImport("advapi32.dll")]static extern bool CloseServiceHandle(IntPtr s);
  public static void CheckServicePermission(string name) {
   IntPtr manager=OpenSCManager(null,null,1);if(manager==IntPtr.Zero)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
   try{IntPtr service=OpenService(manager,name,4|8|16|32);if(service==IntPtr.Zero)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Service control permission required: "+name);CloseServiceHandle(service);}finally{CloseServiceHandle(manager);}
  }
 }
}
