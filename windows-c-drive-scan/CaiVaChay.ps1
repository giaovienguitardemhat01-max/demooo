# Tai bo cong cu don o C (Scan-CDrive.ps1 + TuDongDonO-C.ps1) ve may roi chay voi quyen Administrator.
# Lenh duy nhat (dan vao Win+R hoac PowerShell):
#   powershell -ep bypass -c "[Net.ServicePointManager]::SecurityProtocol=3072;iex(irm https://raw.githubusercontent.com/giaovienguitardemhat01-max/demooo/claude/serene-newton-rsaq74/windows-c-drive-scan/CaiVaChay.ps1)"
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $base = 'https://raw.githubusercontent.com/giaovienguitardemhat01-max/demooo/claude/serene-newton-rsaq74/windows-c-drive-scan'
    $dir = Join-Path $env:LOCALAPPDATA 'DonDepOC'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($f in @('Scan-CDrive.ps1', 'TuDongDonO-C.ps1')) {
        Write-Host ('Dang tai ' + $f + ' ...')
        Invoke-WebRequest -Uri ($base + '/' + $f) -OutFile (Join-Path $dir $f) -UseBasicParsing
    }
    $main = Join-Path $dir 'TuDongDonO-C.ps1'
    Write-Host 'Dang mo cua so Administrator - hay bam "Yes" o hop thoai UAC...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"' + $main + '"'))
} catch {
    Write-Host ('LOI: ' + $_.Exception.Message) -ForegroundColor Red
    Read-Host 'Nhan Enter de dong'
}
