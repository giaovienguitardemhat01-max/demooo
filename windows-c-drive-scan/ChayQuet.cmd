@echo off
rem ==================================================================
rem  ChayQuet.cmd - chay Scan-CDrive.ps1 (CHI DOC, khong xoa gi)
rem  Tu xin quyen Administrator: cua so UAC se hien ra, bam "Yes".
rem ==================================================================
setlocal
fltmc >nul 2>&1
if errorlevel 1 (
    echo Can quyen Administrator de quet day du. Hay bam "Yes" o cua so UAC...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    if errorlevel 1 (
        echo Khong lay duoc quyen Administrator - chua quet gi.
        pause
    )
    exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scan-CDrive.ps1" %*
echo.
echo Xong. Bao cao nam trong thu muc "BaoCao" canh file nay.
pause
