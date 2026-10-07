@echo off
rem ChayTuDong.cmd - tu dong: quet o C -> don an toan -> quet lai -> cau hinh chong day lai.
rem Script tu xin quyen Administrator (bam "Yes" o cua so UAC).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0TuDongDonO-C.ps1"
