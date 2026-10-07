<#
.SYNOPSIS
    Tự động: quét ổ C -> phân tích -> dọn dẹp AN TOÀN -> xử lý nguyên nhân -> quét lại -> cấu hình chống đầy lại.

.DESCRIPTION
    Chỉ tự xoá những thứ Windows/ứng dụng tự tạo lại được:
      - Tệp tạm (%TEMP% cũ hơn 24 giờ, Windows Temp cũ hơn 48 giờ)
      - Bộ nhớ đệm tải Windows Update (khi Windows không chờ khởi động lại / không đang cài cập nhật)
      - Delivery Optimization (bằng lệnh chính thức Delete-DeliveryOptimizationCache)
      - Báo cáo lỗi (WER) và crash dump (ghi lại tên ứng dụng bị lỗi trước khi xoá)
      - Thùng rác: chỉ những mục đã xoá hơn N ngày (mặc định 3)
      - Cache trình duyệt / ứng dụng (chỉ khi ứng dụng đó đang TẮT), cache shader GPU, thumbnail
      - Log CBS cũ hơn 7 ngày, Microsoft Store cache
      - Component Store của Windows Update bằng DISM /StartComponentCleanup (KHÔNG dùng /ResetBase)

    KHÔNG BAO GIỜ đụng vào: System32, WinSxS (thủ công), registry (ngoài cấu hình Storage Sense),
    driver, file cá nhân (Desktop/Documents/Downloads/Pictures/Videos/Music, OneDrive),
    toàn bộ AppData, pagefile.sys, hiberfil.sys, Windows.old, dữ liệu Docker/WSL, Zalo/Telegram/CapCut.
    Không đi theo junction/symlink (không thể lan sang thư mục khác).

    Cấu hình chống đầy lại: bật Storage Sense (không bao giờ dọn Downloads), giới hạn System Restore
    hợp lý (giữ điểm khôi phục mới nhất), cài cảnh báo hằng ngày khi ổ C sắp đầy.

.PARAMETER ChiXem
    Chạy thử: chỉ tính sẽ dọn được bao nhiêu, không xoá và không đổi cấu hình gì.

.PARAMETER BoQuaDonDism
    Không chạy DISM /StartComponentCleanup (bước này có thể mất 5-30 phút).

.PARAMETER GiuThungRacNgay
    Giữ lại các mục trong Thùng rác được xoá trong N ngày gần đây (mặc định 3; 0 = làm rỗng hết).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\TuDongDonO-C.ps1
#>
[CmdletBinding()]
param(
    [switch]$ChiXem,
    [switch]$BoQuaDonDism,
    [ValidateRange(0, 365)]
    [int]$GiuThungRacNgay = 3,
    [string]$ThuMucBaoCao,
    [switch]$KhongMoNotepad
)

$ErrorActionPreference = 'Continue'

# ----------------------------------------------------------------------------
# Tự nâng quyền Administrator + đảm bảo PowerShell 64-bit
# ----------------------------------------------------------------------------
function Get-RelaunchArgs {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath))
    if ($ChiXem) { $a += '-ChiXem' }
    if ($BoQuaDonDism) { $a += '-BoQuaDonDism' }
    $a += @('-GiuThungRacNgay', $GiuThungRacNgay)
    if ($ThuMucBaoCao) { $a += @('-ThuMucBaoCao', ('"{0}"' -f $ThuMucBaoCao)) }
    if ($KhongMoNotepad) { $a += '-KhongMoNotepad' }
    return $a
}

$isAdmin = $false
try {
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
if (-not $isAdmin) {
    Write-Host 'Cần quyền Administrator: cửa sổ UAC sẽ hiện ra, hãy bấm "Yes"...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList (Get-RelaunchArgs) -ErrorAction Stop
    } catch {
        Write-Host 'Không lấy được quyền Administrator - chưa làm gì cả.' -ForegroundColor Red
    }
    return
}
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $native = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $native) { Start-Process -FilePath $native -ArgumentList (Get-RelaunchArgs); return }
}

# ----------------------------------------------------------------------------
# Chuẩn bị
# ----------------------------------------------------------------------------
$startTime = Get-Date
$stamp = $startTime.ToString('yyyyMMdd-HHmmss')
$here = $PSScriptRoot
$scanScript = Join-Path $here 'Scan-CDrive.ps1'
if (-not $ThuMucBaoCao) { $ThuMucBaoCao = Join-Path $here 'BaoCao' }
$scanOut = Join-Path $ThuMucBaoCao 'Quet'
$runOut = Join-Path $ThuMucBaoCao ('DonDep-' + $stamp)
New-Item -ItemType Directory -Path $runOut -Force | Out-Null
try { Start-Transcript -LiteralPath (Join-Path $runOut 'NhatKy.txt') -Force | Out-Null } catch { }

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

function Get-DiskC {
    try { return Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop } catch { return $null }
}
function Get-FreeBytes {
    $d = Get-DiskC
    if ($d) { return [double]$d.FreeSpace }
    return [double]0
}

function Write-Buoc {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 90) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 90) -ForegroundColor Cyan
}
function Write-Info {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host ('  ' + $Text) -ForegroundColor $Color
}

