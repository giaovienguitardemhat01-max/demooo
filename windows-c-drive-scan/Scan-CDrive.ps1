<#
.SYNOPSIS
    Quet va phan tich dung luong o C. CHI DOC - KHONG xoa, KHONG sua bat cu thu gi.

.DESCRIPTION
    Script nay chi THU THAP SO LIEU de tim nguyen nhan o C bi day:
      - Dung luong tong / da dung / con trong cua o C, suc khoe o dia
      - Quet toan bo cay thu muc o C (bo qua junction/symlink de khong dem trung,
        khong tinh file OneDrive "chi tren cloud", tinh dung file nen/sparse)
      - Top vi tri / file lon nhat, cay thu muc lon
      - Phan loai theo nguyen nhan: Windows Update, Temp, WER/crash dump, thung rac,
        Store, cache trinh duyet, OneDrive, Docker/WSL/may ao, ung dung chat, ...
      - pagefile.sys / hiberfil.sys / System Restore (shadow copy) / WinSxS (DISM)
      - Du lieu moi ghi trong N ngay gan day + tien trinh ghi nhieu du lieu nhat
        (de tim ung dung dang lien tuc tao du lieu)
      - So sanh voi lan quet truoc (neu co) de thay thu muc nao dang phinh to

    Thu duy nhat script GHI ra la thu muc bao cao (vai MB).
    Khong xoa file, khong doi registry, khong doi cau hinh he thong, khong tat dich vu.
    Cac lenh he thong duoc goi deu la lenh CHI DOC:
      vssadmin list shadowstorage, Dism /AnalyzeComponentStore, Dism /Get-ReservedStorageState,
      powercfg /a, fsutil dirty query, compact /compactos:query

    Nen chay bang quyen Administrator de do duoc thu muc he thong, thu muc cua
    cac user khac, System Restore (vssadmin) va WinSxS (DISM).

.PARAMETER OutputDir
    Thu muc luu bao cao. Mac dinh: thu muc 'BaoCao' nam canh file script.

.PARAMETER RecentDays
    So ngay gan day dung de tinh "du lieu moi ghi". Mac dinh 7.

.PARAMETER SkipDism
    Bo qua buoc phan tich WinSxS bang DISM (tiet kiem 1-5 phut).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Scan-CDrive.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [ValidateRange(1, 90)]
    [int]$RecentDays = 7,
    [switch]$SkipDism
)

$ErrorActionPreference = 'Continue'

# PowerShell 32-bit tren Windows 64-bit bi chuyen huong System32 -> SysWOW64, so lieu se sai.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and $env:WINDIR) {
    $native = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $native) {
        Write-Host 'Dang chay PowerShell 32-bit -> mo lai bang PowerShell 64-bit...'
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-RecentDays', $RecentDays)
        if ($OutputDir) { $argList += @('-OutputDir', $OutputDir) }
        if ($SkipDism) { $argList += '-SkipDism' }
        & $native @argList
        return
    }
}

$scanStart = Get-Date
$onWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$isAdmin = $false
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

