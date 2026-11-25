@echo off
set "P=%~dp0index.html"
set "P=%P:\=/%"
start "" chrome --app="file:///%P%"
start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "%~dp0hotkey.ps1"
