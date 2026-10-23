@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.ps1'))) %*"
endlocal