# ----------------------------------------------------------------------------
# Bo quet file (C#, chi doc). Dung FindFirstFileExW de nhanh va lay duoc reparse tag:
#  - bo qua junction/symlink (tranh dem trung, tranh vong lap)
#  - file OneDrive "chi tren cloud" (placeholder) khong chiem cho -> tinh rieng
#  - file nen NTFS / CompactOS / sparse -> dung kich thuoc thuc tren dia
# Viet theo cu phap C# 5 de bien dich duoc trong Windows PowerShell 5.1.
# ----------------------------------------------------------------------------
$walkerSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace CDriveScan
{
    public class DirEntry
    {
        public string Path;
        public int Depth;
        public long Bytes;
        public long Files;
        public long RecentBytes;
        public long CloudBytes;
        public bool IsBig;
        public bool Denied;
    }

    public class FileEntry
    {
        public string Path;
        public long Bytes;
        public DateTime LastWriteUtc;
    }

    public class ExtStat
    {
        public string Ext;
        public long Bytes;
        public long Files;
    }

    public class Walker
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME_U
        {
            public uint Low;
            public uint High;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WIN32_FIND_DATAW
        {
            public uint dwFileAttributes;
            public FILETIME_U ftCreationTime;
            public FILETIME_U ftLastAccessTime;
            public FILETIME_U ftLastWriteTime;
            public uint nFileSizeHigh;
            public uint nFileSizeLow;
            public uint dwReserved0;
            public uint dwReserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string cFileName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
            public string cAlternateFileName;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstFileExW(string lpFileName, int fInfoLevelId, out WIN32_FIND_DATAW lpFindFileData, int fSearchOp, IntPtr lpSearchFilter, int dwAdditionalFlags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool FindNextFileW(IntPtr hFindFile, out WIN32_FIND_DATAW lpFindFileData);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FindClose(IntPtr hFindFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public FILETIME_U CreationTime;
            public FILETIME_U LastAccessTime;
            public FILETIME_U LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(IntPtr hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        private static readonly IntPtr INVALID_HANDLE = new IntPtr(-1);
        private const int FIND_EX_INFO_BASIC = 1;
        private const int FIND_FIRST_EX_LARGE_FETCH = 2;
        private const uint ATTR_DIRECTORY = 0x10;
        private const uint ATTR_SPARSE = 0x200;
        private const uint ATTR_REPARSE = 0x400;
        private const uint ATTR_COMPRESSED = 0x800;
        private const uint ATTR_OFFLINE = 0x1000;
        private const uint ATTR_RECALL_ON_OPEN = 0x40000;
        private const uint ATTR_RECALL_ON_DATA_ACCESS = 0x400000;
        private const uint TAG_MOUNT_POINT = 0xA0000003;
        private const uint TAG_SYMLINK = 0xA000000C;
        private const uint TAG_WOF = 0x80000017;
        private const long MAX_FILETIME = 2650467743999999999L;
        private const uint FILE_READ_ATTRIBUTES = 0x80;
        private const uint FILE_SHARE_ALL = 0x7;
        private const uint OPEN_EXISTING = 3;
        private const uint FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private const uint FLAG_BACKUP_SEMANTICS = 0x02000000;

        public long MinRecordBytes = 100L * 1024 * 1024;
        public int TopFileCount = 50;
        public int RecentFileCount = 30;
        public long SpecialFileMinBytes = 10L * 1024 * 1024;
        public long RecentCutoffFileTime = 0;
        // Hard link (vd WinSxS <-> System32): chi tinh 1 lan, cho duong dan gap dau tien.
        public bool DedupHardLinks = true;
        public long HardLinkMinBytes = 32L * 1024;
        public long OnDiskCheckMinBytes = 32L * 1024;

        public HashSet<string> Targets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> SpecialExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        public List<DirEntry> Dirs = new List<DirEntry>();
        public List<FileEntry> TopFiles = new List<FileEntry>();
        public List<FileEntry> RecentFiles = new List<FileEntry>();
        public List<FileEntry> SpecialFiles = new List<FileEntry>();
        public List<FileEntry> RootFiles = new List<FileEntry>();
        public Dictionary<string, ExtStat> Extensions = new Dictionary<string, ExtStat>(StringComparer.OrdinalIgnoreCase);
        public List<string> DeniedSamples = new List<string>();
        public List<string> LinkSamples = new List<string>();

        public long TotalFiles;
        public long TotalDirs;
        public long TotalBytes;
        public long DeniedDirs;
        public long SkippedLinks;
        public long PlaceholderFiles;
        public long PlaceholderBytes;
        public long CompressedSavedBytes;
        public long HardLinkDupFiles;
        public long HardLinkDupBytes;
        public long HardLinkOpenFailures;
        public volatile string CurrentDir = "";
        public string Error;

        private Thread worker;
        private HashSet<long> seenLinks = new HashSet<long>();
        private long topThreshold = 0;
        private long recentThreshold = 0;

        private struct Totals
        {
            public long Bytes;
            public long Files;
            public long Recent;
            public long Cloud;
        }

        public void Start(string root)
        {
            string r = root.TrimEnd('\\');
            worker = new Thread(delegate()
            {
                try
                {
                    Walk(r, 0);
                }
                catch (Exception ex)
                {
                    Error = ex.ToString();
                }
                Trim(TopFiles, TopFileCount, ref topThreshold);
                Trim(RecentFiles, RecentFileCount, ref recentThreshold);
            }, 64 * 1024 * 1024);
            worker.IsBackground = true;
            worker.Start();
        }

        public bool IsRunning
        {
            get { return worker != null && worker.IsAlive; }
        }

        public void Wait()
        {
            if (worker != null) worker.Join();
        }

        private static long Combine(uint high, uint low)
        {
            return ((long)high << 32) | (long)low;
        }

        private static int CompareDesc(FileEntry a, FileEntry b)
        {
            return b.Bytes.CompareTo(a.Bytes);
        }

        private static void Trim(List<FileEntry> list, int keep, ref long threshold)
        {
            list.Sort(CompareDesc);
            if (list.Count > keep) list.RemoveRange(keep, list.Count - keep);
            if (keep > 0 && list.Count >= keep) threshold = list[keep - 1].Bytes;
        }

        private static FileEntry MakeFile(string path, long bytes, long fileTime)
        {
            FileEntry f = new FileEntry();
            f.Path = path;
            f.Bytes = bytes;
            f.LastWriteUtc = DateTime.FromFileTimeUtc(fileTime);
            return f;
        }

        // true = file nay la mot ten khac (hard link) cua file da dem truoc do
        private bool IsDuplicateHardLink(string full)
        {
            IntPtr fh = CreateFileW(@"\\?\" + full, FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, FLAG_OPEN_REPARSE_POINT | FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (fh == INVALID_HANDLE)
            {
                HardLinkOpenFailures++;
                return false;
            }
            try
            {
                BY_HANDLE_FILE_INFORMATION info;
                if (GetFileInformationByHandle(fh, out info) && info.NumberOfLinks > 1)
                {
                    long id = Combine(info.FileIndexHigh, info.FileIndexLow);
                    if (!seenLinks.Add(id)) return true;
                }
            }
            finally
            {
                CloseHandle(fh);
            }
            return false;
        }

        private void Record(string dir, int depth, Totals t, bool denied)
        {
            bool big = t.Bytes >= MinRecordBytes;
            if (big || depth <= 1 || Targets.Contains(dir))
            {
                DirEntry e = new DirEntry();
                e.Path = dir;
                e.Depth = depth;
                e.Bytes = t.Bytes;
                e.Files = t.Files;
                e.RecentBytes = t.Recent;
                e.CloudBytes = t.Cloud;
                e.IsBig = big;
                e.Denied = denied;
                Dirs.Add(e);
            }
        }

        private Totals Walk(string dir, int depth)
        {
            Totals t = new Totals();
            CurrentDir = dir;
            WIN32_FIND_DATAW fd;
            IntPtr h = FindFirstFileExW(@"\\?\" + dir + @"\*", FIND_EX_INFO_BASIC, out fd, 0, IntPtr.Zero, FIND_FIRST_EX_LARGE_FETCH);
            if (h == INVALID_HANDLE)
            {
                DeniedDirs++;
                if (DeniedSamples.Count < 40) DeniedSamples.Add(dir);
                Record(dir, depth, t, true);
                return t;
            }
            try
            {
                do
                {
                    string name = fd.cFileName;
                    if (name == "." || name == "..") continue;
                    string full = dir + "\\" + name;
                    uint attr = fd.dwFileAttributes;
                    bool isReparse = (attr & ATTR_REPARSE) != 0;

                    if ((attr & ATTR_DIRECTORY) != 0)
                    {
                        if (isReparse && (fd.dwReserved0 == TAG_MOUNT_POINT || fd.dwReserved0 == TAG_SYMLINK))
                        {
                            SkippedLinks++;
                            if (LinkSamples.Count < 40) LinkSamples.Add(full);
                            continue;
                        }
                        TotalDirs++;
                        Totals c = Walk(full, depth + 1);
                        t.Bytes += c.Bytes;
                        t.Files += c.Files;
                        t.Recent += c.Recent;
                        t.Cloud += c.Cloud;
                        continue;
                    }

                    long logical = Combine(fd.nFileSizeHigh, fd.nFileSizeLow);
                    TotalFiles++;

                    // OneDrive / cloud placeholder: chua tai ve may, khong chiem cho tren o C.
                    if ((attr & (ATTR_RECALL_ON_DATA_ACCESS | ATTR_RECALL_ON_OPEN | ATTR_OFFLINE)) != 0)
                    {
                        PlaceholderFiles++;
                        PlaceholderBytes += logical;
                        t.Cloud += logical;
                        continue;
                    }

                    // Kich thuoc thuc tren dia: file nen NTFS, sparse va nen WOF/CompactOS (Windows an co
                    // WOF khi liet ke thu muc nen file >= OnDiskCheckMinBytes luon duoc hoi truc tiep).
                    long size = logical;
                    if ((attr & (ATTR_COMPRESSED | ATTR_SPARSE)) != 0 || (isReparse && fd.dwReserved0 == TAG_WOF) || logical >= OnDiskCheckMinBytes)
                    {
                        uint hi;
                        uint lo = GetCompressedFileSizeW(@"\\?\" + full, out hi);
                        if (lo != 0xFFFFFFFF || Marshal.GetLastWin32Error() == 0)
                        {
                            long onDisk = Combine(hi, lo);
                            if (onDisk >= 0 && onDisk <= logical)
                            {
                                CompressedSavedBytes += logical - onDisk;
                                size = onDisk;
                            }
                        }
                    }

                    if (DedupHardLinks && logical >= HardLinkMinBytes && IsDuplicateHardLink(full))
                    {
                        HardLinkDupFiles++;
                        HardLinkDupBytes += size;
                        continue;
                    }

                    t.Bytes += size;
                    t.Files++;
                    TotalBytes += size;

                    long ft = Combine(fd.ftLastWriteTime.High, fd.ftLastWriteTime.Low);
                    if (ft < 0 || ft > MAX_FILETIME) ft = 0;
                    bool recent = RecentCutoffFileTime > 0 && ft >= RecentCutoffFileTime;
                    if (recent) t.Recent += size;

                    string ext;
                    int dot = name.LastIndexOf('.');
                    if (dot <= 0 || dot == name.Length - 1) ext = "(khong co)";
                    else if (name.Length - dot > 12) ext = "(khac)";
                    else ext = name.Substring(dot).ToLowerInvariant();

                    ExtStat es;
                    if (!Extensions.TryGetValue(ext, out es))
                    {
                        es = new ExtStat();
                        es.Ext = ext;
                        Extensions[ext] = es;
                    }
                    es.Bytes += size;
                    es.Files++;

                    if (depth == 0) RootFiles.Add(MakeFile(full, size, ft));
                    if (size >= topThreshold)
                    {
                        TopFiles.Add(MakeFile(full, size, ft));
                        if (TopFiles.Count >= TopFileCount * 2) Trim(TopFiles, TopFileCount, ref topThreshold);
                    }
                    if (recent && size >= recentThreshold)
                    {
                        RecentFiles.Add(MakeFile(full, size, ft));
                        if (RecentFiles.Count >= RecentFileCount * 2) Trim(RecentFiles, RecentFileCount, ref recentThreshold);
                    }
                    if (size >= SpecialFileMinBytes && SpecialFiles.Count < 1000 && SpecialExtensions.Contains(ext))
                    {
                        SpecialFiles.Add(MakeFile(full, size, ft));
                    }
                }
                while (FindNextFileW(h, out fd));
            }
            finally
            {
                FindClose(h);
            }
            Record(dir, depth, t, false);
            return t;
        }
    }
}
'@

# ----------------------------------------------------------------------------
# Ham tien ich
# ----------------------------------------------------------------------------
$script:Lines = New-Object System.Collections.Generic.List[string]

function Out-Line {
    param([string]$Text = '')
    $script:Lines.Add($Text)
}

function Out-Section {
    param([string]$Title)
    Out-Line ''
    Out-Line ('=' * 100)
    Out-Line $Title
    Out-Line ('=' * 100)
}

function Format-Size {
    param([double]$Bytes)
    $neg = $Bytes -lt 0
    $b = [Math]::Abs($Bytes)
    if ($b -ge 1TB) { $s = '{0:N2} TB' -f ($b / 1TB) }
    elseif ($b -ge 1GB) { $s = '{0:N2} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { $s = '{0:N0} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { $s = '{0:N0} KB' -f ($b / 1KB) }
    else { $s = '{0:N0} B' -f $b }
    if ($neg) { return '-' + $s }
    return $s
}

function Format-Pct {
    param([double]$Part, [double]$Whole)
    if ($Whole -le 0) { return '?' }
    return ('{0:N1}%' -f (100.0 * $Part / $Whole))
}

function Format-Date {
    param($Date)
    if ($null -eq $Date) { return '?' }
    try { return ([datetime]$Date).ToString('yyyy-MM-dd HH:mm') } catch { return [string]$Date }
}

function Limit-Text {
    param([string]$Text, [int]$Max = 90)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return '...' + $Text.Substring($Text.Length - $Max + 3)
}

function Show-Path {
    param([string]$Path)
    if ($Path -match '^[A-Za-z]:$') { return $Path + '\' }
    return $Path
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Get-RegValues {
    param([string]$Path)
    try {
        $p = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        $o = [ordered]@{}
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -notlike 'PS*') { $o[$prop.Name] = $prop.Value }
        }
        return $o
    } catch { return $null }
}

function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    try {
        return (& $File @Arguments 2>&1 | Out-String)
    } catch {
        return ('[!] Khong chay duoc {0}: {1}' -f $File, $_.Exception.Message)
    }
}

function Out-Raw {
    param([string]$Text, [int]$MaxLines = 40)
    if (-not $Text) { Out-Line '    (khong co du lieu)'; return }
    $n = 0
    foreach ($l in ($Text -split '[\r\n]+')) {
        $t = $l.TrimEnd()
        if ($t.Trim() -eq '') { continue }
        if ($t -match '^\s*\[[=\s\d.,%]*\]\s*$') { continue }
        Out-Line ('    ' + $t.Trim())
        $n++
        if ($n -ge $MaxLines) { Out-Line '    ...'; break }
    }
}

function Out-Wrapped {
    param([string]$Prefix, [string[]]$Words, [int]$Width = 100)
    $line = $Prefix
    foreach ($w in $Words) {
        if (($line.Length + $w.Length + 2) -gt $Width -and $line.Trim()) {
            Out-Line $line
            $line = ' ' * $Prefix.Length
        }
        $line += $w + '; '
    }
    if ($line.Trim()) { Out-Line $line }
}

function Invoke-Safe {
    param([string]$What, [scriptblock]$Block)
    try { & $Block } catch { Out-Line ('  [!] Khong lay duoc {0}: {1}' -f $What, $_.Exception.Message) }
}

function Resolve-Targets {
    param([string[]]$Patterns)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($pat in $Patterns) {
        if (-not $pat) { continue }
        try {
            if ($pat -match '[\*\?]') {
                $items = @(Get-Item -Path $pat -Force -ErrorAction Stop)
            } elseif (Test-Path -LiteralPath $pat) {
                $items = @(Get-Item -LiteralPath $pat -Force -ErrorAction Stop)
            } else {
                $items = @()
            }
            foreach ($i in $items) {
                if ($i.PSIsContainer) {
                    $full = $i.FullName.TrimEnd('\')
                    if (-not $out.Contains($full)) { $out.Add($full) }
                }
            }
        } catch { }
    }
    return , $out.ToArray()
}

function Remove-NestedPaths {
    param([string[]]$Paths)
    $sorted = @($Paths | Where-Object { $_ } | Select-Object -Unique | Sort-Object Length)
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($p in $sorted) {
        $nested = $false
        foreach ($k in $kept) {
            if ($p.Equals($k, [StringComparison]::OrdinalIgnoreCase) -or
                $p.StartsWith($k + '\', [StringComparison]::OrdinalIgnoreCase)) { $nested = $true; break }
        }
        if (-not $nested) { $kept.Add($p) }
    }
    return , $kept.ToArray()
}

function Get-ChromiumCacheDirs {
    param([string]$UserData)
    $result = New-Object System.Collections.Generic.List[string]
    $profileDirs = @(Get-ChildItem -LiteralPath $UserData -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -eq 'Guest Profile' -or $_.Name -eq 'System Profile' })
    $profileSubs = @('Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache',
        'Service Worker\CacheStorage', 'Service Worker\ScriptCache', 'Media Cache')
    foreach ($pd in $profileDirs) {
        foreach ($sub in $profileSubs) {
            $p = $pd.FullName.TrimEnd('\') + '\' + $sub
            if (Test-Path -LiteralPath $p) { $result.Add($p) }
        }
    }
    foreach ($sub in @('ShaderCache', 'GrShaderCache', 'GraphiteDawnCache', 'component_crx_cache', 'extensions_crx_cache')) {
        $p = $UserData.TrimEnd('\') + '\' + $sub
        if (Test-Path -LiteralPath $p) { $result.Add($p) }
    }
    return , $result.ToArray()
}

# ----------------------------------------------------------------------------
# Chuan bi thu muc bao cao
# ----------------------------------------------------------------------------
if (-not $OutputDir) {
    if ($PSScriptRoot) { $OutputDir = Join-Path $PSScriptRoot 'BaoCao' }
    else { $OutputDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'BaoCao-O-C' }
}
$runId = $scanStart.ToString('yyyyMMdd-HHmmss')
$runDir = Join-Path $OutputDir $runId
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

Write-Host ''
Write-Host '=== QUET O C - CHE DO CHI DOC (khong xoa, khong sua gi) ===' -ForegroundColor Cyan
if (-not $isAdmin) {
    Write-Host '[CANH BAO] Dang chay KHONG co quyen Administrator.' -ForegroundColor Yellow
    Write-Host '           Thu muc he thong, user khac, System Restore va WinSxS se khong do duoc day du.' -ForegroundColor Yellow
    Write-Host '           Nen dong cua so nay va chay lai bang ChayQuet.cmd (se hoi quyen Admin).' -ForegroundColor Yellow
}
Write-Host ('Bao cao se luu tai: {0}' -f $runDir)

# ----------------------------------------------------------------------------
# [1/5] Thong tin he thong (chi doc)
# ----------------------------------------------------------------------------
Write-Host '[1/5] Thu thap thong tin he thong...'

$cDisk = $null; $otherDisks = @(); $os = $null; $cs = $null
try { $cDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop } catch { }
try { $otherDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | Where-Object { $_.DeviceID -ne 'C:' }) } catch { }
try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }
try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }

$capacity = 0.0; $freeBytes = 0.0
if ($cDisk) { $capacity = [double]$cDisk.Size; $freeBytes = [double]$cDisk.FreeSpace }
$usedBytes = $capacity - $freeBytes

# Ho so nguoi dung tren o C
$Profiles = @()
try {
    $Profiles = @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -Force -ErrorAction Stop |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { $_.FullName.TrimEnd('\') })
} catch { }

function UP {
    param([string]$Rel)
    foreach ($p in $script:Profiles) { $p + '\' + $Rel }
}

# WSL distro (user hien tai)
$lxss = @()
try {
    $lxss = @(Get-ChildItem -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction Stop | ForEach-Object {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.BasePath) {
                [pscustomobject]@{ Name = $p.DistributionName; BasePath = ([string]$p.BasePath -replace '^\\\\\?\\', '').TrimEnd('\'); Version = $p.Version }
            }
        })
} catch { }

# ----------------------------------------------------------------------------
# Danh muc nguyen nhan. Muc:
#   A  = an toan tuyet doi (cache/tam; xoa bang cong cu chinh thong, tu tao lai)
#   B  = an toan nhung can can nhac (mat kha nang rollback, phai tai lai, du lieu ung dung)
#   C  = khong nen dung vao / chi la so tong de tham khao
#   CN = du lieu ca nhan - KHONG xoa, chi can nhac CHUYEN sang o khac
# ----------------------------------------------------------------------------
$catalog = New-Object System.Collections.Generic.List[object]
function Add-Cat {
    param([string]$Cat, [string]$Name, [string]$Level, [string[]]$Paths, [string]$Note = '')
    $script:catalog.Add([pscustomobject]@{
            Cat = $Cat; Name = $Name; Level = $Level; Note = $Note
            Patterns = @($Paths | Where-Object { $_ })
            Found = @(); Missing = @()
            Bytes = [long]0; Files = [long]0; Recent = [long]0; Cloud = [long]0; Denied = $false
        })
}

$catWU = 'Windows Update'
Add-Cat $catWU 'Cache tai ban cap nhat (SoftwareDistribution\Download)' 'A' @('C:\Windows\SoftwareDistribution\Download') 'Windows tu tai lai neu can. Don bang Disk Cleanup > "Windows Update Cleanup" hoac dung dich vu wuauserv roi xoa noi dung.'
Add-Cat $catWU 'Delivery Optimization cache' 'A' @('C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization', 'C:\Windows\SoftwareDistribution\DeliveryOptimization') 'Ban cap nhat chia se P2P. Don trong Settings > Storage > Temporary files > Delivery Optimization Files.'
Add-Cat $catWU 'Log CBS / DISM (C:\Windows\Logs)' 'B' @('C:\Windows\Logs') 'Log cai dat cap nhat; CBS.log co the phinh to khi update loi. Xoa .log/.cab cu khi TrustedInstaller dung.'
Add-Cat $catWU 'Component store WinSxS (xem so lieu DISM o muc 9)' 'C' @('C:\Windows\WinSxS') 'KHONG xoa thu cong. File dung chung (hard link) voi System32 da tinh cho System32; so chinh xac xem DISM o muc 9. Chi don bang DISM /StartComponentCleanup.'
Add-Cat $catWU 'Windows Installer cache (C:\Windows\Installer)' 'C' @('C:\Windows\Installer') 'KHONG xoa - can de go/sua/cap nhat phan mem (Office, Visual C++...).'
Add-Cat $catWU 'Du lieu Windows Update (DataStore)' 'C' @('C:\Windows\SoftwareDistribution\DataStore') 'KHONG xoa - lich su/co so du lieu cap nhat.'

$catOld = 'Windows.old / nang cap'
Add-Cat $catOld 'Windows.old (ban Windows truoc)' 'B' @('C:\Windows.old') 'Xoa = mat kha nang quay lai ban Windows truoc. Don bang Disk Cleanup > "Previous Windows installation(s)".'
Add-Cat $catOld 'File tam nang cap ($Windows.~BT, $Windows.~WS, $WinREAgent, ESD)' 'B' @('C:\$Windows.~BT', 'C:\$Windows.~WS', 'C:\$WinREAgent', 'C:\ESD', 'C:\$GetCurrent', 'C:\$SysReset') 'Con lai sau nang cap/Reset. Don bang Disk Cleanup > "Temporary Windows installation files".'
Add-Cat $catOld 'Log cai dat Windows (Panther)' 'B' @('C:\Windows\Panther') 'Log setup; thuong nho.'

$catTemp = 'Tep tam (Temp)'
Add-Cat $catTemp 'Windows Temp' 'A' @('C:\Windows\Temp', 'C:\Windows\SystemTemp') 'File tam cua dich vu he thong. Xoa file cu (khong dang khoa) bang Settings > Storage > Temporary files.'
Add-Cat $catTemp 'User Temp (%TEMP% cua tung user)' 'A' (UP 'AppData\Local\Temp') 'File tam cua ung dung. Xoa file cu hon vai ngay khi da dong ung dung. Kiem tra file lon de biet ung dung nao tao ra.'

$catWer = 'Crash dump / WER'
Add-Cat $catWer 'Windows Error Reporting (bao cao loi)' 'A' @('C:\ProgramData\Microsoft\Windows\WER'; UP 'AppData\Local\Microsoft\Windows\WER') 'Bao cao loi da gui/chua gui. Don bang Disk Cleanup > "System error memory dump files" / "Windows error reports".'
Add-Cat $catWer 'Crash dump ung dung (CrashDumps)' 'A' (UP 'AppData\Local\CrashDumps') 'Dump khi ung dung bi crash. Neu lien tuc tang -> co ung dung crash lap lai (xem ten file).'
Add-Cat $catWer 'Minidump + LiveKernelReports' 'A' @('C:\Windows\Minidump', 'C:\Windows\LiveKernelReports') 'Dump loi he thong/driver. Neu lon/lien tuc -> co loi driver (GPU, Wi-Fi...) can kiem tra.'

Add-Cat 'Thung rac' 'Recycle Bin (tat ca user tren o C)' 'B' @('C:\$Recycle.Bin') 'Xem lai truoc khi lam rong - co the con file muon khoi phuc.'

$catStore = 'Microsoft Store'
Add-Cat $catStore 'Microsoft Store cache' 'A' (UP 'AppData\Local\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalCache') 'Xoa bang lenh wsreset.exe.'

$catBrowser = 'Trinh duyet'
$chromium = @(
    @{ Name = 'Google Chrome'; Rel = 'AppData\Local\Google\Chrome\User Data' },
    @{ Name = 'Microsoft Edge'; Rel = 'AppData\Local\Microsoft\Edge\User Data' },
    @{ Name = 'Coc Coc'; Rel = 'AppData\Local\CocCoc\Browser\User Data' },
    @{ Name = 'Brave'; Rel = 'AppData\Local\BraveSoftware\Brave-Browser\User Data' },
    @{ Name = 'Vivaldi'; Rel = 'AppData\Local\Vivaldi\User Data' }
)
foreach ($b in $chromium) {
    $uds = @(UP $b.Rel | Where-Object { Test-Path -LiteralPath $_ })
    if ($uds.Count -eq 0) {
        Add-Cat $catBrowser ('Cache {0}' -f $b.Name) 'A' @()
        continue
    }
    $cacheDirs = @()
    foreach ($ud in $uds) { $cacheDirs += Get-ChromiumCacheDirs $ud }
    Add-Cat $catBrowser ('Cache {0}' -f $b.Name) 'A' $cacheDirs 'Chi la cache. Xoa trong trinh duyet: Ctrl+Shift+Del > "Anh va tep trong bo nho dem". Khong mat lich su/mat khau.'
    Add-Cat $catBrowser ('Mo hinh AI tai ve may cua {0} (OptGuideOnDeviceModel)' -f $b.Name) 'B' @($uds | ForEach-Object { $_ + '\OptGuideOnDeviceModel' }) 'Mo hinh AI (vd Gemini Nano) trinh duyet tu tai; se tai lai neu khong tat tinh nang AI trong trinh duyet.'
    Add-Cat $catBrowser ('Toan bo ho so {0} (tham khao)' -f $b.Name) 'C' $uds 'Chua lich su, mat khau, cookie, extension. KHONG xoa thu cong.'
}
Add-Cat $catBrowser 'Cache Firefox' 'A' (UP 'AppData\Local\Mozilla\Firefox\Profiles\*\cache2') 'Xoa trong Firefox: Settings > Privacy > Cookies and Site Data > Clear Data > Cached Web Content.'
Add-Cat $catBrowser 'Cache Opera' 'A' @(UP 'AppData\Local\Opera Software\*\Cache'; UP 'AppData\Local\Opera Software\*\Default\Cache'; UP 'AppData\Local\Opera Software\*\Code Cache') 'Xoa trong Opera: Ctrl+Shift+Del > Cached images and files.'
Add-Cat $catBrowser 'Cache web cu (INetCache)' 'A' (UP 'AppData\Local\Microsoft\Windows\INetCache') 'Cache cua IE/WebView cu. Don bang Disk Cleanup > "Temporary Internet Files".'

$catCloud = 'Dong bo dam may'
Add-Cat $catCloud 'Thu muc OneDrive (file dang luu tren may)' 'CN' (UP 'OneDrive*') 'Du lieu ca nhan. Giai phong bang chuot phai > "Free up space" (giu tren cloud, xoa ban tren may) - KHONG xoa file.'
Add-Cat $catCloud 'OneDrive app + log' 'C' (UP 'AppData\Local\Microsoft\OneDrive') 'Chuong trinh OneDrive va log. Khong xoa thu cong.'
Add-Cat $catCloud 'Google Drive cache (DriveFS)' 'B' (UP 'AppData\Local\Google\DriveFS') 'Cache Google Drive cho may tinh. Co the doi vi tri cache/giam trong cai dat Google Drive.'
Add-Cat $catCloud 'Dropbox / iCloud Drive' 'CN' @(UP 'Dropbox'; UP 'iCloudDrive') 'Du lieu dong bo. Dung tinh nang "Online-only" cua ung dung.'

$catVm = 'Docker / WSL / may ao / gia lap'
Add-Cat $catVm 'Docker Desktop (o dia ao vhdx)' 'B' @(UP 'AppData\Local\Docker'; 'C:\ProgramData\Docker'; 'C:\ProgramData\DockerDesktop') 'File vhdx KHONG tu thu nho. Don bang "docker system prune", sau do compact vhdx hoac doi "Disk image location" sang o khac.'
$wslPaths = @(UP 'AppData\Local\Packages\CanonicalGroupLimited.*'; UP 'AppData\Local\Packages\*Linux*'; UP 'AppData\Local\wsl')
foreach ($d in $lxss) { if ($d.BasePath -like 'C:\*') { $wslPaths += $d.BasePath } }
Add-Cat $catVm 'WSL (Linux tren Windows)' 'B' $wslPaths 'ext4.vhdx KHONG tu thu nho. Don ben trong Linux, roi compact hoac export/import sang o khac.'
Add-Cat $catVm 'May ao Hyper-V / VirtualBox / VMware' 'B' @('C:\ProgramData\Microsoft\Windows\Virtual Hard Disks'; 'C:\Users\Public\Documents\Hyper-V'; UP 'VirtualBox VMs'; UP 'Documents\Virtual Machines') 'O dia may ao. Chuyen sang o khac bang chinh phan mem ao hoa.'
Add-Cat $catVm 'Gia lap Android (BlueStacks, LDPlayer, Nox, MEmu, AVD)' 'B' @('C:\ProgramData\BlueStacks_nxt'; 'C:\ProgramData\BlueStacks'; 'C:\LDPlayer'; 'C:\Program Files\Nox'; 'C:\Program Files\Microvirt'; UP 'AppData\Local\Nox'; UP '.android\avd') 'O dia ao cua gia lap. Xoa ban gia lap khong dung bang Multi-instance manager cua chinh phan mem.'

$catChat = 'Ung dung chat'
Add-Cat $catChat 'Zalo PC (anh/video/file nhan qua chat)' 'B' @(UP 'AppData\Local\ZaloPC'; UP 'AppData\Roaming\ZaloData') 'Chua anh/video/file da nhan - co the la du lieu quan trong. Chi don trong Zalo: Cai dat > Du lieu > Quan ly du lieu.'
Add-Cat $catChat 'Telegram Desktop' 'B' (UP 'AppData\Roaming\Telegram Desktop') 'Don trong Telegram: Settings > Advanced > Manage local storage.'
Add-Cat $catChat 'Microsoft Teams' 'B' @(UP 'AppData\Roaming\Microsoft\Teams'; UP 'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe') 'Cache Teams; xoa khi Teams da thoat (Settings > Apps > Teams > Reset/Repair).'
Add-Cat $catChat 'Messenger / WhatsApp / Viber / Skype / Discord' 'B' @(UP 'AppData\Local\Packages\Facebook.Messenger*'; UP 'AppData\Local\Packages\5319275A.WhatsAppDesktop*'; UP 'AppData\Roaming\ViberPC'; UP 'AppData\Roaming\Microsoft\Skype for Desktop'; UP 'AppData\Roaming\discord') 'Cache + media chat. Don trong cai dat cua tung ung dung.'

$catMedia = 'Do hoa / video / nhac'
Add-Cat $catMedia 'CapCut - cache' 'B' @(UP 'AppData\Local\CapCut\User Data\Cache'; UP 'AppData\Local\CapCut\Cache') 'Don trong CapCut: Cai dat > Bo nho dem > Xoa. Khong xoa thu muc Projects.'
Add-Cat $catMedia 'CapCut - du an (Projects)' 'CN' (UP 'AppData\Local\CapCut\User Data\Projects') 'Du an video cua ban - KHONG xoa. Co the doi noi luu du an sang o khac trong cai dat CapCut.'
Add-Cat $catMedia 'CapCut - toan bo (tham khao)' 'C' (UP 'AppData\Local\CapCut') 'Tong cua CapCut (gom app, cache, du an).'
Add-Cat $catMedia 'Adobe Media Cache (Premiere/After Effects)' 'B' @(UP 'AppData\Roaming\Adobe\Common\Media Cache Files'; UP 'AppData\Roaming\Adobe\Common\Media Cache'; UP 'AppData\Roaming\Adobe\Common\Peak Files') 'Don trong Premiere: Preferences > Media Cache > Delete. Co the doi vi tri sang o khac.'
Add-Cat $catMedia 'Wondershare / Filmora' 'B' @(UP 'AppData\Roaming\Wondershare'; UP 'AppData\Local\Wondershare') 'Cache/render cua Filmora. Don trong cai dat cua phan mem.'
Add-Cat $catMedia 'Spotify cache' 'B' @(UP 'AppData\Local\Spotify'; UP 'AppData\Local\Packages\SpotifyAB.SpotifyMusic*') 'Nhac tai offline + cache. Don trong Spotify: Settings > Storage > Clear cache.'

Add-Cat 'Game' 'Thu vien game (Steam, Epic, Riot, Garena, Battle.net)' 'B' @('C:\Program Files (x86)\Steam\steamapps'; 'C:\Program Files\Epic Games'; 'C:\Riot Games'; 'C:\Program Files (x86)\Garena'; 'C:\Garena'; 'C:\Program Files (x86)\Battle.net'; 'C:\Program Files\EA Games') 'Game da cai. Go hoac chuyen sang o khac bang launcher (Steam: Storage > Move).'

$catSys = 'Cache he thong & driver'
Add-Cat $catSys 'Cache shader GPU (DirectX/NVIDIA/AMD)' 'A' @(UP 'AppData\Local\D3DSCache'; UP 'AppData\Local\NVIDIA\DXCache'; UP 'AppData\Local\NVIDIA\GLCache'; UP 'AppData\LocalLow\NVIDIA\PerDriverVersion'; UP 'AppData\Local\AMD\DxCache'; UP 'AppData\Local\AMD\DxcCache'; UP 'AppData\Local\AMD\GLCache') 'Tu tao lai. Don bang Disk Cleanup > "DirectX Shader Cache".'
Add-Cat $catSys 'Thumbnail cache (Explorer)' 'A' (UP 'AppData\Local\Microsoft\Windows\Explorer') 'Anh thu nho. Don bang Disk Cleanup > "Thumbnails".'
Add-Cat $catSys 'Bo cai driver cu (NVIDIA/AMD/Intel)' 'B' @('C:\ProgramData\NVIDIA Corporation\Downloader'; 'C:\Program Files\NVIDIA Corporation\Installer2'; 'C:\AMD'; 'C:\Intel'; 'C:\Drivers') 'Bo cai driver da giai nen. Co the xoa sau khi xac nhan driver dang chay on dinh.'
Add-Cat $catSys 'Chi muc Windows Search' 'B' @('C:\ProgramData\Microsoft\Search\Data') 'Neu qua lon (> vai GB) -> rebuild chi muc trong Indexing Options, khong xoa tay.'
Add-Cat $catSys 'Windows Defender (lich su quet)' 'C' @('C:\ProgramData\Microsoft\Windows Defender\Scans') 'Khong xoa thu cong.'
Add-Cat $catSys 'Driver Store (FileRepository)' 'C' @('C:\Windows\System32\DriverStore\FileRepository') 'KHONG xoa thu cong. Driver cu chi go bang pnputil / Disk Cleanup "Device driver packages".'
Add-Cat $catSys 'Package Cache (bo cai Visual C++, .NET, VS)' 'C' @('C:\ProgramData\Package Cache') 'KHONG xoa - can de go/sua phan mem.'
Add-Cat $catSys 'Event logs (winevt)' 'C' @('C:\Windows\System32\winevt\Logs') 'Kich thuoc bi gioi han boi cau hinh log; khong xoa thu cong.'

$catDev = 'Lap trinh / AI'
Add-Cat $catDev 'Cache goi lap trinh (npm, pip, yarn, nuget, gradle, maven, cargo, conda)' 'B' @(UP 'AppData\Local\npm-cache'; UP 'AppData\Roaming\npm-cache'; UP 'AppData\Local\pip\Cache'; UP 'AppData\Local\Yarn\Cache'; UP 'AppData\Local\pnpm\store'; UP '.nuget\packages'; UP '.gradle\caches'; UP '.m2\repository'; UP '.cargo\registry'; UP 'anaconda3\pkgs'; UP 'miniconda3\pkgs'; UP '.conda\pkgs'; UP 'AppData\Local\uv\cache') 'Tai lai duoc. Don bang lenh cua tung cong cu (npm cache clean, pip cache purge, conda clean -a...).'
Add-Cat $catDev 'Mo hinh AI cuc bo (Ollama, HuggingFace, LM Studio)' 'B' @(UP '.ollama\models'; UP '.cache\huggingface'; UP '.lmstudio'; UP '.cache\lm-studio') 'Mo hinh AI rat lon. Xoa mo hinh khong dung bang chinh cong cu (ollama rm ...), hoac doi thu muc mo hinh sang o khac.'
Add-Cat $catDev 'Android SDK / JetBrains / Visual Studio cache' 'B' @(UP 'AppData\Local\Android\Sdk'; UP 'AppData\Local\JetBrains'; 'C:\ProgramData\Microsoft\VisualStudio\Packages') 'Bo cong cu lap trinh. Don bang trinh quan ly cua tung cong cu.'

$catOffice = 'Office / Outlook / sao luu dien thoai'
Add-Cat $catOffice 'Outlook OST (ban sao hop thu)' 'B' (UP 'AppData\Local\Microsoft\Outlook') 'Ban sao mail tu server. Giam bang Outlook > Account Settings > "Download email for the past: 6-12 months".'
Add-Cat $catOffice 'Outlook PST (hop thu luu tru)' 'CN' (UP 'Documents\Outlook Files') 'Thu luu tru ca nhan - KHONG xoa. Co the chuyen sang o khac.'
Add-Cat $catOffice 'Office Document Cache' 'B' (UP 'AppData\Local\Microsoft\Office\16.0\OfficeFileCache') 'Cache dong bo tai lieu Office.'
Add-Cat $catOffice 'Sao luu iPhone/iPad (iTunes / Apple Devices)' 'CN' @(UP 'AppData\Roaming\Apple Computer\MobileSync\Backup'; UP 'Apple\MobileSync\Backup') 'Ban sao luu dien thoai - KHONG xoa neu chua chac. Co the chuyen sang o khac.'

Add-Cat 'AppData (tong, tham khao)' 'AppData cua tung user (tong)' 'C' (UP 'AppData') 'Tong du lieu ung dung. KHONG xoa ca thu muc - xem chi tiet o muc AppData de biet ung dung nao.'
Add-Cat 'AppData (tong, tham khao)' 'Du lieu cac ung dung Store (AppData\Local\Packages, tong)' 'C' (UP 'AppData\Local\Packages') 'Chua du lieu nhieu app (WhatsApp, Messenger, Teams, WSL...). Xem chi tiet o muc AppData.'

$catPersonal = 'Du lieu ca nhan'
Add-Cat $catPersonal 'Desktop' 'CN' (UP 'Desktop') 'Du lieu ca nhan - KHONG xoa. Co the chuyen thu muc sang o khac (Properties > Location).'
Add-Cat $catPersonal 'Documents' 'CN' (UP 'Documents') 'Du lieu ca nhan - KHONG xoa. Co the chuyen thu muc sang o khac (Properties > Location).'
Add-Cat $catPersonal 'Downloads' 'CN' (UP 'Downloads') 'Thuong chua bo cai/file da tai. Ban tu xem lai; co the chuyen thu muc sang o khac.'
Add-Cat $catPersonal 'Pictures' 'CN' (UP 'Pictures') 'Du lieu ca nhan - KHONG xoa.'
Add-Cat $catPersonal 'Videos' 'CN' (UP 'Videos') 'Du lieu ca nhan - KHONG xoa.'
Add-Cat $catPersonal 'Music' 'CN' (UP 'Music') 'Du lieu ca nhan - KHONG xoa.'

$catOs = 'He dieu hanh & phan mem (tham khao)'
Add-Cat $catOs 'C:\Windows (toan bo)' 'C' @('C:\Windows') 'He dieu hanh. KHONG xoa bat ky thu gi thu cong.'
Add-Cat $catOs 'C:\Program Files + Program Files (x86)' 'C' @('C:\Program Files', 'C:\Program Files (x86)') 'Phan mem da cai. Chi go bang Settings > Apps.'
Add-Cat $catOs 'C:\ProgramData' 'C' @('C:\ProgramData') 'Du lieu dung chung cua phan mem. Khong xoa thu cong.'

foreach ($item in $catalog) { $item.Found = Resolve-Targets $item.Patterns }

# ----------------------------------------------------------------------------
# [2/5] Quet toan bo o C + chay DISM song song
# ----------------------------------------------------------------------------
$dismProc = $null; $dismNote = ''
$dismOutFile = Join-Path $runDir 'dism-AnalyzeComponentStore.txt'
if ($SkipDism) { $dismNote = 'Da bo qua (-SkipDism).' }
elseif (-not $onWindows) { $dismNote = 'Khong phai Windows.' }
elseif (-not $isAdmin) { $dismNote = 'Can quyen Administrator de chay DISM.' }
else {
    try {
        $dismExe = Join-Path $env:WINDIR 'System32\Dism.exe'
        $dismProc = Start-Process -FilePath $dismExe -ArgumentList '/Online /Cleanup-Image /AnalyzeComponentStore /English' `
            -NoNewWindow -PassThru -RedirectStandardOutput $dismOutFile -RedirectStandardError (Join-Path $runDir 'dism-err.txt')
    } catch { $dismNote = 'Khong chay duoc DISM: ' + $_.Exception.Message }
}

if (-not ('CDriveScan.Walker' -as [type])) {
    try {
        Add-Type -TypeDefinition $walkerSource -Language CSharp -ErrorAction Stop
    } catch {
        Write-Host ('[LOI] Khong bien dich duoc bo quet: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return
    }
}

$walker = New-Object CDriveScan.Walker
$walker.RecentCutoffFileTime = (Get-Date).AddDays(-$RecentDays).ToFileTimeUtc()
foreach ($item in $catalog) { foreach ($f in $item.Found) { [void]$walker.Targets.Add($f) } }
foreach ($p in $Profiles) {
    foreach ($s in @('AppData', 'AppData\Local', 'AppData\Roaming', 'AppData\LocalLow')) { [void]$walker.Targets.Add($p + '\' + $s) }
}
foreach ($e in @('.vhdx', '.vhd', '.avhdx', '.vmdk', '.vdi', '.qcow2', '.iso', '.img', '.dmp', '.hdmp', '.mdmp',
        '.esd', '.wim', '.ost', '.pst', '.bak', '.log', '.etl', '.evtx', '.tmp', '.edb', '.db')) {
    [void]$walker.SpecialExtensions.Add($e)
}

Write-Host ('[2/5] Quet toan bo o C (chi doc). Co the mat 3-20 phut tuy so luong file...')
$walkStart = Get-Date
$walker.Start('C:')
while ($walker.IsRunning) {
    $status = '{0:N0} file, {1:N0} thu muc, {2} da do' -f $walker.TotalFiles, $walker.TotalDirs, (Format-Size $walker.TotalBytes)
    $op = Limit-Text $walker.CurrentDir 100
    if (-not $op) { $op = '...' }
    Write-Progress -Activity 'Dang quet o C (chi doc)' -Status $status -CurrentOperation $op
    Start-Sleep -Milliseconds 700
}
$walker.Wait()
Write-Progress -Activity 'Dang quet o C (chi doc)' -Completed
$walkDuration = (Get-Date) - $walkStart
Write-Host ('      Xong: {0:N0} file, {1:N0} thu muc trong {2:hh\:mm\:ss}.' -f $walker.TotalFiles, $walker.TotalDirs, $walkDuration)
if ($walker.Error) { Write-Host ('[CANH BAO] Loi khi quet: {0}' -f $walker.Error) -ForegroundColor Yellow }

# ----------------------------------------------------------------------------
# [3/5] Cac thong tin can quyen Admin / lenh he thong (chi doc)
# ----------------------------------------------------------------------------
Write-Host '[3/5] Doc cau hinh pagefile, hibernate, System Restore, Windows Update...'

$dismText = ''
if ($dismProc) {
    Write-Host '      Dang doi DISM phan tich WinSxS (toi da 15 phut)...'
    if (-not $dismProc.WaitForExit(900000)) { $dismNote = 'DISM chay qua 15 phut, chua co ket qua (DISM van tiep tuc chay nen).' }
    try { $dismText = Get-Content -LiteralPath $dismOutFile -Raw -ErrorAction Stop } catch { }
}
$reservedText = ''
if ($onWindows -and $isAdmin) {
    $reservedText = Invoke-Native (Join-Path $env:WINDIR 'System32\Dism.exe') @('/Online', '/Get-ReservedStorageState', '/English')
}

$vssText = ''; $fsutilText = ''; $compactText = ''; $powercfgText = ''
if ($onWindows) {
    if ($isAdmin) {
        $vssText = Invoke-Native 'vssadmin.exe' @('list', 'shadowstorage')
        $fsutilText = Invoke-Native 'fsutil.exe' @('dirty', 'query', 'C:')
    }
    $compactText = Invoke-Native 'compact.exe' @('/compactos:query')
    $powercfgText = Invoke-Native 'powercfg.exe' @('/a')
}

# Shadow storage (System Restore)
$shadow = $null; $shadowCount = $null; $restorePoints = @()
try {
    $cVol = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='C:'" -ErrorAction Stop
    foreach ($s in @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction Stop)) {
        if ($s.Volume.DeviceID -eq $cVol.DeviceID) { $shadow = $s }
    }
    $shadowCount = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop | Where-Object { $_.VolumeName -eq $cVol.DeviceID }).Count
} catch { }
try {
    $restorePoints = @(Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore -ErrorAction Stop | ForEach-Object {
            $t = $null
            try { $t = [datetime]::ParseExact(([string]$_.CreationTime).Substring(0, 14), 'yyyyMMddHHmmss', $null) } catch { }
            [pscustomobject]@{ Time = $t; Description = $_.Description; Seq = $_.SequenceNumber }
        } | Sort-Object Seq -Descending)
} catch { }
$srDisabled = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'DisableSR'

# Pagefile / RAM / hibernate / crash dump
$pfUsage = @(); $pfSetting = @(); $hasBattery = $null
try { $pfUsage = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop) } catch { }
try { $pfSetting = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction Stop) } catch { }
try { $hasBattery = (@(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop).Count -gt 0) } catch { }
$hibernateEnabled = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
$hiberFileType = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HiberFileType'
$fastStartup = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
$crash = Get-RegValues 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
$werLocalDumps = Get-RegValues 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
$werLocalDumpApps = @()
try { $werLocalDumpApps = @(Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps' -ErrorAction Stop | ForEach-Object { $_.PSChildName }) } catch { }

# Windows Update
$pendingReboot = (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
(Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

# Storage Sense
$storageSense = Get-RegValues 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
$storageSensePolicy = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' 'AllowStorageSenseGlobal'

# Vi tri thu muc ca nhan (user hien tai)
$shellFolders = Get-RegValues 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'

# O dia vat ly + su kien
Write-Host '[4/5] Kiem tra suc khoe o dia, nhat ky su kien, tien trinh, phan mem...'
$physInfo = @(); $physErr = ''
try {
    $diskNum = (Get-Partition -DriveLetter C -ErrorAction Stop).DiskNumber
    foreach ($pd in @(Get-PhysicalDisk -ErrorAction Stop)) {
        $rel = $null
        if ($isAdmin) { try { $rel = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch { } }
        $physInfo += [pscustomobject]@{
            IsSystem = ([string]$pd.DeviceId -eq [string]$diskNum)
            Name = $pd.FriendlyName; Media = [string]$pd.MediaType; Bus = [string]$pd.BusType
            Health = [string]$pd.HealthStatus; Size = $pd.Size
            Wear = $(if ($rel) { $rel.Wear } else { $null })
            Temp = $(if ($rel) { $rel.Temperature } else { $null })
            ReadErrors = $(if ($rel) { $rel.ReadErrorsUncorrected } else { $null })
            Hours = $(if ($rel) { $rel.PowerOnHours } else { $null })
        }
    }
} catch { $physErr = $_.Exception.Message }

$lowDiskEvents = $null
try {
    $lowDiskEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'srv'; Id = 2013; StartTime = (Get-Date).AddDays(-30) } -ErrorAction Stop)
} catch {
    if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $lowDiskEvents = @() }
}
$diskErrEvents = $null
$diskProviders = @('disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'storahci', 'stornvme', 'volmgr', 'iaStorA', 'iaStorAC', 'iaStorAVC', 'iaStorVD', 'Microsoft-Windows-StorPort')
try {
    $diskErrEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 5000 -ErrorAction Stop |
        Where-Object { $diskProviders -contains $_.ProviderName })
} catch {
    if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $diskErrEvents = @() }
}

$procs = @()
try {
    $procs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Sort-Object WriteTransferCount -Descending | Select-Object -First 15)
} catch { }

$programs = @()
foreach ($up in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    try { $programs += @(Get-ItemProperty -Path $up -ErrorAction Stop) } catch { }
}
$programs = @($programs | Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } | ForEach-Object {
        $d = $null
        try { $d = [datetime]::ParseExact([string]$_.InstallDate, 'yyyyMMdd', $null) } catch { }
        [pscustomobject]@{
            Name = $_.DisplayName; Publisher = $_.Publisher; Date = $d
            SizeBytes = $(if ($_.EstimatedSize) { [double]$_.EstimatedSize * 1KB } else { 0 })
            Location = $_.InstallLocation
        }
    } | Sort-Object Name -Unique)

# ----------------------------------------------------------------------------
# [5/5] Tinh toan & lap bao cao
# ----------------------------------------------------------------------------
Write-Host '[5/5] Lap bao cao...'

$dirs = @($walker.Dirs)
$dirIndex = @{}
foreach ($d in $dirs) { $dirIndex[$d.Path] = $d }
$rootEntry = $dirIndex['C:']
$measured = [double]$walker.TotalBytes

# Kich thuoc "tu than" (khong trung lap): tong - cac thu muc con lon (>= 100 MB) da liet ke rieng
$own = @{}; $ownRecent = @{}; $children = @{}
foreach ($d in $dirs) { if ($d.IsBig) { $own[$d.Path] = [double]$d.Bytes; $ownRecent[$d.Path] = [double]$d.RecentBytes } }
foreach ($d in $dirs) {
    if (-not $d.IsBig -or $d.Depth -eq 0) { continue }
    $parent = $d.Path.Substring(0, $d.Path.LastIndexOf('\'))
    if ($own.ContainsKey($parent)) {
        $own[$parent] -= $d.Bytes
        $ownRecent[$parent] -= $d.RecentBytes
        if (-not $children.ContainsKey($parent)) { $children[$parent] = New-Object System.Collections.Generic.List[object] }
        $children[$parent].Add($d)
    }
}
$ownList = @($dirs | Where-Object { $_.IsBig } | ForEach-Object {
        [pscustomobject]@{ Path = $_.Path; Own = $own[$_.Path]; Total = [double]$_.Bytes; Files = $_.Files; OwnRecent = $ownRecent[$_.Path] }
    } | Sort-Object Own -Descending)

# Do kich thuoc tung muc trong danh muc
foreach ($item in $catalog) {
    foreach ($f in (Remove-NestedPaths $item.Found)) {
        $e = $dirIndex[$f]
        if ($e) {
            $item.Bytes += $e.Bytes; $item.Files += $e.Files; $item.Recent += $e.RecentBytes; $item.Cloud += $e.CloudBytes
            if ($e.Denied) { $item.Denied = $true }
        } else {
            $item.Missing += $f
        }
    }
}

function Get-LevelTotal {
    param([string]$Level)
    $paths = @()
    foreach ($item in $script:catalog) { if ($item.Level -eq $Level) { $paths += $item.Found } }
    $sum = [double]0
    foreach ($p in (Remove-NestedPaths $paths)) { $e = $script:dirIndex[$p]; if ($e) { $sum += $e.Bytes } }
    return $sum
}
$levelA = Get-LevelTotal 'A'
$levelB = Get-LevelTotal 'B'

$catOrder = New-Object System.Collections.Generic.List[string]
foreach ($item in $catalog) { if (-not $catOrder.Contains($item.Cat)) { $catOrder.Add($item.Cat) } }
$catTotals = @(foreach ($c in $catOrder) {
        # Chi tinh phan co the xu ly (A/B/CN); nhom chi toan muc C ("tham khao") thi tinh tong.
        $inCat = @($catalog | Where-Object { $_.Cat -eq $c })
        $use = @($inCat | Where-Object { $_.Level -ne 'C' })
        if ($use.Count -eq 0) { $use = $inCat }
        $paths = @(); foreach ($item in $use) { $paths += $item.Found }
        $sum = [double]0; $rec = [double]0
        foreach ($p in (Remove-NestedPaths $paths)) { $e = $dirIndex[$p]; if ($e) { $sum += $e.Bytes; $rec += $e.RecentBytes } }
        [pscustomobject]@{ Cat = $c; Bytes = $sum; Recent = $rec }
    })

# File he thong o goc C:\
$rootFiles = @($walker.RootFiles | Sort-Object Bytes -Descending)
function Get-RootFileSize {
    param([string]$Name)
    foreach ($f in $script:rootFiles) { if ($f.Path -ieq ('C:\' + $Name)) { return [double]$f.Bytes } }
    return $null
}
$pagefileBytes = Get-RootFileSize 'pagefile.sys'
$hiberfilBytes = Get-RootFileSize 'hiberfil.sys'
$swapfileBytes = Get-RootFileSize 'swapfile.sys'
$memoryDmp = $null
foreach ($f in $walker.SpecialFiles) { if ($f.Path -ieq 'C:\Windows\MEMORY.DMP') { $memoryDmp = $f } }

# So sanh voi lan quet truoc
$prevRun = $null; $prevMeta = $null; $prevOwn = $null
try {
    $prevRun = Get-ChildItem -LiteralPath $OutputDir -Directory -ErrorAction Stop |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' -and $_.Name -lt $runId -and (Test-Path -LiteralPath (Join-Path $_.FullName 'ThuMucLon.csv')) } |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($prevRun) {
        $prevOwn = @{}
        foreach ($r in (Import-Csv -LiteralPath (Join-Path $prevRun.FullName 'ThuMucLon.csv'))) { $prevOwn[$r.Path] = [double]$r.OwnBytes }
        $mp = Join-Path $prevRun.FullName 'meta.json'
        if (Test-Path -LiteralPath $mp) { $prevMeta = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json }
    }
} catch { }

# ============================================================================
# VIET BAO CAO
# ============================================================================
$standardRoot = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', 'Users', '$Recycle.Bin',
    'System Volume Information', 'Recovery', 'PerfLogs', '$WinREAgent', 'Config.Msi', 'OneDriveTemp',
    'Documents and Settings', '$Windows.~BT', '$Windows.~WS', 'Windows.old', 'MSOCache', '$SysReset', '$GetCurrent', 'DumpStack.log.tmp')

$freePct = 0
if ($capacity -gt 0) { $freePct = 100.0 * $freeBytes / $capacity }
$warn = ''
if ($capacity -gt 0) {
    if ($freePct -lt 5 -or $freeBytes -lt 5GB) { $warn = '  <== NGUY HIEM: rat it cho trong, Windows se cham/loi cap nhat' }
    elseif ($freePct -lt 10 -or $freeBytes -lt 15GB) { $warn = '  <== THAP: nen giu toi thieu 15-20% trong' }
}

Out-Line 'BAO CAO PHAN TICH DUNG LUONG O C  (CHE DO CHI DOC - KHONG XOA/SUA GI)'
Out-Line ('Thoi diem quet : {0}' -f $scanStart.ToString('yyyy-MM-dd HH:mm:ss'))
$osText = '?'
if ($os) { $osText = '{0} (version {1}, build {2})' -f $os.Caption, $os.Version, $os.BuildNumber }
Out-Line ('May / Windows  : {0} | {1}' -f $env:COMPUTERNAME, $osText)
if ($os -and $os.LastBootUpTime) {
    $up = (Get-Date) - $os.LastBootUpTime
    Out-Line ('Khoi dong luc  : {0} (da chay {1} ngay {2} gio)' -f (Format-Date $os.LastBootUpTime), [int]$up.TotalDays, $up.Hours)
}
Out-Line ('Quyen Admin    : {0}' -f $(if ($isAdmin) { 'CO' } else { 'KHONG  (so lieu he thong co the thieu - nen chay lai bang ChayQuet.cmd)' }))
Out-Line ('PowerShell     : {0} | Thoi gian quet file: {1:hh\:mm\:ss} | Moc "moi ghi": {2} ngay gan day' -f $PSVersionTable.PSVersion, $walkDuration, $RecentDays)

# ---------------------------------------------------------------- [0] Tom tat
Out-Section '[0] TOM TAT NHANH'
if ($capacity -gt 0) {
    Out-Line ('  O C: tong {0} | da dung {1} ({2}) | con trong {3} ({4}){5}' -f (Format-Size $capacity), (Format-Size $usedBytes), (Format-Pct $usedBytes $capacity), (Format-Size $freeBytes), (Format-Pct $freeBytes $capacity), $warn)
} else {
    Out-Line '  [!] Khong doc duoc thong tin o C qua WMI.'
}
Out-Line '  5 vi tri chiem nhieu nhat (khong trung lap, xem muc [2]):'
$i = 0
foreach ($o in ($ownList | Select-Object -First 5)) {
    $i++
    Out-Line ('     {0}. {1,11}  {2}' -f $i, (Format-Size $o.Own), (Show-Path $o.Path))
}
Out-Line '  Nhom lon nhat (xem muc [5]):'
foreach ($c in ($catTotals | Where-Object { $_.Cat -notlike '*tham khao*' } | Sort-Object Bytes -Descending | Select-Object -First 5)) {
    Out-Line ('     - {0,11}  {1}' -f (Format-Size $c.Bytes), $c.Cat)
}
if ($pagefileBytes -or $hiberfilBytes) {
    Out-Line ('  pagefile.sys: {0} | hiberfil.sys: {1}' -f $(if ($pagefileBytes) { Format-Size $pagefileBytes } else { 'khong co' }), $(if ($hiberfilBytes) { Format-Size $hiberfilBytes } else { 'khong co' }))
}
if ($shadow) { Out-Line ('  System Restore (shadow copy) dang dung: {0}' -f (Format-Size $shadow.UsedSpace)) }
Out-Line ('  Uoc tinh giai phong muc A (an toan tuyet doi)    : ~{0}' -f (Format-Size $levelA))
Out-Line ('  Uoc tinh them muc B (an toan, can ban quyet dinh): ~{0} (chua gom hiberfil / System Restore)' -f (Format-Size $levelB))
if ($rootEntry) {
    Out-Line ('  Du lieu moi ghi trong {0} ngay gan day: {1}' -f $RecentDays, (Format-Size $rootEntry.RecentBytes))
    $topRecent = $ownList | Sort-Object OwnRecent -Descending | Select-Object -First 1
    if ($topRecent -and $topRecent.OwnRecent -gt 0) { Out-Line ('     ghi nhieu nhat vao: {0} ({1})' -f (Show-Path $topRecent.Path), (Format-Size $topRecent.OwnRecent)) }
}
Out-Line '  (Script KHONG xoa gi. Cac muc A/B chi la de xuat - can ban xac nhan truoc khi don.)'

# ---------------------------------------------------------------- [1] Tong quan
Out-Section '[1] TONG QUAN O C & SUC KHOE O DIA'
if ($cDisk) {
    Out-Line ('  Tong dung luong : {0}' -f (Format-Size $capacity))
    Out-Line ('  Da su dung      : {0}  ({1})' -f (Format-Size $usedBytes), (Format-Pct $usedBytes $capacity))
    Out-Line ('  Con trong       : {0}  ({1}){2}' -f (Format-Size $freeBytes), (Format-Pct $freeBytes $capacity), $warn)
    Out-Line ('  He thong tep    : {0} | Nhan o: {1}' -f $cDisk.FileSystem, $cDisk.VolumeName)
} else {
    Out-Line '  [!] Khong doc duoc Win32_LogicalDisk cho o C.'
}
if ($otherDisks.Count -gt 0) {
    Out-Line '  O dia khac (noi co the chuyen du lieu ca nhan sang):'
    foreach ($d in $otherDisks) {
        Out-Line ('     {0}  tong {1}, con trong {2}  {3}' -f $d.DeviceID, (Format-Size $d.Size), (Format-Size $d.FreeSpace), $d.VolumeName)
    }
} else {
    Out-Line '  O dia khac: khong co (chi co o C).'
}
if ($physInfo.Count -gt 0) {
    Out-Line '  O dia vat ly:'
    foreach ($pd in $physInfo) {
        $extra = @()
        if ($null -ne $pd.Wear) { $extra += ('hao mon {0}%' -f $pd.Wear) }
        if ($pd.Temp) { $extra += ('{0} do C' -f $pd.Temp) }
        if ($pd.Hours) { $extra += ('{0:N0} gio chay' -f $pd.Hours) }
        if ($pd.ReadErrors) { $extra += ('LOI DOC KHONG SUA DUOC: {0}' -f $pd.ReadErrors) }
        Out-Line ('     {0}{1} | {2} | {3} | {4} | {5} {6}' -f $(if ($pd.IsSystem) { '[chua o C] ' } else { '' }), $pd.Name, $pd.Media, $pd.Bus, (Format-Size $pd.Size), $pd.Health, ($extra -join ', '))
    }
    if (@($physInfo | Where-Object { $_.IsSystem -and $_.Media -eq 'HDD' }).Count -gt 0) {
        Out-Line '     -> O C nam tren HDD (o cung co): khi gan day se cham hon nhieu so voi SSD.'
    }
} elseif ($physErr) { Out-Line ('  O dia vat ly: khong doc duoc ({0})' -f $physErr) }
if ($fsutilText) { Out-Line '  fsutil dirty query C: (o co bi danh dau can chkdsk?):'; Out-Raw $fsutilText 3 }
if ($null -ne $lowDiskEvents) {
    $ldTxt = '{0} lan' -f $lowDiskEvents.Count
    if ($lowDiskEvents.Count -gt 0) { $ldTxt += (', gan nhat {0}, som nhat {1}' -f (Format-Date $lowDiskEvents[0].TimeCreated), (Format-Date $lowDiskEvents[-1].TimeCreated)) }
    Out-Line ('  Canh bao "o day" cua Windows (System log, srv 2013) 30 ngay qua: {0}' -f $ldTxt)
}
if ($null -ne $diskErrEvents) {
    Out-Line ('  Loi/canh bao o dia - NTFS trong System log 30 ngay qua: {0}' -f $diskErrEvents.Count)
    foreach ($g in ($diskErrEvents | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 6)) {
        $first = $g.Group[0]
        Out-Line ('     {0,5} lan  {1} (ID {2}), gan nhat {3}: {4}' -f $g.Count, $first.ProviderName, $first.Id, (Format-Date $first.TimeCreated), (Limit-Text (($first.Message -split "`n")[0]) 90))
    }
}

# ---------------------------------------------------------------- [2] Top vi tri
Out-Section ('[2] TOP 20 VI TRI CHIEM DUNG LUONG (khong trung lap; moi byte chi tinh 1 lan)')
Out-Line '  "Tu than" = file nam truc tiep trong thu muc + cac thu muc con nho hon 100 MB.'
Out-Line '  Thu muc con >= 100 MB duoc tinh rieng o dong cua chinh no -> cong cac dong khong bi trung.'
Out-Line ''
Out-Line ('  {0,3}  {1,11}  {2,9}  {3,14}  {4}' -f '#', 'Tu than', '% da dung', 'Tong (gom con)', 'Duong dan')
$i = 0
foreach ($o in ($ownList | Select-Object -First 20)) {
    $i++
    Out-Line ('  {0,3}  {1,11}  {2,9}  {3,14}  {4}' -f $i, (Format-Size $o.Own), (Format-Pct $o.Own $usedBytes), (Format-Size $o.Total), (Show-Path $o.Path))
}

# ---------------------------------------------------------------- [3] Cay thu muc
Out-Section '[3] CAY THU MUC LON (cap 1: >= 100 MB; cap sau: >= 500 MB; di sau vao thu muc >= 1 GB)'
Out-Line '  Dau * = thu muc o goc C:\ khong phai thu muc chuan cua Windows (can xem ai tao ra).'
Out-Line ''
$script:treeLines = 0
$script:treeMax = 140
function Out-Tree {
    param([string]$Path, [int]$Level)
    if (-not $children.ContainsKey($Path)) { return }
    $min = 500MB
    if ($Level -eq 1) { $min = 100MB }
    $count = 0
    foreach ($k in ($children[$Path] | Sort-Object Bytes -Descending)) {
        if ($k.Bytes -lt $min -or $count -ge 12) { break }
        if ($script:treeLines -ge $script:treeMax) { return }
        $leaf = $k.Path.Substring($k.Path.LastIndexOf('\') + 1)
        $mark = ''
        if ($Level -eq 1 -and $standardRoot -notcontains $leaf) { $mark = ' *' }
        # Gop chuoi thu muc chi co 1 thu muc con chiem gan het dung luong (vd a\b\c)
        $node = $k
        while ($children.ContainsKey($node.Path)) {
            $kidList = $children[$node.Path]
            if ($kidList.Count -ne 1 -or $kidList[0].Bytes -lt 0.9 * $node.Bytes) { break }
            $node = $kidList[0]
            $leaf += '\' + $node.Path.Substring($node.Path.LastIndexOf('\') + 1)
        }
        $ownTxt = ''
        if ($children.ContainsKey($node.Path) -and $own[$node.Path] -ge 500MB) { $ownTxt = '   (tu than: {0})' -f (Format-Size $own[$node.Path]) }
        Out-Line ('  {0,11}  {1}{2}{3}{4}' -f (Format-Size $k.Bytes), ('    ' * ($Level - 1)), $leaf, $mark, $ownTxt)
        $script:treeLines++
        $count++
        if ($Level -lt 10 -and $node.Bytes -ge 1GB) { Out-Tree -Path $node.Path -Level ($Level + 1) }
    }
}
if ($rootEntry) {
    Out-Line ('  {0,11}  C:\  (tong do duoc)' -f (Format-Size $rootEntry.Bytes))
    Out-Tree -Path 'C:' -Level 1
    if ($script:treeLines -ge $script:treeMax) { Out-Line '  ... (cay da cat bot cho gon; danh sach day du trong ThuMucLon.csv)' }
    $smallRoot = @($dirs | Where-Object { $_.Depth -eq 1 -and $_.Bytes -lt 100MB })
    Out-Line ('  {0,11}  ({1} thu muc khac o goc, moi cai < 100 MB)' -f (Format-Size (($smallRoot | Measure-Object Bytes -Sum).Sum)), $smallRoot.Count)
    $deniedRoot = @($dirs | Where-Object { $_.Depth -eq 1 -and $_.Denied } | ForEach-Object { $_.Path })
    if ($deniedRoot.Count -gt 0) { Out-Line ('  Khong truy cap duoc (khong do duoc): {0}' -f ($deniedRoot -join '; ')) }
}
$oddRootFiles = @($rootFiles | Where-Object { $_.Bytes -ge 10MB -and @('pagefile.sys', 'hiberfil.sys', 'swapfile.sys') -notcontains $_.Path.Substring($_.Path.LastIndexOf('\') + 1) })
if ($oddRootFiles.Count -gt 0) {
    Out-Line '  File lon bat thuong nam o goc C:\ :'
    foreach ($f in $oddRootFiles) { Out-Line ('     {0,11}  {1}  ({2})' -f (Format-Size $f.Bytes), $f.Path, (Format-Date $f.LastWriteUtc.ToLocalTime())) }
}

# ---------------------------------------------------------------- [4] Top file
Out-Section '[4] TOP 20 FILE LON NHAT TREN O C'
$i = 0
foreach ($f in ($walker.TopFiles | Select-Object -First 20)) {
    $i++
    Out-Line ('  {0,3}  {1,11}  {2}  {3}' -f $i, (Format-Size $f.Bytes), (Format-Date $f.LastWriteUtc.ToLocalTime()), $f.Path)
}

# ---------------------------------------------------------------- [5] Xep hang nhom
Out-Section '[5] XEP HANG THEO NHOM NGUYEN NHAN (phan co the xu ly A/B/CN; nhom "tham khao" la so tong)'
$rank = @($catTotals)
if ($pagefileBytes) { $rank += [pscustomobject]@{ Cat = 'pagefile.sys + swapfile.sys (bo nho ao)'; Bytes = $pagefileBytes + [double]$swapfileBytes; Recent = 0 } }
if ($hiberfilBytes) { $rank += [pscustomobject]@{ Cat = 'hiberfil.sys (ngu dong / Fast Startup)'; Bytes = $hiberfilBytes; Recent = 0 } }
if ($shadow) { $rank += [pscustomobject]@{ Cat = 'System Restore / Shadow Copies'; Bytes = [double]$shadow.UsedSpace; Recent = 0 } }
foreach ($c in ($rank | Sort-Object Bytes -Descending)) {
    $r = ''
    if ($c.Recent -ge 50MB) { $r = '   (moi ghi {0} ngay: {1})' -f $RecentDays, (Format-Size $c.Recent) }
    Out-Line ('  {0,11}  {1,7}  {2}{3}' -f (Format-Size $c.Bytes), (Format-Pct $c.Bytes $usedBytes), $c.Cat, $r)
}
Out-Line '  Luu y: cac nhom "tham khao" bao trum nhieu nhom khac (vd AppData chua Temp, trinh duyet...).'

# ---------------------------------------------------------------- [6] Chi tiet nguyen nhan
Out-Section '[6] CHI TIET THEO NGUYEN NHAN (muc A / B / C / CN)'
Out-Line '  A  = an toan tuyet doi (cache/tam, tu tao lai; don bang cong cu chinh thong)'
Out-Line '  B  = an toan nhung can can nhac (mat rollback, phai tai lai, hoac la du lieu ung dung)'
Out-Line '  C  = khong nen dung vao / so tong de tham khao'
Out-Line '  CN = du lieu ca nhan: KHONG xoa, chi can nhac CHUYEN sang o khac'
$notFound = New-Object System.Collections.Generic.List[string]
foreach ($c in $catOrder) {
    $items = @($catalog | Where-Object { $_.Cat -eq $c })
    $present = @($items | Where-Object { $_.Found.Count -gt 0 })
    foreach ($it in ($items | Where-Object { $_.Found.Count -eq 0 })) { $notFound.Add($it.Name) }
    if ($present.Count -eq 0) { continue }
    Out-Line ''
    Out-Line ('  --- {0} ---' -f $c)
    foreach ($it in $present) {
        $flags = ''
        if ($it.Denied) { $flags += '  [mot phan KHONG truy cap duoc]' }
        Out-Line ('  [{0,-2}] {1,11}  {2}{3}' -f $it.Level, (Format-Size $it.Bytes), $it.Name, $flags)
        $rows = @(foreach ($f in $it.Found) { $e = $dirIndex[$f]; if ($e) { $e } })
        $shown = 0
        foreach ($e in @($rows | Sort-Object Bytes -Descending)) {
            if ($shown -ge 5) { break }
            if ($e.Bytes -lt 1MB -and $rows.Count -gt 1) { continue }
            $extra = ''
            if ($e.RecentBytes -ge 1MB) { $extra += (', moi ghi {0} ngay: {1}' -f $RecentDays, (Format-Size $e.RecentBytes)) }
            if ($e.CloudBytes -gt 0) { $extra += (', chi tren cloud (khong chiem cho): {0}' -f (Format-Size $e.CloudBytes)) }
            Out-Line ('{0,21}- {1}  ({2}, {3:N0} file{4})' -f '', $e.Path, (Format-Size $e.Bytes), $e.Files, $extra)
            $shown++
        }
        if ($it.Note -and $it.Bytes -ge 100MB) { Out-Line ('{0,21}  -> {1}' -f '', $it.Note) }
    }
}
if ($notFound.Count -gt 0) {
    Out-Line ''
    Out-Wrapped '  Da kiem tra, KHONG co tren may: ' @($notFound)
}
if ($lxss.Count -gt 0) {
    Out-Line ''
    Out-Line '  WSL distro dang dang ky (user hien tai):'
    foreach ($d in $lxss) { Out-Line ('     {0}  ->  {1}' -f $d.Name, $d.BasePath) }
}

# ---------------------------------------------------------------- [7] Pagefile / hiberfil
Out-Section '[7] PAGEFILE.SYS / HIBERFIL.SYS / BO NHO / CRASH DUMP'
$ramBytes = $null
if ($cs) { $ramBytes = [double]$cs.TotalPhysicalMemory }
Out-Line ('  RAM vat ly            : {0}' -f $(if ($ramBytes) { Format-Size $ramBytes } else { '?' }))
Out-Line ('  pagefile.sys          : {0}' -f $(if ($pagefileBytes) { Format-Size $pagefileBytes } else { 'khong co tren C' }))
if ($cs) { Out-Line ('  Windows tu quan ly pagefile: {0}' -f $(if ($cs.AutomaticManagedPagefile) { 'CO' } else { 'KHONG (dang dat thu cong)' })) }
foreach ($u in $pfUsage) {
    Out-Line ('  Su dung pagefile      : {0} | cap phat {1} | dang dung {2} | dinh tu luc khoi dong {3}' -f $u.Name, (Format-Size ([double]$u.AllocatedBaseSize * 1MB)), (Format-Size ([double]$u.CurrentUsage * 1MB)), (Format-Size ([double]$u.PeakUsage * 1MB)))
}
foreach ($s in $pfSetting) {
    Out-Line ('  Cau hinh pagefile     : {0} | Initial {1} MB | Max {2} MB (0/0 = he thong quan ly)' -f $s.Name, $s.InitialSize, $s.MaximumSize)
}
if ($os) {
    $commitUsed = ([double]$os.TotalVirtualMemorySize - [double]$os.FreeVirtualMemory) * 1KB
    Out-Line ('  Commit (RAM+pagefile) : dang dung {0} / gioi han {1} | RAM trong {2}' -f (Format-Size $commitUsed), (Format-Size ([double]$os.TotalVirtualMemorySize * 1KB)), (Format-Size ([double]$os.FreePhysicalMemory * 1KB)))
}
Out-Line ('  swapfile.sys          : {0}' -f $(if ($swapfileBytes) { Format-Size $swapfileBytes } else { 'khong co' }))
Out-Line ''
Out-Line ('  hiberfil.sys          : {0}' -f $(if ($hiberfilBytes) { Format-Size $hiberfilBytes } else { 'khong co' }))
Out-Line ('  Hibernate (registry)  : {0}' -f $(if ($null -eq $hibernateEnabled) { '?' } elseif ($hibernateEnabled -eq 1) { 'BAT' } else { 'TAT' }))
Out-Line ('  Kieu hiberfile        : {0}' -f $(if ($hiberFileType -eq 1) { 'Reduced (chi cho Fast Startup)' } elseif ($hiberFileType -eq 2) { 'Full (ho tro Hibernate)' } else { '? (mac dinh)' }))
Out-Line ('  Fast Startup          : {0}' -f $(if ($null -eq $fastStartup) { '?' } elseif ($fastStartup -eq 1) { 'BAT' } else { 'TAT' }))
Out-Line ('  May co pin (laptop?)  : {0}' -f $(if ($null -eq $hasBattery) { '?' } elseif ($hasBattery) { 'CO' } else { 'KHONG' }))
if ($powercfgText) { Out-Line '  powercfg /a (cac che do ngu kha dung):'; Out-Raw $powercfgText 20 }
Out-Line ''
if ($crash) {
    $cde = $crash['CrashDumpEnabled']
    $cdeTxt = switch ($cde) { 0 { 'None' } 1 { 'Complete memory dump' } 2 { 'Kernel memory dump' } 3 { 'Small memory dump (256 KB)' } 7 { 'Automatic memory dump' } default { [string]$cde } }
    Out-Line ('  Crash dump he thong   : {0} | DumpFile={1} | AlwaysKeepMemoryDump={2}' -f $cdeTxt, $crash['DumpFile'], $crash['AlwaysKeepMemoryDump'])
}
Out-Line ('  MEMORY.DMP            : {0}' -f $(if ($memoryDmp) { '{0} ({1})' -f (Format-Size $memoryDmp.Bytes), (Format-Date $memoryDmp.LastWriteUtc.ToLocalTime()) } else { 'khong co (hoac < 10 MB)' }))
if ($werLocalDumps -or $werLocalDumpApps.Count -gt 0) {
    $wl = @(); if ($werLocalDumps) { foreach ($k in $werLocalDumps.Keys) { $wl += ('{0}={1}' -f $k, $werLocalDumps[$k]) } }
    $appTxt = ''
    if ($werLocalDumpApps.Count -gt 0) {
        $appTxt = 'rieng cho: ' + (($werLocalDumpApps | Select-Object -First 6) -join ', ')
        if ($werLocalDumpApps.Count -gt 6) { $appTxt += (' ... (+{0} ung dung)' -f ($werLocalDumpApps.Count - 6)) }
    }
    Out-Line ('  [!] WER LocalDumps DANG BAT (ung dung crash se ghi dump ra dia): {0} {1}' -f ($wl -join ', '), $appTxt)
} else {
    Out-Line '  WER LocalDumps        : khong cau hinh (binh thuong)'
}

# ---------------------------------------------------------------- [8] System Restore
Out-Section '[8] SYSTEM RESTORE / SHADOW COPIES'
if ($shadow) {
    $maxTxt = Format-Size $shadow.MaxSpace
    if ([double]$shadow.MaxSpace -ge 1E18) { $maxTxt = 'KHONG GIOI HAN  <== co the chiem rat nhieu o C' }
    elseif ($capacity -gt 0) { $maxTxt += (' ({0} o C)' -f (Format-Pct $shadow.MaxSpace $capacity)) }
    Out-Line ('  Shadow storage cua C : da dung {0} | da cap {1} | toi da {2}' -f (Format-Size $shadow.UsedSpace), (Format-Size $shadow.AllocatedSpace), $maxTxt)
} elseif ($isAdmin) {
    Out-Line '  Khong co shadow storage cho o C (System Protection co the dang tat).'
} else {
    Out-Line '  Can quyen Administrator de doc shadow storage.'
}
if ($null -ne $shadowCount) { Out-Line ('  So ban shadow copy tren C: {0}' -f $shadowCount) }
if ($null -ne $srDisabled) { Out-Line ('  DisableSR (registry)     : {0}' -f $srDisabled) }
if ($restorePoints.Count -gt 0) {
    Out-Line ('  Restore points ({0}, moi nhat truoc):' -f $restorePoints.Count)
    foreach ($rp in ($restorePoints | Select-Object -First 10)) { Out-Line ('     {0}  {1}' -f (Format-Date $rp.Time), $rp.Description) }
}
if ($vssText) { Out-Line '  vssadmin list shadowstorage:'; Out-Raw $vssText 25 }

# ---------------------------------------------------------------- [9] Windows Update / DISM
Out-Section '[9] WINDOWS UPDATE / WINSXS (DISM) / RESERVED STORAGE / COMPACTOS'
Out-Line ('  Dang cho khoi dong lai de hoan tat cap nhat: {0}' -f $(if ($pendingReboot) { 'CO  <== nen khoi dong lai truoc khi don' } else { 'khong' }))
Out-Line '  DISM /AnalyzeComponentStore (so lieu chinh thuc cua WinSxS):'
if ($dismText) { Out-Raw $dismText 30 } else { Out-Line ('    {0}' -f $(if ($dismNote) { $dismNote } else { '(khong co du lieu)' })) }
if ($dismNote -and $dismText) { Out-Line ('    {0}' -f $dismNote) }
if ($reservedText) { Out-Line '  Reserved Storage (Windows giu san cho cap nhat):'; Out-Raw $reservedText 6 }
if ($compactText) { Out-Line '  CompactOS (nen he dieu hanh):'; Out-Raw $compactText 6 }

# ---------------------------------------------------------------- [10] AppData
Out-Section '[10] APPDATA CHI TIET (thu muc ung dung >= 100 MB, theo tung user)'
foreach ($p in $Profiles) {
    $ad = $dirIndex[$p + '\AppData']
    if (-not $ad -or $ad.Bytes -lt 100MB) { continue }
    Out-Line ''
    Out-Line ('  {0}\AppData  = {1}' -f $p, (Format-Size $ad.Bytes))
    foreach ($s in @('Local', 'Roaming', 'LocalLow')) {
        $sp = $p + '\AppData\' + $s
        $se = $dirIndex[$sp]
        if (-not $se -or $se.Bytes -lt 100MB) { continue }
        Out-Line ('    {0,11}  {1}' -f (Format-Size $se.Bytes), $s)
        if ($children.ContainsKey($sp)) {
            foreach ($k in ($children[$sp] | Sort-Object Bytes -Descending | Select-Object -First 15)) {
                $r = ''
                if ($k.RecentBytes -ge 50MB) { $r = '   (moi ghi {0} ngay: {1})' -f $RecentDays, (Format-Size $k.RecentBytes) }
                Out-Line ('      {0,11}  {1}{2}' -f (Format-Size $k.Bytes), $k.Path.Substring($sp.Length + 1), $r)
            }
        }
        if ($sp -like '*\AppData\Local' -and $children.ContainsKey($sp + '\Packages')) {
            Out-Line '         Packages (ung dung Store) lon nhat:'
            foreach ($k in ($children[$sp + '\Packages'] | Sort-Object Bytes -Descending | Select-Object -First 8)) {
                Out-Line ('        {0,11}  {1}' -f (Format-Size $k.Bytes), $k.Path.Substring($sp.Length + 10))
            }
        }
    }
}

# ---------------------------------------------------------------- [11] Moi ghi
Out-Section ('[11] DU LIEU MOI GHI TRONG {0} NGAY GAN DAY (tim ung dung dang lien tuc tao du lieu)' -f $RecentDays)
if ($rootEntry) { Out-Line ('  Tong file co thoi gian sua trong {0} ngay: {1}' -f $RecentDays, (Format-Size $rootEntry.RecentBytes)) }
Out-Line '  Vi tri nhan nhieu du lieu moi nhat (khong trung lap):'
foreach ($o in ($ownList | Where-Object { $_.OwnRecent -ge 50MB } | Sort-Object OwnRecent -Descending | Select-Object -First 15)) {
    Out-Line ('     {0,11}  {1}' -f (Format-Size $o.OwnRecent), (Show-Path $o.Path))
}
Out-Line '  File lon nhat duoc ghi/sua gan day:'
foreach ($f in ($walker.RecentFiles | Select-Object -First 20)) {
    Out-Line ('     {0,11}  {1}  {2}' -f (Format-Size $f.Bytes), (Format-Date $f.LastWriteUtc.ToLocalTime()), $f.Path)
}

# ---------------------------------------------------------------- [12] Tien trinh
Out-Section '[12] TIEN TRINH DA GHI NHIEU DU LIEU NHAT (tu luc tien trinh khoi dong)'
Out-Line '  (Gom ca ghi file, mang, pipe - dung de nghi van, chua phai ket luan.)'
foreach ($pr in $procs) {
    $rate = ''
    if ($pr.CreationDate) {
        $hrs = ((Get-Date) - $pr.CreationDate).TotalHours
        if ($hrs -gt 0.05) { $rate = '{0}/gio' -f (Format-Size ([double]$pr.WriteTransferCount / $hrs)) }
    }
    $path = $pr.ExecutablePath
    if (-not $path) { $path = '(tien trinh he thong / khong xem duoc duong dan)' }
    Out-Line ('  {0,11}  {1,12}  {2} (PID {3})  {4}' -f (Format-Size ([double]$pr.WriteTransferCount)), $rate, $pr.Name, $pr.ProcessId, $path)
}

# ---------------------------------------------------------------- [13] File dac biet
Out-Section '[13] O DIA AO / DUMP / ISO / LOG / DATABASE LON (>= 10 MB)'
foreach ($f in (@($walker.SpecialFiles) | Sort-Object Bytes -Descending | Select-Object -First 30)) {
    Out-Line ('  {0,11}  {1}  {2}' -f (Format-Size $f.Bytes), (Format-Date $f.LastWriteUtc.ToLocalTime()), $f.Path)
}

# ---------------------------------------------------------------- [14] Loai file
Out-Section '[14] DUNG LUONG THEO LOAI FILE (top 20 phan mo rong)'
foreach ($x in (@($walker.Extensions.Values) | Sort-Object Bytes -Descending | Select-Object -First 20)) {
    Out-Line ('  {0,11}  {1,7}  {2,-14} {3,10:N0} file' -f (Format-Size $x.Bytes), (Format-Pct $x.Bytes $measured), $x.Ext, $x.Files)
}

# ---------------------------------------------------------------- [15] Phan mem
Out-Section '[15] PHAN MEM DA CAI (de doi chieu "toi khong cai them gi")'
Out-Line '  Lon nhat theo kich thuoc tu khai bao (chi tham khao, nhieu phan mem khai bao sai):'
foreach ($pg in ($programs | Where-Object { $_.SizeBytes -gt 0 } | Sort-Object SizeBytes -Descending | Select-Object -First 20)) {
    Out-Line ('     {0,11}  {1}  ({2})' -f (Format-Size $pg.SizeBytes), $pg.Name, $(if ($pg.Date) { Format-Date $pg.Date } else { '?' }))
}
$recentPrograms = @($programs | Where-Object { $_.Date -and $_.Date -ge (Get-Date).AddDays(-90) } | Sort-Object Date -Descending)
Out-Line ('  Cai/cap nhat trong 90 ngay gan day: {0}' -f $recentPrograms.Count)
foreach ($pg in ($recentPrograms | Select-Object -First 30)) {
    Out-Line ('     {0}  {1}  [{2}]' -f $pg.Date.ToString('yyyy-MM-dd'), $pg.Name, $pg.Publisher)
}

# ---------------------------------------------------------------- [16] Cau hinh
Out-Section '[16] CAU HINH LIEN QUAN (Storage Sense, vi tri thu muc ca nhan)'
if ($storageSense) {
    $ssOn = $storageSense['01']
    Out-Line ('  Storage Sense: {0}' -f $(if ($ssOn -eq 1) { 'BAT' } else { 'TAT' }))
    $freq = $storageSense['2048']
    if ($null -ne $freq) { Out-Line ('     Tan suat chay: {0}' -f $(switch ($freq) { 0 { 'khi o sap day' } 1 { 'hang ngay' } 7 { 'hang tuan' } 30 { 'hang thang' } default { $freq } })) }
    if ($null -ne $storageSense['04']) { Out-Line ('     Xoa file tam cua ung dung: {0}' -f $storageSense['04']) }
    if ($null -ne $storageSense['08']) { Out-Line ('     Don thung rac: {0} (sau {1} ngay)' -f $storageSense['08'], $storageSense['256']) }
    if ($null -ne $storageSense['32']) { Out-Line ('     Don Downloads: {0} (sau {1} ngay)' -f $storageSense['32'], $storageSense['512']) }
    $raw = @(); foreach ($k in $storageSense.Keys) { $raw += ('{0}={1}' -f $k, $storageSense[$k]) }
    Out-Line ('     (gia tri goc: {0})' -f ($raw -join ', '))
} else {
    Out-Line '  Storage Sense: chua tung cau hinh (mac dinh TAT)'
}
if ($null -ne $storageSensePolicy) { Out-Line ('  Group Policy AllowStorageSenseGlobal = {0}' -f $storageSensePolicy) }
if ($shellFolders) {
    Out-Line '  Vi tri thu muc ca nhan cua user hien tai:'
    $names = [ordered]@{ 'Desktop' = 'Desktop'; 'Personal' = 'Documents'; '{374DE290-123F-4565-9164-39C4925E467B}' = 'Downloads'; 'My Pictures' = 'Pictures'; 'My Video' = 'Videos'; 'My Music' = 'Music' }
    foreach ($k in $names.Keys) { if ($shellFolders[$k]) { Out-Line ('     {0,-10} -> {1}' -f $names[$k], $shellFolders[$k]) } }
}

# ---------------------------------------------------------------- [17] So sanh
Out-Section '[17] SO SANH VOI LAN QUET TRUOC'
if ($prevRun -and $prevOwn) {
    $span = $scanStart - [datetime]::ParseExact($prevRun.Name, 'yyyyMMdd-HHmmss', $null)
    Out-Line ('  Lan truoc: {0} (cach day {1:N1} gio)' -f $prevRun.Name, $span.TotalHours)
    if ($prevMeta -and $capacity -gt 0) {
        $dFree = $freeBytes - [double]$prevMeta.FreeBytes
        Out-Line ('  Dung luong trong thay doi: {0} (truoc {1} -> nay {2})' -f (Format-Size $dFree), (Format-Size ([double]$prevMeta.FreeBytes)), (Format-Size $freeBytes))
    }
    $deltas = @()
    $keys = @($own.Keys) + @($prevOwn.Keys) | Select-Object -Unique
    foreach ($k in $keys) {
        $cur = 0.0; $old = 0.0
        if ($own.ContainsKey($k)) { $cur = $own[$k] }
        if ($prevOwn.ContainsKey($k)) { $old = $prevOwn[$k] }
        $deltas += [pscustomobject]@{ Path = $k; Delta = $cur - $old }
    }
    Out-Line '  Tang nhieu nhat:'
    foreach ($d in ($deltas | Where-Object { $_.Delta -ge 10MB } | Sort-Object Delta -Descending | Select-Object -First 15)) {
        Out-Line ('     +{0,10}  {1}' -f (Format-Size $d.Delta), (Show-Path $d.Path))
    }
    Out-Line '  Giam nhieu nhat:'
    foreach ($d in ($deltas | Where-Object { $_.Delta -le -10MB } | Sort-Object Delta | Select-Object -First 5)) {
        Out-Line ('     {0,11}  {1}' -f (Format-Size $d.Delta), (Show-Path $d.Path))
    }
} else {
    Out-Line '  Chua co lan quet truoc. Hay chay lai script sau vai gio / 1 ngay su dung binh thuong:'
    Out-Line '  muc nay se chi ra CHINH XAC thu muc nao dang phinh to.'
}

# ---------------------------------------------------------------- [18] Uoc tinh
Out-Section '[18] UOC TINH CO THE GIAI PHONG (CHUA THUC HIEN GI) & NHUNG THU KHONG NEN XOA'
Out-Line ('  Muc A - an toan tuyet doi (cache/tam/dump/Store/shader...)   : ~{0}' -f (Format-Size $levelA))
Out-Line ('  Muc B - can can nhac (Windows.old, thung rac, app data...)    : ~{0}' -f (Format-Size $levelB))
if ($hiberfilBytes) { Out-Line ('  Muc B - hiberfil.sys (tat Hibernate hoac dat kieu Reduced)    : toi da {0}' -f (Format-Size $hiberfilBytes)) }
if ($shadow -and [double]$shadow.UsedSpace -gt 0) { Out-Line ('  Muc B - thu nho System Restore (xoa restore point cu)         : mot phan cua {0}' -f (Format-Size $shadow.UsedSpace)) }
Out-Line '  Muc A - DISM /StartComponentCleanup: xem "Backups and Disabled Features" o muc [9].'
Out-Line '  (So thuc te giai phong co the khac: file dang bi khoa se khong xoa duoc.)'
Out-Line ''
Out-Line '  KHONG NEN XOA THU CONG (so lieu de tham khao):'
foreach ($p in @('C:\Windows\WinSxS', 'C:\Windows\System32', 'C:\Windows\System32\DriverStore', 'C:\Windows\Installer', 'C:\ProgramData\Package Cache', 'C:\Program Files\WindowsApps', 'C:\Windows\SoftwareDistribution\DataStore')) {
    $e = $dirIndex[$p]
    $sz = 'chua do / < 100 MB'
    if ($e) { $sz = Format-Size $e.Bytes; if ($e.Denied) { $sz = 'khong truy cap duoc' } }
    Out-Line ('     {0,-45} {1}' -f $p, $sz)
}
Out-Line '     pagefile.sys (chi dieu chinh qua System Properties sau khi danh gia RAM)'
Out-Line '     System Volume Information (chi quan ly qua System Protection / vssadmin)'
Out-Line '     Registry, driver, ca thu muc AppData/ProgramData, file trong Documents/Desktop/Pictures...'

# ---------------------------------------------------------------- [19] Do chinh xac
Out-Section '[19] GHI CHU DO LUONG'
Out-Line ('  Tong kich thuoc file do duoc  : {0} ({1:N0} file, {2:N0} thu muc)' -f (Format-Size $measured), $walker.TotalFiles, $walker.TotalDirs)
if ($capacity -gt 0) {
    $gap = $usedBytes - $measured
    Out-Line ('  Da dung theo Windows          : {0}  -> chenh lech {1}' -f (Format-Size $usedBytes), (Format-Size $gap))
    Out-Line '     Chenh lech den tu: shadow copy (System Volume Information), metadata NTFS ($MFT, nhat ky),'
    Out-Line '     thu muc khong truy cap duoc, va file nho < 32 KB co hard link (khong kiem tra de quet nhanh).'
}
Out-Line ('  Thu muc khong truy cap duoc   : {0:N0}' -f $walker.DeniedDirs)
foreach ($s in ($walker.DeniedSamples | Select-Object -First 8)) { Out-Line ('     {0}' -f $s) }
Out-Line ('  Junction/symlink da bo qua    : {0:N0} (tranh dem trung)' -f $walker.SkippedLinks)
Out-Line ('  File chi tren cloud (OneDrive): {0:N0} file, {1} - KHONG chiem cho o C, khong tinh vao tong' -f $walker.PlaceholderFiles, (Format-Size $walker.PlaceholderBytes))
Out-Line ('  Tiet kiem nho nen NTFS/WOF/CompactOS/sparse: {0} (da tinh theo dung luong thuc tren dia)' -f (Format-Size $walker.CompressedSavedBytes))
Out-Line ('  Hard link trung (chi tinh 1 lan)        : {0:N0} file, {1} (khong mo duoc de kiem tra: {2:N0} file)' -f $walker.HardLinkDupFiles, (Format-Size $walker.HardLinkDupBytes), $walker.HardLinkOpenFailures)
if ($walker.Error) { Out-Line ('  [!] Loi bo quet: {0}' -f $walker.Error) }
Out-Line ''
Out-Line ('  File chi tiet: ThuMucLon.csv, FileLon.csv, FileMoiGhi.csv, PhanLoai.csv trong {0}' -f $runDir)

# ============================================================================
# Ghi file
# ============================================================================
$reportPath = Join-Path $runDir 'BaoCao-TomTat.txt'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllLines($reportPath, $script:Lines.ToArray(), $utf8Bom)

$ownList | ForEach-Object {
    $e = $dirIndex[$_.Path]
    [pscustomobject]@{
        Path = $_.Path; Depth = $e.Depth; Bytes = [long]$_.Total; OwnBytes = [long]$_.Own; Files = $_.Files
        RecentBytes = $e.RecentBytes; CloudOnlyBytes = $e.CloudBytes; GB = [math]::Round($_.Total / 1GB, 2); OwnGB = [math]::Round($_.Own / 1GB, 2)
    }
} | Export-Csv -LiteralPath (Join-Path $runDir 'ThuMucLon.csv') -NoTypeInformation -Encoding UTF8
$walker.TopFiles | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Bytes = $_.Bytes; MB = [math]::Round($_.Bytes / 1MB, 1); LastWrite = $_.LastWriteUtc.ToLocalTime() } } |
    Export-Csv -LiteralPath (Join-Path $runDir 'FileLon.csv') -NoTypeInformation -Encoding UTF8
$walker.RecentFiles | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Bytes = $_.Bytes; MB = [math]::Round($_.Bytes / 1MB, 1); LastWrite = $_.LastWriteUtc.ToLocalTime() } } |
    Export-Csv -LiteralPath (Join-Path $runDir 'FileMoiGhi.csv') -NoTypeInformation -Encoding UTF8
$catalog | ForEach-Object { [pscustomobject]@{ Cat = $_.Cat; Name = $_.Name; Level = $_.Level; Bytes = $_.Bytes; GB = [math]::Round($_.Bytes / 1GB, 2); Files = $_.Files; RecentBytes = $_.Recent; Paths = ($_.Found -join ' | '); Note = $_.Note } } |
    Export-Csv -LiteralPath (Join-Path $runDir 'PhanLoai.csv') -NoTypeInformation -Encoding UTF8
[pscustomobject]@{ RunId = $runId; ScanTime = $scanStart.ToString('o'); CapacityBytes = $capacity; FreeBytes = $freeBytes; MeasuredBytes = $measured; IsAdmin = $isAdmin } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDir 'meta.json') -Encoding UTF8

Write-Host ''
Write-Host '=== XONG (khong co gi bi xoa hay thay doi) ===' -ForegroundColor Green
if ($capacity -gt 0) {
    Write-Host ('O C: tong {0} | da dung {1} | con trong {2}' -f (Format-Size $capacity), (Format-Size $usedBytes), (Format-Size $freeBytes))
}
Write-Host ('Bao cao: {0}' -f $reportPath)
Write-Host 'Hay mo file BaoCao-TomTat.txt, xem lai (co the che ten file rieng tu), roi gui noi dung cho Claude.'
if ($onWindows -and [Environment]::UserInteractive) { try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $reportPath) } catch { } }