# ----------------------------------------------------------------------------
# Bộ dọn an toàn (C#): không đi theo junction/symlink, không xoá file đang mở,
# lọc theo tuổi file (cả ngày tạo lẫn ngày sửa), hỗ trợ đường dẫn dài, chế độ chạy thử.
# ----------------------------------------------------------------------------
$cleanerSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace CDriveClean
{
    public class Result
    {
        public long Bytes;
        public long Files;
        public long Dirs;
        public long Failed;
        public long Skipped;
        public long KeptBytes;

        public void Add(Result o)
        {
            if (o == null) return;
            Bytes += o.Bytes;
            Files += o.Files;
            Dirs += o.Dirs;
            Failed += o.Failed;
            Skipped += o.Skipped;
            KeptBytes += o.KeptBytes;
        }
    }

    public static class Cleaner
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
        private static extern bool DeleteFileW(string lpFileName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool RemoveDirectoryW(string lpPathName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetFileAttributesW(string lpFileName, uint dwFileAttributes);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFileAttributesW(string lpFileName);

        private static readonly IntPtr INVALID_HANDLE = new IntPtr(-1);
        private const uint INVALID_ATTRIBUTES = 0xFFFFFFFF;
        private const uint ATTR_READONLY = 0x1;
        private const uint ATTR_DIRECTORY = 0x10;
        private const uint ATTR_REPARSE = 0x400;
        private const uint ATTR_NORMAL = 0x80;

        public static bool DryRun = false;

        private struct Entry
        {
            public string Name;
            public uint Attr;
            public long Size;
            public long Write;
            public long Create;
        }

        private static string Long(string p)
        {
            if (p.StartsWith(@"\\?\")) return p;
            return @"\\?\" + p;
        }

        private static long Combine(uint high, uint low)
        {
            return ((long)high << 32) | (long)low;
        }

        private static List<Entry> List(string dir, out bool ok)
        {
            List<Entry> list = new List<Entry>();
            WIN32_FIND_DATAW fd;
            IntPtr h = FindFirstFileExW(Long(dir) + @"\*", 1, out fd, 0, IntPtr.Zero, 2);
            if (h == INVALID_HANDLE)
            {
                ok = false;
                return list;
            }
            try
            {
                do
                {
                    if (fd.cFileName == "." || fd.cFileName == "..") continue;
                    Entry e = new Entry();
                    e.Name = fd.cFileName;
                    e.Attr = fd.dwFileAttributes;
                    e.Size = Combine(fd.nFileSizeHigh, fd.nFileSizeLow);
                    e.Write = Combine(fd.ftLastWriteTime.High, fd.ftLastWriteTime.Low);
                    e.Create = Combine(fd.ftCreationTime.High, fd.ftCreationTime.Low);
                    list.Add(e);
                }
                while (FindNextFileW(h, out fd));
            }
            finally
            {
                FindClose(h);
            }
            ok = true;
            return list;
        }

        private static bool IsOld(long fileTime, long cutoff)
        {
            return cutoff <= 0 || fileTime < cutoff;
        }

        public static bool Match(string name, string pattern)
        {
            if (string.IsNullOrEmpty(pattern) || pattern == "*") return true;
            int si = 0, pi = 0, star = -1, mark = 0;
            while (si < name.Length)
            {
                if (pi < pattern.Length && (pattern[pi] == '?' || char.ToLowerInvariant(pattern[pi]) == char.ToLowerInvariant(name[si])))
                {
                    si++;
                    pi++;
                }
                else if (pi < pattern.Length && pattern[pi] == '*')
                {
                    star = pi++;
                    mark = si;
                }
                else if (star != -1)
                {
                    pi = star + 1;
                    si = ++mark;
                }
                else
                {
                    return false;
                }
            }
            while (pi < pattern.Length && pattern[pi] == '*') pi++;
            return pi == pattern.Length;
        }

        private static bool DeleteWithAttr(string full, uint attr)
        {
            if (DryRun) return true;
            string lp = Long(full);
            if ((attr & ATTR_READONLY) != 0)
            {
                uint na = attr & ~ATTR_READONLY & ~ATTR_DIRECTORY;
                if (na == 0) na = ATTR_NORMAL;
                SetFileAttributesW(lp, na);
            }
            return DeleteFileW(lp);
        }

        // Delete the CONTENTS of dir (keeps dir itself). cutoff = FILETIME UTC; 0 = no age filter.
        public static Result CleanDir(string dir, long cutoff, string pattern, bool removeEmptyDirs)
        {
            Result r = new Result();
            string d = dir.TrimEnd('\\');
            uint a = GetFileAttributesW(Long(d));
            if (a == INVALID_ATTRIBUTES || (a & ATTR_DIRECTORY) == 0) return r;
            if ((a & ATTR_REPARSE) != 0)
            {
                r.Skipped++;
                return r;
            }
            CleanRec(d, cutoff, string.IsNullOrEmpty(pattern) ? "*" : pattern, removeEmptyDirs, r);
            return r;
        }

        private static bool CleanRec(string dir, long cutoff, string pattern, bool removeEmpty, Result r)
        {
            bool ok;
            List<Entry> entries = List(dir, out ok);
            if (!ok)
            {
                r.Failed++;
                return false;
            }
            bool empty = true;
            foreach (Entry e in entries)
            {
                string full = dir + "\\" + e.Name;
                // Junction / symlink / cloud file: never follow, never delete.
                if ((e.Attr & ATTR_REPARSE) != 0)
                {
                    r.Skipped++;
                    empty = false;
                    continue;
                }
                if ((e.Attr & ATTR_DIRECTORY) != 0)
                {
                    bool subEmpty = CleanRec(full, cutoff, pattern, removeEmpty, r);
                    if (subEmpty && removeEmpty && IsOld(e.Create, cutoff) && !DryRun && RemoveDirectoryW(Long(full)))
                    {
                        r.Dirs++;
                    }
                    else
                    {
                        empty = false;
                    }
                    continue;
                }
                if (!Match(e.Name, pattern))
                {
                    empty = false;
                    continue;
                }
                if (!IsOld(e.Write, cutoff) || !IsOld(e.Create, cutoff))
                {
                    r.Skipped++;
                    empty = false;
                    continue;
                }
                if (DeleteWithAttr(full, e.Attr))
                {
                    r.Bytes += e.Size;
                    r.Files++;
                    if (DryRun) empty = false;
                }
                else
                {
                    r.Failed++;
                    empty = false;
                }
            }
            return empty;
        }

        // Delete a whole directory (used for Recycle Bin items).
        public static Result DeleteTree(string dir)
        {
            Result r = CleanDir(dir, 0, "*", true);
            if (!DryRun && r.Skipped == 0 && RemoveDirectoryW(Long(dir.TrimEnd('\\')))) r.Dirs++;
            return r;
        }

        public static bool DeleteOne(string path)
        {
            uint a = GetFileAttributesW(Long(path));
            if (a == INVALID_ATTRIBUTES) return false;
            if ((a & (ATTR_DIRECTORY | ATTR_REPARSE)) != 0) return false;
            return DeleteWithAttr(path, a);
        }

        public static long Measure(string dir)
        {
            bool ok;
            long total = 0;
            foreach (Entry e in List(dir.TrimEnd('\\'), out ok))
            {
                if ((e.Attr & ATTR_REPARSE) != 0) continue;
                if ((e.Attr & ATTR_DIRECTORY) != 0) total += Measure(dir.TrimEnd('\\') + "\\" + e.Name);
                else total += e.Size;
            }
            return total;
        }

        // Recycle Bin: each item = $I (info; deletion FILETIME at byte 16) + $R (data).
        // Only items deleted before cutoff are removed.
        public static Result CleanRecycleBin(string binRoot, long cutoff)
        {
            Result r = new Result();
            bool ok;
            foreach (Entry sid in List(binRoot.TrimEnd('\\'), out ok))
            {
                if ((sid.Attr & ATTR_DIRECTORY) == 0 || (sid.Attr & ATTR_REPARSE) != 0) continue;
                string sidDir = binRoot.TrimEnd('\\') + "\\" + sid.Name;
                bool ok2;
                List<Entry> items = List(sidDir, out ok2);
                if (!ok2)
                {
                    r.Failed++;
                    continue;
                }
                Dictionary<string, Entry> byName = new Dictionary<string, Entry>(StringComparer.OrdinalIgnoreCase);
                foreach (Entry e in items) byName[e.Name] = e;
                foreach (Entry info in items)
                {
                    if (!info.Name.StartsWith("$I", StringComparison.OrdinalIgnoreCase) || (info.Attr & ATTR_DIRECTORY) != 0) continue;
                    string infoPath = sidDir + "\\" + info.Name;
                    long deletedAt;
                    try
                    {
                        byte[] b = File.ReadAllBytes(infoPath);
                        if (b.Length < 24)
                        {
                            r.Skipped++;
                            continue;
                        }
                        deletedAt = BitConverter.ToInt64(b, 16);
                    }
                    catch
                    {
                        r.Failed++;
                        continue;
                    }
                    string rName = "$R" + info.Name.Substring(2);
                    Entry data;
                    bool hasData = byName.TryGetValue(rName, out data);
                    string rPath = sidDir + "\\" + rName;
                    long dataSize = 0;
                    if (hasData)
                    {
                        if ((data.Attr & ATTR_REPARSE) != 0)
                        {
                            r.Skipped++;
                            continue;
                        }
                        dataSize = (data.Attr & ATTR_DIRECTORY) != 0 ? Measure(rPath) : data.Size;
                    }
                    if (cutoff > 0 && deletedAt >= cutoff)
                    {
                        r.KeptBytes += dataSize;
                        r.Skipped++;
                        continue;
                    }
                    bool removed = true;
                    if (hasData)
                    {
                        if ((data.Attr & ATTR_DIRECTORY) != 0)
                        {
                            Result sub = DeleteTree(rPath);
                            r.Bytes += sub.Bytes;
                            r.Files += sub.Files;
                            r.Failed += sub.Failed;
                            removed = DryRun || GetFileAttributesW(Long(rPath)) == INVALID_ATTRIBUTES;
                        }
                        else if (DeleteWithAttr(rPath, data.Attr))
                        {
                            r.Bytes += data.Size;
                            r.Files++;
                        }
                        else
                        {
                            r.Failed++;
                            removed = false;
                        }
                    }
                    if (removed) DeleteWithAttr(infoPath, info.Attr);
                }
            }
            return r;
        }
    }
}
'@
if (-not ('CDriveClean.Cleaner' -as [type])) {
    try {
        Add-Type -TypeDefinition $cleanerSource -Language CSharp -ErrorAction Stop
    } catch {
        Write-Host ('[LỖI] Không biên dịch được bộ dọn dẹp: {0}' -f $_.Exception.Message) -ForegroundColor Red
        try { Stop-Transcript | Out-Null } catch { }
        return
    }
}
[CDriveClean.Cleaner]::DryRun = [bool]$ChiXem

# ----------------------------------------------------------------------------
# Hàm tiện ích
# ----------------------------------------------------------------------------
$profiles = @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
    ForEach-Object { $_.FullName.TrimEnd('\') })

function UP {
    param([string]$Rel)
    foreach ($p in $script:profiles) { $p + '\' + $Rel }
}

function Get-ExistingDirs {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        if (-not $p) { continue }
        if ($p -match '[\*\?]') {
            Get-Item -Path $p -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } | ForEach-Object { $_.FullName.TrimEnd('\') }
        } elseif (Test-Path -LiteralPath $p -PathType Container) {
            $p.TrimEnd('\')
        }
    }
}

function Clear-Dirs {
    param([string[]]$Paths, [long]$Cutoff = 0, [string]$Pattern = '*', [bool]$RemoveEmpty = $true)
    $total = New-Object CDriveClean.Result
    foreach ($p in @(Get-ExistingDirs $Paths)) {
        $total.Add([CDriveClean.Cleaner]::CleanDir($p, $Cutoff, $Pattern, $RemoveEmpty))
    }
    return $total
}

$script:procNames = @()
function Update-ProcList {
    $script:procNames = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName.ToLowerInvariant() } | Select-Object -Unique)
}
function Test-Running {
    param([string[]]$Names)
    foreach ($n in $Names) { if ($script:procNames -contains $n.ToLowerInvariant()) { return $true } }
    return $false
}

function Get-ChromiumCacheDirs {
    param([string]$UserData)
    $result = New-Object System.Collections.Generic.List[string]
    $profileDirs = @(Get-ChildItem -LiteralPath $UserData -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -eq 'Guest Profile' -or $_.Name -eq 'System Profile' })
    foreach ($pd in $profileDirs) {
        foreach ($sub in @('Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache',
                'Service Worker\CacheStorage', 'Service Worker\ScriptCache', 'Media Cache')) {
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

function Get-AppLabel {
    param([string]$Path)
    $map = [ordered]@{
        '\AppData\Local\Temp'                  = 'Tệp tạm (Temp)'
        '\Windows\Temp'                        = 'Tệp tạm của Windows'
        '\SoftwareDistribution'                = 'Windows Update'
        '\DeliveryOptimization'                = 'Delivery Optimization (Windows Update)'
        '\ZaloPC'                              = 'Zalo'
        '\ZaloData'                            = 'Zalo'
        '\CapCut'                              = 'CapCut'
        '\Google\Chrome'                       = 'Google Chrome'
        '\Microsoft\Edge'                      = 'Microsoft Edge'
        '\CocCoc'                              = 'Cốc Cốc'
        '\Docker'                              = 'Docker'
        '\CanonicalGroupLimited'               = 'WSL (Ubuntu)'
        '\AppData\Local\wsl'                   = 'WSL'
        '\Telegram Desktop'                    = 'Telegram'
        '\OneDrive'                            = 'OneDrive'
        '\Microsoft\Teams'                     = 'Microsoft Teams'
        '\MSTeams_'                            = 'Microsoft Teams'
        '\Adobe'                               = 'Adobe'
        '\Steam'                               = 'Steam'
        '\WER'                                 = 'Báo cáo lỗi Windows (WER)'
        '\CrashDumps'                          = 'Crash dump ứng dụng'
        '\LiveKernelReports'                   = 'Báo cáo lỗi driver (LiveKernelReports)'
        '\Windows Defender'                    = 'Windows Defender'
        '\Logs\CBS'                            = 'Nhật ký cập nhật Windows (CBS)'
        '\System32\config'                     = 'Registry hệ thống (bình thường)'
        '\winevt\Logs'                         = 'Nhật ký sự kiện Windows'
        '\$Recycle.Bin'                        = 'Thùng rác'
        '\Downloads'                           = 'Thư mục Downloads'
        '\Desktop'                             = 'Desktop'
        '\Documents'                           = 'Documents'
        '\Pictures'                            = 'Pictures'
        '\Videos'                              = 'Videos'
    }
    foreach ($k in $map.Keys) { if ($Path.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $map[$k] } }
    if ($Path -match '\\AppData\\(Local|Roaming|LocalLow)\\([^\\]+)') { return $Matches[2] }
    if ($Path -match '^C:\\Program Files[^\\]*\\([^\\]+)') { return $Matches[1] }
    return $Path.Substring($Path.LastIndexOf('\') + 1)
}

function Get-LatestScanDir {
    if (-not (Test-Path -LiteralPath $scanOut)) { return $null }
    return Get-ChildItem -LiteralPath $scanOut -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending | Select-Object -First 1
}

function Invoke-Scan {
    param([switch]$SkipDism)
    if (-not (Test-Path -LiteralPath $scanScript)) {
        Write-Info ('Không tìm thấy {0} - bỏ qua bước quét chi tiết.' -f $scanScript) 'Yellow'
        return $null
    }
    $prev = Get-LatestScanDir
    try {
        if ($SkipDism) { & $scanScript -OutputDir $scanOut -NoOpen -SkipDism } else { & $scanScript -OutputDir $scanOut -NoOpen }
    } catch {
        Write-Info ('Lỗi khi quét: {0}' -f $_.Exception.Message) 'Yellow'
    }
    $new = Get-LatestScanDir
    if ($new -and (-not $prev -or $new.Name -ne $prev.Name)) { return $new.FullName }
    return $null
}

function Import-ScanData {
    param([string]$Dir)
    $data = [ordered]@{ Cat = @(); Dirs = @(); DismRecommended = $null; Report = $null }
    if (-not $Dir) { return $data }
    try { $data.Cat = @(Import-Csv -LiteralPath (Join-Path $Dir 'PhanLoai.csv')) } catch { }
    try { $data.Dirs = @(Import-Csv -LiteralPath (Join-Path $Dir 'ThuMucLon.csv')) } catch { }
    $dismFile = Join-Path $Dir 'dism-AnalyzeComponentStore.txt'
    if (Test-Path -LiteralPath $dismFile) {
        $t = Get-Content -LiteralPath $dismFile -Raw -ErrorAction SilentlyContinue
        if ($t -match 'Cleanup Recommended\s*:\s*Yes') { $data.DismRecommended = $true }
        elseif ($t -match 'Cleanup Recommended\s*:\s*No') { $data.DismRecommended = $false }
    }
    $data.Report = Join-Path $Dir 'BaoCao-TomTat.txt'
    return $data
}

function Get-RootFileSize {
    param([string]$Name)
    try { return [double](Get-Item -LiteralPath ('C:\' + $Name) -Force -ErrorAction Stop).Length } catch { return [double]0 }
}

function Get-ShadowStorageC {
    try {
        $vol = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='C:'" -ErrorAction Stop
        foreach ($s in @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction Stop)) {
            if ($s.Volume.DeviceID -eq $vol.DeviceID) { return $s }
        }
    } catch { }
    return $null
}

function Test-PendingReboot {
    return (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

function Stop-ServiceWait {
    param([string]$Name, [int]$Seconds = 90)
    $svc = Get-Service -Name $Name -ErrorAction Stop
    if ($svc.Status -eq 'Stopped') { return }
    & sc.exe stop $Name | Out-Null
    $svc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, (New-TimeSpan -Seconds $Seconds))
}

$script:actions = New-Object System.Collections.Generic.List[object]
function Invoke-Don {
    param([string]$Ten, [scriptblock]$Viec)
    Write-Info ('-> {0} ...' -f $Ten) 'White'
    $f0 = Get-FreeBytes
    $status = 'Xong'; $note = ''; $r = New-Object CDriveClean.Result
    try {
        $out = @(& $Viec)
        $res = $null
        if ($out.Count -gt 0) { $res = $out[-1] }
        if ($res -is [hashtable]) {
            if ($res.ContainsKey('Status')) { $status = $res.Status }
            if ($res.ContainsKey('Note')) { $note = [string]$res.Note }
            if ($res.ContainsKey('R') -and $res.R) { $r = $res.R }
        }
    } catch {
        $status = 'Lỗi'
        $note = $_.Exception.Message
    }
    $f1 = Get-FreeBytes
    $credit = [double]$r.Bytes
    if ($credit -le 0 -and -not $ChiXem -and $status -eq 'Xong' -and ($f1 - $f0) -gt 1MB) { $credit = $f1 - $f0 }
    $r.Bytes = [long]$credit
    $script:actions.Add([pscustomobject]@{ Ten = $Ten; TrangThai = $status; Bytes = [double]$r.Bytes; Files = $r.Files; Failed = $r.Failed; FreeDelta = $f1 - $f0; Note = $note })
    if ($status -eq 'Xong') {
        $line = '   {0} {1} ({2:N0} file)' -f $(if ($ChiXem) { 'Sẽ xoá được' } else { 'Đã xoá' }), (Format-Size $r.Bytes), $r.Files
        if ($r.Failed -gt 0) { $line += (', {0:N0} mục đang được dùng nên giữ nguyên' -f $r.Failed) }
        Write-Info $line 'Green'
        if ($note) { Write-Info ('   ' + $note) 'DarkGray' }
    } else {
        Write-Info ('   {0}: {1}' -f $status, $note) 'Yellow'
    }
}

$findings = New-Object System.Collections.Generic.List[string]   # nguyên nhân / chẩn đoán
$todo = New-Object System.Collections.Generic.List[string]       # việc còn cần làm
$configured = New-Object System.Collections.Generic.List[string] # cấu hình đã thay đổi

$disk0 = Get-DiskC
$capacity = 0.0
if ($disk0) { $capacity = [double]$disk0.Size }
$freeBefore = Get-FreeBytes

Write-Host ''
Write-Host '#################################################################################' -ForegroundColor Green
Write-Host '#  TỰ ĐỘNG DỌN Ổ C AN TOÀN  -  không xoá file cá nhân, không đụng file hệ thống  #' -ForegroundColor Green
Write-Host '#################################################################################' -ForegroundColor Green
if ($ChiXem) { Write-Host '  CHẾ ĐỘ CHẠY THỬ: không xoá và không thay đổi gì.' -ForegroundColor Yellow }
Write-Info ('Ổ C lúc bắt đầu: còn trống {0} / {1}' -f (Format-Size $freeBefore), (Format-Size $capacity)) 'White'
Write-Info ('Nhật ký và báo cáo: {0}' -f $ThuMucBaoCao)
Write-Info 'Toàn bộ quy trình thường mất 10-40 phút. Có thể dùng máy bình thường trong lúc chạy.'

# ============================================================================
# BƯỚC 1 - QUÉT
# ============================================================================
Write-Buoc 'BƯỚC 1/6 - QUÉT TOÀN BỘ Ổ C'
$scanBeforeDir = Invoke-Scan
$before = Import-ScanData $scanBeforeDir
if ($scanBeforeDir) { Write-Info ('Báo cáo quét trước khi dọn: {0}' -f $before.Report) 'Green' }

# ============================================================================
# BƯỚC 2 - PHÂN TÍCH
# ============================================================================
Write-Buoc 'BƯỚC 2/6 - PHÂN TÍCH NGUYÊN NHÂN'
$pagefileBytes = Get-RootFileSize 'pagefile.sys'
$hiberfilBytes = Get-RootFileSize 'hiberfil.sys'
$shadow = Get-ShadowStorageC
$shadowUsed = 0.0
if ($shadow) { $shadowUsed = [double]$shadow.UsedSpace }
$pendingReboot = Test-PendingReboot

$causeList = New-Object System.Collections.Generic.List[object]
foreach ($c in $before.Cat) {
    if ($c.Level -eq 'C') { continue }
    if ([double]$c.Bytes -ge 500MB) { $causeList.Add([pscustomobject]@{ Ten = $c.Name; Bytes = [double]$c.Bytes; Muc = $c.Level; Note = $c.Note }) }
}
if ($pagefileBytes -ge 500MB) { $causeList.Add([pscustomobject]@{ Ten = 'pagefile.sys (bộ nhớ ảo)'; Bytes = $pagefileBytes; Muc = 'C'; Note = '' }) }
if ($hiberfilBytes -ge 500MB) { $causeList.Add([pscustomobject]@{ Ten = 'hiberfil.sys (ngủ đông / Fast Startup)'; Bytes = $hiberfilBytes; Muc = 'B'; Note = '' }) }
if ($shadowUsed -ge 500MB) { $causeList.Add([pscustomobject]@{ Ten = 'System Restore (điểm khôi phục)'; Bytes = $shadowUsed; Muc = 'B'; Note = '' }) }
$causes = @($causeList | Sort-Object Bytes -Descending)
Write-Info 'Những thứ chiếm nhiều dung lượng nhất (không tính phần hệ thống không được đụng vào):' 'White'
foreach ($c in ($causes | Select-Object -First 12)) {
    Write-Info ('{0,11}  [{1,-2}] {2}' -f (Format-Size $c.Bytes), $c.Muc, $c.Ten)
}

$normalChurn = '\\System32\\config|\\winevt\\|\\Windows Defender\\|\\Prefetch|\\SoftwareDistribution\\DataStore|\\catroot2'
$growth = @($before.Dirs | Where-Object { $_.PSObject.Properties['OwnRecentBytes'] -and [double]$_.OwnRecentBytes -ge 300MB -and $_.Path -notmatch $normalChurn } |
    Sort-Object { [double]$_.OwnRecentBytes } -Descending | Select-Object -First 6)
if ($growth.Count -gt 0) {
    Write-Info 'Nơi đang được ghi thêm nhiều dữ liệu nhất (7 ngày qua):' 'White'
    foreach ($g in $growth) {
        Write-Info ('{0,11}  {1}  ({2})' -f (Format-Size ([double]$g.OwnRecentBytes)), $g.Path, (Get-AppLabel $g.Path))
    }
}
if ($pendingReboot) { Write-Info 'Windows đang chờ khởi động lại để hoàn tất cập nhật.' 'Yellow' }

# Ghi lại thông tin crash TRƯỚC khi xoá dump (để tìm nguyên nhân)
$appDumps = @()
foreach ($d in @(Get-ExistingDirs (UP 'AppData\Local\CrashDumps'))) {
    $appDumps += @(Get-ChildItem -LiteralPath $d -Filter '*.dmp' -File -Force -ErrorAction SilentlyContinue)
}
$kernelReports = @()
if (Test-Path -LiteralPath 'C:\Windows\LiveKernelReports') {
    $kernelReports = @(Get-ChildItem -LiteralPath 'C:\Windows\LiveKernelReports' -Filter '*.dmp' -File -Recurse -Force -ErrorAction SilentlyContinue)
}
$minidumps = @()
if (Test-Path -LiteralPath 'C:\Windows\Minidump') {
    $minidumps = @(Get-ChildItem -LiteralPath 'C:\Windows\Minidump' -Filter '*.dmp' -File -Force -ErrorAction SilentlyContinue)
}

# ============================================================================
# BƯỚC 3 - DỌN DẸP AN TOÀN
# ============================================================================
Write-Buoc 'BƯỚC 3/6 - DỌN DẸP AN TOÀN'
$now = Get-Date
$cut1d = $now.AddDays(-1).ToFileTimeUtc()
$cut2d = $now.AddDays(-2).ToFileTimeUtc()
$cut7d = $now.AddDays(-7).ToFileTimeUtc()
$cutBin = 0
if ($GiuThungRacNgay -gt 0) { $cutBin = $now.AddDays(-$GiuThungRacNgay).ToFileTimeUtc() }
Update-ProcList

Invoke-Don 'Tệp tạm của người dùng (%TEMP%, cũ hơn 24 giờ)' {
    @{ R = (Clear-Dirs (UP 'AppData\Local\Temp') $cut1d) }
}

Invoke-Don 'Tệp tạm của Windows (cũ hơn 48 giờ)' {
    @{ R = (Clear-Dirs @('C:\Windows\Temp', 'C:\Windows\SystemTemp',
                'C:\Windows\System32\config\systemprofile\AppData\Local\Temp',
                'C:\Windows\ServiceProfiles\LocalService\AppData\Local\Temp',
                'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Temp') $cut2d) }
}

Invoke-Don 'Bộ nhớ đệm tải bản cập nhật (SoftwareDistribution\Download)' {
    if ($pendingReboot) { return @{ Status = 'Bỏ qua'; Note = 'Windows đang chờ khởi động lại để cài cập nhật - giữ nguyên để không ảnh hưởng việc cài đặt.' } }
    if (Test-Running @('TiWorker')) { return @{ Status = 'Bỏ qua'; Note = 'Windows đang cài cập nhật - để lần sau.' } }
    $dl = 'C:\Windows\SoftwareDistribution\Download'
    if ($ChiXem) { return @{ R = (Clear-Dirs @($dl) 0) } }
    $was = @{}
    foreach ($s in @('wuauserv', 'bits')) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc) { $was[$s] = [string]$svc.Status }
    }
    try {
        foreach ($s in @('wuauserv', 'bits')) { if ($was[$s] -ne 'Stopped') { Stop-ServiceWait $s 90 } }
        $r = Clear-Dirs @($dl) 0
    } finally {
        foreach ($s in @('bits', 'wuauserv')) { if ($was[$s] -eq 'Running') { Start-Service -Name $s -ErrorAction SilentlyContinue } }
    }
    @{ R = $r; Note = 'Windows sẽ tự tải lại khi cần.' }
}

Invoke-Don 'Bộ nhớ đệm Delivery Optimization' {
    $doDir = 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
    $b0 = [double]0
    if (Test-Path -LiteralPath $doDir) { $b0 = [CDriveClean.Cleaner]::Measure($doDir) }
    $r = New-Object CDriveClean.Result
    if ($ChiXem) { $r.Bytes = $b0; return @{ R = $r } }
    if (-not (Get-Command -Name 'Delete-DeliveryOptimizationCache' -ErrorAction SilentlyContinue)) {
        return @{ Status = 'Bỏ qua'; Note = 'Bản Windows này không có lệnh Delete-DeliveryOptimizationCache.' }
    }
    Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null
    $b1 = [double]0
    if (Test-Path -LiteralPath $doDir) { $b1 = [CDriveClean.Cleaner]::Measure($doDir) }
    $r.Bytes = [long][Math]::Max(0, $b0 - $b1)
    @{ R = $r }
}

Invoke-Don 'Báo cáo lỗi Windows (WER) và crash dump' {
    $r = New-Object CDriveClean.Result
    $r.Add((Clear-Dirs @('C:\ProgramData\Microsoft\Windows\WER\ReportArchive', 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue', 'C:\ProgramData\Microsoft\Windows\WER\Temp') 0))
    $r.Add((Clear-Dirs @(UP 'AppData\Local\Microsoft\Windows\WER\ReportArchive'; UP 'AppData\Local\Microsoft\Windows\WER\ReportQueue'; UP 'AppData\Local\Microsoft\Windows\WER\Temp') 0))
    $r.Add((Clear-Dirs (UP 'AppData\Local\CrashDumps') 0 '*.dmp' $false))
    $r.Add((Clear-Dirs @('C:\Windows\Minidump') 0 '*.dmp' $false))
    $r.Add((Clear-Dirs @('C:\Windows\LiveKernelReports') 0 '*.dmp' $false))
    $mem = 'C:\Windows\MEMORY.DMP'
    if (Test-Path -LiteralPath $mem) {
        $len = (Get-Item -LiteralPath $mem -Force).Length
        if ([CDriveClean.Cleaner]::DeleteOne($mem)) { $r.Bytes += $len; $r.Files++ } else { $r.Failed++ }
    }
    @{ R = $r; Note = 'Tên ứng dụng/driver bị lỗi đã được ghi lại để chẩn đoán (xem báo cáo cuối).' }
}

Invoke-Don ('Thùng rác (các mục đã xoá hơn {0} ngày)' -f $GiuThungRacNgay) {
    $r = [CDriveClean.Cleaner]::CleanRecycleBin('C:\$Recycle.Bin', $cutBin)
    $note = ''
    if ($r.KeptBytes -gt 0) { $note = 'Giữ lại {0} vừa xoá trong {1} ngày gần đây (phòng khi cần khôi phục).' -f (Format-Size $r.KeptBytes), $GiuThungRacNgay }
    @{ R = $r; Note = $note }
}

Update-ProcList
$browserDefs = @(
    @{ Name = 'Google Chrome'; Procs = @('chrome'); Rel = 'AppData\Local\Google\Chrome\User Data' },
    @{ Name = 'Microsoft Edge'; Procs = @('msedge'); Rel = 'AppData\Local\Microsoft\Edge\User Data' },
    @{ Name = 'Cốc Cốc'; Procs = @('browser', 'coccoc'); Rel = 'AppData\Local\CocCoc\Browser\User Data' },
    @{ Name = 'Brave'; Procs = @('brave'); Rel = 'AppData\Local\BraveSoftware\Brave-Browser\User Data' },
    @{ Name = 'Vivaldi'; Procs = @('vivaldi'); Rel = 'AppData\Local\Vivaldi\User Data' }
)
$cacheTargets = New-Object System.Collections.Generic.List[object]
foreach ($b in $browserDefs) {
    $dirs = @()
    foreach ($ud in @(Get-ExistingDirs (UP $b.Rel))) { $dirs += Get-ChromiumCacheDirs $ud }
    $cacheTargets.Add(@{ Name = $b.Name; Procs = $b.Procs; Dirs = $dirs })
}
$cacheTargets.Add(@{ Name = 'Firefox'; Procs = @('firefox'); Dirs = @(Get-ExistingDirs (UP 'AppData\Local\Mozilla\Firefox\Profiles\*\cache2')) })
$cacheTargets.Add(@{ Name = 'Opera'; Procs = @('opera'); Dirs = @(Get-ExistingDirs @(UP 'AppData\Local\Opera Software\*\Cache'; UP 'AppData\Local\Opera Software\*\Code Cache'; UP 'AppData\Local\Opera Software\*\Default\Cache')) })
$cacheTargets.Add(@{ Name = 'Discord'; Procs = @('discord'); Dirs = @(Get-ExistingDirs @(UP 'AppData\Roaming\discord\Cache'; UP 'AppData\Roaming\discord\Code Cache'; UP 'AppData\Roaming\discord\GPUCache')) })
$cacheTargets.Add(@{ Name = 'Slack'; Procs = @('slack'); Dirs = @(Get-ExistingDirs @(UP 'AppData\Roaming\Slack\Cache'; UP 'AppData\Roaming\Slack\Code Cache'; UP 'AppData\Roaming\Slack\GPUCache'; UP 'AppData\Roaming\Slack\Service Worker\CacheStorage')) })
$cacheTargets.Add(@{ Name = 'Microsoft Teams'; Procs = @('teams', 'ms-teams'); Dirs = @(Get-ExistingDirs @(UP 'AppData\Roaming\Microsoft\Teams\Cache'; UP 'AppData\Roaming\Microsoft\Teams\Code Cache'; UP 'AppData\Roaming\Microsoft\Teams\GPUCache'; UP 'AppData\Roaming\Microsoft\Teams\Service Worker\CacheStorage'; UP 'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Cache'; UP 'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Code Cache')) })
$cacheTargets.Add(@{ Name = 'Visual Studio Code'; Procs = @('code'); Dirs = @(Get-ExistingDirs @(UP 'AppData\Roaming\Code\Cache'; UP 'AppData\Roaming\Code\CachedData'; UP 'AppData\Roaming\Code\Code Cache'; UP 'AppData\Roaming\Code\GPUCache')) })

$script:openApps = New-Object System.Collections.Generic.List[string]
Invoke-Don 'Cache trình duyệt và ứng dụng (chỉ ứng dụng đang tắt)' {
    $r = New-Object CDriveClean.Result
    $skippedApps = @()
    foreach ($t in $cacheTargets) {
        if ($t.Dirs.Count -eq 0) { continue }
        if (Test-Running $t.Procs) {
            $skippedApps += $t.Name
            $script:openApps.Add($t.Name)
            continue
        }
        $r.Add((Clear-Dirs $t.Dirs 0))
    }
    $note = ''
    if ($skippedApps.Count -gt 0) { $note = 'Đang mở nên bỏ qua (an toàn): ' + ($skippedApps -join ', ') }
    @{ R = $r; Note = $note }
}

Invoke-Don 'Cache shader GPU (DirectX / NVIDIA / AMD)' {
    @{ R = (Clear-Dirs @(UP 'AppData\Local\D3DSCache'; UP 'AppData\Local\NVIDIA\DXCache'; UP 'AppData\Local\NVIDIA\GLCache';
                UP 'AppData\LocalLow\NVIDIA\PerDriverVersion\DXCache'; UP 'AppData\Local\AMD\DxCache'; UP 'AppData\Local\AMD\DxcCache'; UP 'AppData\Local\AMD\GLCache') 0) }
}

Invoke-Don 'Thumbnail cache và cache web cũ (INetCache)' {
    $r = New-Object CDriveClean.Result
    $r.Add((Clear-Dirs (UP 'AppData\Local\Microsoft\Windows\Explorer') 0 'thumbcache_*.db' $false))
    $r.Add((Clear-Dirs (UP 'AppData\Local\Microsoft\Windows\INetCache') $cut1d))
    @{ R = $r }
}

Invoke-Don 'Microsoft Store cache' {
    if (Test-Running @('WinStore.App')) { return @{ Status = 'Bỏ qua'; Note = 'Microsoft Store đang mở.' } }
    @{ R = (Clear-Dirs (UP 'AppData\Local\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalCache') 0) }
}

Invoke-Don 'Log cập nhật Windows cũ (CbsPersist hơn 7 ngày)' {
    @{ R = (Clear-Dirs @('C:\Windows\Logs\CBS') $cut7d 'CbsPersist_*' $false) }
}

Invoke-Don 'Dọn Component Store của Windows Update (DISM /StartComponentCleanup)' {
    if ($BoQuaDonDism) { return @{ Status = 'Bỏ qua'; Note = 'Đã tắt bằng tham số -BoQuaDonDism.' } }
    if ($ChiXem) { return @{ Status = 'Bỏ qua'; Note = 'Chạy thử - không chạy DISM.' } }
    if ($pendingReboot) { return @{ Status = 'Bỏ qua'; Note = 'Windows đang chờ khởi động lại; khởi động lại máy rồi chạy lại công cụ để dọn phần này.' } }
    if ($before.DismRecommended -eq $false) { return @{ Status = 'Bỏ qua'; Note = 'DISM báo không cần dọn (Component Store Cleanup Recommended: No).' } }
    $out = Join-Path $runOut 'dism-StartComponentCleanup.txt'
    $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\Dism.exe') -ArgumentList '/Online /Cleanup-Image /StartComponentCleanup /English' `
        -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError ($out + '.err')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited) {
        Write-Progress -Activity 'DISM đang dọn Component Store (5-30 phút) - KHÔNG tắt máy' -Status ('Đã chạy {0:hh\:mm\:ss}' -f $sw.Elapsed)
        if ($sw.Elapsed.TotalMinutes -ge 90) { break }
        Start-Sleep -Seconds 5
    }
    Write-Progress -Activity 'DISM' -Completed
    if (-not $p.HasExited) { return @{ Status = 'Lỗi'; Note = 'DISM chạy hơn 90 phút và vẫn đang chạy nền - KHÔNG tắt máy cho tới khi xong.' } }
    $txt = Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue
    if ($txt -match 'completed successfully') { return @{ Note = 'DISM hoàn tất (vẫn gỡ được bản cập nhật vì không dùng /ResetBase).' } }
    $tail = (($txt -split '[\r\n]+') | Where-Object { $_.Trim() -and $_ -notmatch '^\s*\[' } | Select-Object -Last 2) -join ' '
    return @{ Status = 'Lỗi'; Note = ('DISM không báo thành công: ' + $tail) }
}

# ============================================================================
# BƯỚC 4 - XỬ LÝ NGUYÊN NHÂN
# ============================================================================
Write-Buoc 'BƯỚC 4/6 - CHẨN ĐOÁN NGUYÊN NHÂN GÂY ĐẦY'

foreach ($g in ($appDumps | Group-Object { if ($_.Name -match '^(.+?\.exe)\.') { $Matches[1] } else { $_.BaseName } } | Sort-Object Count -Descending)) {
    if ($g.Count -ge 2) {
        $findings.Add(('Ứng dụng {0} bị crash {1} lần (đã xoá dump {2}) - nên cập nhật hoặc cài lại ứng dụng này.' -f $g.Name, $g.Count, (Format-Size (($g.Group | Measure-Object Length -Sum).Sum))))
    }
}
if ($kernelReports.Count -gt 0) {
    $kSize = ($kernelReports | Measure-Object Length -Sum).Sum
    $kinds = @($kernelReports | ForEach-Object { $_.Directory.Name } | Select-Object -Unique) -join ', '
    $msg = 'Windows ghi {0} báo cáo lỗi driver ({1}) trong LiveKernelReports, tổng {2} (đã xoá).' -f $kernelReports.Count, $kinds, (Format-Size $kSize)
    if ($kinds -match 'WATCHDOG') { $msg += ' WATCHDOG thường do driver card màn hình bị treo/khởi động lại - nên cập nhật driver GPU từ trang của NVIDIA/AMD/Intel.' }
    $findings.Add($msg)
}
$recentMini = @($minidumps | Where-Object { $_.LastWriteTime -ge (Get-Date).AddDays(-30) })
if ($recentMini.Count -gt 0) {
    $findings.Add(('Máy bị màn hình xanh (BSOD) {0} lần trong 30 ngày qua - nên kiểm tra driver/phần cứng.' -f $recentMini.Count))
}
$werLocal = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
if ($werLocal) {
    $todo.Add('WER LocalDumps đang bật: mỗi lần ứng dụng crash sẽ ghi dump ra ổ C. Nếu bạn không phải lập trình viên cần dump, có thể xoá khoá HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps (công cụ không tự sửa registry).')
}
foreach ($g in $growth) {
    $label = Get-AppLabel $g.Path
    $findings.Add(('{0} ghi thêm {1} trong 7 ngày qua tại {2}.' -f $label, (Format-Size ([double]$g.OwnRecentBytes)), $g.Path))
}
foreach ($f in $findings) { Write-Info ('- ' + $f) }
if ($findings.Count -eq 0) { Write-Info 'Không phát hiện ứng dụng nào ghi dữ liệu bất thường.' }

# ============================================================================
# BƯỚC 5 - KIỂM TRA LẠI
# ============================================================================
Write-Buoc 'BƯỚC 5/6 - QUÉT LẠI VÀ KIỂM TRA WINDOWS'
$freeAfterClean = Get-FreeBytes
$scanAfterDir = Invoke-Scan -SkipDism
$after = Import-ScanData $scanAfterDir
if ($scanAfterDir) { Write-Info ('Báo cáo quét sau khi dọn (mục [17] so sánh trước/sau): {0}' -f $after.Report) 'Green' }

$health = New-Object System.Collections.Generic.List[string]
$healthOk = $true
$chk = ''
try { $chk = (& (Join-Path $env:WINDIR 'System32\Dism.exe') /Online /Cleanup-Image /CheckHealth /English 2>&1 | Out-String) } catch { }
if ($chk -match 'No component store corruption detected') { $health.Add('Kho thành phần Windows: không có lỗi (DISM /CheckHealth).') }
elseif ($chk -match 'repairable') { $healthOk = $false; $health.Add('DISM báo kho thành phần CÓ LỖI sửa được - nên chạy: DISM /Online /Cleanup-Image /RestoreHealth rồi sfc /scannow.') }
else { $health.Add('Không đọc được kết quả DISM /CheckHealth.') }
foreach ($s in @('wuauserv', 'bits', 'cryptsvc', 'dosvc')) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if ($svc -and [string]$svc.StartType -eq 'Disabled') { $healthOk = $false; $health.Add(('Dịch vụ {0} đang bị Disabled.' -f $s)) }
}
$health.Add('Dịch vụ Windows Update / BITS / Delivery Optimization: giữ nguyên chế độ khởi động.')
if (Get-Process -Name explorer -ErrorAction SilentlyContinue) { $health.Add('Explorer (giao diện Windows) đang chạy bình thường.') }
$diskErr = @()
try {
    $diskErr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $startTime } -ErrorAction Stop |
        Where-Object { @('disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'volmgr', 'stornvme', 'storahci') -contains $_.ProviderName })
} catch { }
if ($diskErr.Count -gt 0) { $healthOk = $false; $health.Add(('Có {0} lỗi ổ đĩa/NTFS trong lúc chạy - nên chạy chkdsk C: /scan.' -f $diskErr.Count)) }
else { $health.Add('Không có lỗi ổ đĩa/NTFS mới trong lúc chạy.') }
$pendingAfter = Test-PendingReboot
if ($pendingAfter) { $health.Add('Windows đang chờ khởi động lại (do cập nhật) - nên khởi động lại máy.') }
foreach ($h in $health) { Write-Info ('- ' + $h) }

# ============================================================================
# BƯỚC 6 - CHỐNG ĐẦY LẠI
# ============================================================================
Write-Buoc 'BƯỚC 6/6 - CẤU HÌNH ĐỂ Ổ C KHÔNG ĐẦY LẠI'

# 6a. Storage Sense
$ssPolicy = $null
try { $ssPolicy = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' -Name 'AllowStorageSenseGlobal' -ErrorAction Stop).AllowStorageSenseGlobal } catch { }
if ($ChiXem) {
    Write-Info 'Chạy thử: không đổi cấu hình Storage Sense.'
} elseif ($ssPolicy -eq 0) {
    $todo.Add('Storage Sense bị chính sách (Group Policy) tắt - không bật được.')
} else {
    try {
        $ssKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
        if (-not (Test-Path -LiteralPath $ssKey)) { New-Item -Path $ssKey -Force | Out-Null }
        $vals = [ordered]@{ '01' = 1; '04' = 1; '08' = 1; '256' = 30; '32' = 0; '512' = 0; '2048' = 7 }
        foreach ($k in $vals.Keys) { New-ItemProperty -LiteralPath $ssKey -Name $k -Value $vals[$k] -PropertyType DWord -Force | Out-Null }
        $configured.Add('Bật Storage Sense: chạy hằng tuần, xoá tệp tạm, dọn thùng rác sau 30 ngày, KHÔNG BAO GIỜ đụng Downloads')
        Write-Info 'Đã bật Storage Sense (hằng tuần; tệp tạm; thùng rác > 30 ngày; không đụng Downloads).' 'Green'
    } catch { $todo.Add('Không bật được Storage Sense: ' + $_.Exception.Message) }
}

# 6b. Giới hạn System Restore hợp lý (giữ điểm khôi phục mới nhất)
$target = [Math]::Min([Math]::Max(0.08 * $capacity, 5GB), 15GB)
$shadow = Get-ShadowStorageC
if (-not $shadow) {
    Write-Info 'System Protection (điểm khôi phục) đang tắt cho ổ C - giữ nguyên.'
    $todo.Add('System Protection đang tắt: nên bật cho ổ C ở mức khoảng 5-8% để có điểm khôi phục khi Windows gặp sự cố (System Properties > System Protection).')
} else {
    $max = [double]$shadow.MaxSpace; $used = [double]$shadow.UsedSpace
    if ($max -le 1.25 * $target) {
        Write-Info ('System Restore: giới hạn hiện tại {0} đã hợp lý (đang dùng {1}) - giữ nguyên.' -f (Format-Size $max), (Format-Size $used))
    } elseif ($ChiXem) {
        Write-Info ('Chạy thử: sẽ giới hạn System Restore từ {0} xuống {1}.' -f $(if ($max -ge 1E18) { 'KHÔNG GIỚI HẠN' } else { Format-Size $max }), (Format-Size $target))
    } else {
        try {
            if ($used -gt $target) {
                Write-Info 'Tạo điểm khôi phục mới trước khi thu nhỏ (để luôn còn 1 điểm khôi phục gần nhất)...'
                try { Checkpoint-Computer -Description 'Truoc khi gioi han System Restore' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningAction SilentlyContinue } catch { }
            }
            $shadow = Get-ShadowStorageC
            Set-CimInstance -InputObject $shadow -Property @{ MaxSpace = [uint64]$target } -ErrorAction Stop
            $oldTxt = Format-Size $max
            if ($max -ge 1E18) { $oldTxt = 'KHÔNG GIỚI HẠN' }
            $configured.Add(('Giới hạn System Restore: {0} -> {1} (giữ điểm khôi phục mới nhất)' -f $oldTxt, (Format-Size $target)))
            Write-Info ('Đã giới hạn System Restore: {0} -> {1}.' -f $oldTxt, (Format-Size $target)) 'Green'
        } catch {
            $todo.Add(('Không đổi được giới hạn System Restore ({0}). Có thể chỉnh tay: System Properties > System Protection > Configure > Max Usage khoảng 8%.' -f $_.Exception.Message))
        }
    }
}

# 6c. Cảnh báo khi ổ C sắp đầy (chạy hằng ngày lúc 9:00 và khi đăng nhập, quyền người dùng thường)
$alertDir = Join-Path $env:LOCALAPPDATA 'CanhBaoOC'
$alertScript = Join-Path $alertDir 'CanhBao-O-C.ps1'
$alertSource = @'
param([switch]$ThuNghiem, [int]$NguongGB = 15, [int]$NguongPhanTram = 10)
$ErrorActionPreference = 'SilentlyContinue'
$d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
if (-not $d) { return }
$inv = [Globalization.CultureInfo]::InvariantCulture
$freeGB = [math]::Round([double]$d.FreeSpace / 1GB, 1)
$pct = [math]::Round(100 * [double]$d.FreeSpace / [double]$d.Size, 1)
$log = Join-Path $PSScriptRoot 'LichSu-O-C.csv'
Add-Content -LiteralPath $log -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm', $inv) + ',' + $freeGB.ToString($inv) + ',' + $pct.ToString($inv))
$trend = ''
try {
    $old = Get-Content -LiteralPath $log | Select-Object -Last 100 | ForEach-Object {
        $p = $_.Split(',')
        [pscustomobject]@{ T = [datetime]::ParseExact($p[0], 'yyyy-MM-dd HH:mm', $inv); F = [double]::Parse($p[1], $inv) }
    } | Where-Object { $_.T -le (Get-Date).AddDays(-7) } | Select-Object -Last 1
    if ($old -and ($old.F - $freeGB) -ge 3) { $trend = ' Đã giảm ' + [math]::Round($old.F - $freeGB, 1) + ' GB trong 7 ngày.' }
} catch { }
if ($ThuNghiem -or $freeGB -lt $NguongGB -or $pct -lt $NguongPhanTram) {
    $title = 'Ổ C sắp đầy'
    $msg = 'Ổ C chỉ còn ' + $freeGB + ' GB trống (' + $pct + '%).' + $trend + ' Hãy chạy lại công cụ dọn ổ C.'
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>' + [Security.SecurityElement]::Escape($title) + '</text><text>' + [Security.SecurityElement]::Escape($msg) + '</text></binding></visual></toast>')
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show((New-Object Windows.UI.Notifications.ToastNotification $xml))
    } catch {
        (New-Object -ComObject WScript.Shell).Popup($msg, 60, $title, 48) | Out-Null
    }
}
'@
if ($ChiXem) {
    Write-Info 'Chạy thử: không cài cảnh báo.'
} else {
    try {
        New-Item -ItemType Directory -Path $alertDir -Force | Out-Null
        [IO.File]::WriteAllText($alertScript, $alertSource, (New-Object System.Text.UTF8Encoding($true)))
        $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $alertScript)
        $trDaily = New-ScheduledTaskTrigger -Daily -At '09:00'
        $trLogon = New-ScheduledTaskTrigger -AtLogOn -User $userId
        $trLogon.Delay = 'PT3M'
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName 'Canh bao o C sap day' -Action $action -Trigger @($trDaily, $trLogon) -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        $configured.Add('Cài cảnh báo: mỗi ngày 9:00 và khi đăng nhập, báo nếu ổ C còn dưới 15 GB hoặc dưới 10% (task "Canh bao o C sap day")')
        Write-Info 'Đã cài cảnh báo ổ C sắp đầy (hằng ngày + khi đăng nhập).' 'Green'
    } catch { $todo.Add('Không cài được cảnh báo ổ C: ' + $_.Exception.Message) }
}

# 6d. Đề xuất (không tự làm) cho những thứ có rủi ro
$ramBytes = 0.0
try { $ramBytes = [double](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory } catch { }
$hasBattery = $false
try { $hasBattery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop).Count -gt 0 } catch { }
if ($hiberfilBytes -ge 1GB) {
    if ($hasBattery) {
        $todo.Add(('hiberfil.sys {0}: GIỮ NGUYÊN vì máy là laptop (Windows dùng ngủ đông khi pin cạn để không mất dữ liệu).' -f (Format-Size $hiberfilBytes)))
    } else {
        $todo.Add(('hiberfil.sys {0}: nếu không dùng chế độ Hibernate, chạy "powercfg /h /type reduced" (vẫn giữ Fast Startup) để lấy lại khoảng {1}.' -f (Format-Size $hiberfilBytes), (Format-Size ($hiberfilBytes / 2))))
    }
}
if ($pagefileBytes -ge 1GB) {
    $todo.Add(('pagefile.sys {0} (RAM {1}): giữ nguyên chế độ Windows tự quản lý - xoá/giảm có thể làm máy treo khi thiếu RAM.' -f (Format-Size $pagefileBytes), (Format-Size $ramBytes)))
}
# Những thứ lớn CÒN LẠI sau khi dọn mà công cụ không tự xoá (mức B / dữ liệu của bạn) - số liệu từ lần quét lại
$remainCat = $after.Cat
if (@($remainCat).Count -eq 0) { $remainCat = $before.Cat }
foreach ($c in $remainCat) {
    if ([double]$c.Bytes -lt 1GB -or $c.Cat -eq 'Du lieu ca nhan') { continue }
    if ($c.Level -eq 'B' -or $c.Level -eq 'CN') {
        $todo.Add(('{0} - {1}: {2}' -f $c.Name, (Format-Size ([double]$c.Bytes)), $c.Note))
    }
}
# Đề xuất chuyển dữ liệu cá nhân nếu có ổ khác đủ chỗ
$personal = [double]0
foreach ($c in $remainCat) { if ($c.Cat -eq 'Du lieu ca nhan') { $personal += [double]$c.Bytes } }
$otherDisks = @()
try { $otherDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | Where-Object { $_.DeviceID -ne 'C:' } | Sort-Object FreeSpace -Descending) } catch { }
if ($personal -ge 5GB -and $otherDisks.Count -gt 0 -and [double]$otherDisks[0].FreeSpace -gt $personal + 10GB) {
    $todo.Add(('Dữ liệu cá nhân (Desktop/Documents/Downloads/Pictures/Videos/Music) đang chiếm {0} trên ổ C; ổ {1} còn trống {2}. Nên chuyển: chuột phải thư mục > Properties > Location > Move... sang {1}\ (Windows tự chuyển, không mất dữ liệu).' -f (Format-Size $personal), $otherDisks[0].DeviceID, (Format-Size $otherDisks[0].FreeSpace)))
}
if ($script:openApps.Count -gt 0) {
    $todo.Add(('Cache của {0} chưa dọn vì ứng dụng đang mở - lần sau đóng chúng trước khi chạy để dọn thêm.' -f (($script:openApps | Select-Object -Unique) -join ', ')))
}
if ($pendingReboot -or $pendingAfter) { $todo.Add('Khởi động lại máy để Windows hoàn tất cập nhật (sau đó có thể chạy lại công cụ để dọn thêm phần Windows Update).') }
foreach ($a in $script:actions) { if ($a.TrangThai -eq 'Lỗi') { $todo.Add(('{0}: {1}' -f $a.Ten, $a.Note)) } }

# ============================================================================
# KẾT QUẢ
# ============================================================================
$freeAfter = Get-FreeBytes
$freed = $freeAfter - $freeBefore
$deletedTotal = ($script:actions | Measure-Object Bytes -Sum).Sum
if (-not $deletedTotal) { $deletedTotal = 0 }

function Format-Free {
    param([double]$Free)
    if ($capacity -gt 0) { return ('{0} trống ({1:N1}%)' -f (Format-Size $Free), (100.0 * $Free / $capacity)) }
    return ('{0} trống' -f (Format-Size $Free))
}

$mainCauses = @($causes | Select-Object -First 4 | ForEach-Object { '{0} ({1})' -f $_.Ten, (Format-Size $_.Bytes) })
$causeText = ($mainCauses -join '; ')
if ($growth.Count -gt 0) {
    $causeText += ('. Đang phình to nhanh nhất 7 ngày qua: {0} (+{1})' -f (Get-AppLabel $growth[0].Path), (Format-Size ([double]$growth[0].OwnRecentBytes)))
}
if (-not $causeText) { $causeText = '(không có dữ liệu quét)' }

$doneParts = @($script:actions | Where-Object { $_.TrangThai -eq 'Xong' -and $_.Bytes -ge 1MB } | Sort-Object Bytes -Descending | ForEach-Object { '{0}: {1}' -f $_.Ten, (Format-Size $_.Bytes) })
$doneText = (@($doneParts) + @($configured)) -join '; '
if (-not $doneText) { $doneText = '(không có gì cần dọn)' }
$todoText = ($todo | Select-Object -First 8) -join ' | '
if (-not $todoText) { $todoText = 'Không có.' }

$freedLabel = 'Đã giải phóng'
if ($ChiXem) { $freedLabel = 'Có thể giải phóng (chạy thử)'; $freed = $deletedTotal }

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('KẾT QUẢ DỌN Ổ C - ' + (Get-Date).ToString('yyyy-MM-dd HH:mm'))
$summary.Add('')
$summary.Add(('1. Ổ C trước: {0}' -f (Format-Free $freeBefore)))
$summary.Add(('2. Ổ C sau: {0}' -f (Format-Free $freeAfter)))
$summary.Add(('3. {0}: {1}  (tổng dung lượng file đã xoá: {2})' -f $freedLabel, (Format-Size $freed), (Format-Size $deletedTotal)))
$summary.Add(('4. Nguyên nhân chính khiến ổ C đầy: {0}' -f $causeText))
$summary.Add(('5. Đã xử lý: {0}' -f $doneText))
$summary.Add(('6. Còn vấn đề cần xử lý thêm: {0}' -f $todoText))

$details = New-Object System.Collections.Generic.List[string]
$details.Add('')
$details.Add(('=' * 90))
$details.Add('CHI TIẾT')
$details.Add(('=' * 90))
$details.Add('Các bước dọn dẹp:')
foreach ($a in $script:actions) {
    $details.Add(('  [{0}] {1}: {2} ({3:N0} file; dung lượng trống thay đổi {4}){5}' -f $a.TrangThai, $a.Ten, (Format-Size $a.Bytes), $a.Files, (Format-Size $a.FreeDelta), $(if ($a.Note) { ' - ' + $a.Note } else { '' })))
}
$details.Add('')
$details.Add('Những thứ chiếm nhiều dung lượng nhất (trước khi dọn):')
foreach ($c in ($causes | Select-Object -First 15)) { $details.Add(('  {0,11}  [{1,-2}] {2}' -f (Format-Size $c.Bytes), $c.Muc, $c.Ten)) }
$details.Add('')
$details.Add('Chẩn đoán nguyên nhân:')
if ($findings.Count -eq 0) { $details.Add('  Không phát hiện ứng dụng nào ghi dữ liệu bất thường.') }
foreach ($f in $findings) { $details.Add('  - ' + $f) }
$details.Add('')
$details.Add('Thư mục lớn còn lại sau khi dọn (không trùng lặp):')
foreach ($d in (@($after.Dirs) | Sort-Object { [double]$_.OwnBytes } -Descending | Select-Object -First 12)) {
    $details.Add(('  {0,11}  {1}  ({2})' -f (Format-Size ([double]$d.OwnBytes)), $(if ($d.Path -eq 'C:') { 'C:\ (file ở gốc ổ)' } else { $d.Path }), (Get-AppLabel $d.Path)))
}
$details.Add('')
$details.Add('Kiểm tra Windows sau khi dọn:')
foreach ($h in $health) { $details.Add('  - ' + $h) }
$details.Add('')
$details.Add('Việc còn lại / đề xuất (công cụ KHÔNG tự làm vì có rủi ro hoặc là dữ liệu của bạn):')
if ($todo.Count -eq 0) { $details.Add('  Không có.') }
foreach ($t in $todo) { $details.Add('  - ' + $t) }
$details.Add('')
$details.Add('KHÔNG đụng vào: System32, WinSxS (chỉ dọn qua DISM), registry (ngoài Storage Sense), driver, file cá nhân,')
$details.Add('toàn bộ AppData, pagefile.sys, hiberfil.sys, Windows.old, Docker/WSL, dữ liệu Zalo/Telegram/CapCut.')
$details.Add('')
if ($before.Report) { $details.Add('Báo cáo quét trước khi dọn: ' + $before.Report) }
if ($after.Report) { $details.Add('Báo cáo quét sau khi dọn : ' + $after.Report) }
$details.Add('Nhật ký đầy đủ: ' + (Join-Path $runOut 'NhatKy.txt'))

$resultFile = Join-Path $runOut 'KetQua.txt'
[IO.File]::WriteAllLines($resultFile, [string[]](@($summary) + @($details)), (New-Object System.Text.UTF8Encoding($true)))

Write-Host ''
Write-Host ('#' * 90) -ForegroundColor Green
foreach ($l in $summary) { Write-Host $l -ForegroundColor White }
Write-Host ('#' * 90) -ForegroundColor Green
Write-Host ('Báo cáo chi tiết: {0}' -f $resultFile) -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch { }
if (-not $KhongMoNotepad -and [Environment]::UserInteractive) {
    try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $resultFile) } catch { }
}
