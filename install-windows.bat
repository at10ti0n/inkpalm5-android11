@echo off
REM Windows: double-click to run the installer. Needs Python 3 (python.org, tick "Add to PATH").
cd /d "%~dp0"
where py >nul 2>nul && (py -3 install\inkpalm.py %*) || (python install\inkpalm.py %*)
pause
