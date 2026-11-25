@echo off
set "P=%~dp0index.html"
set "P=%P:\=/%"
set /a PORT=20000+%RANDOM%
for /f %%t in ('powershell -NoProfile -Command "[guid]::NewGuid().ToString('N')"') do set "T=%%t"
start "" chrome --app="file:///%P%#port=%PORT%&t=%T%"
start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0hotkey.ps1"
start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0audio.ps1" -Port %PORT% -Token %T%