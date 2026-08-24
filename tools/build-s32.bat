@echo off
setlocal EnableExtensions

if /I "%S32_BUILD_LOCK_HELD%"=="1" if defined S32_BUILD_LOCK_TOKEN goto :locked
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0invoke-build-locked.ps1" -BuildScript "%~f0"
set "RESULT=%ERRORLEVEL%"
endlocal & exit /b %RESULT%

:locked
set "S32_PROJECT=s32"
set "S32_REVISION=s32"
set "S32_RELEASE_NAME=s32"
set "S32_FIT_SEED=2"
call "%~dp0build-incremental.bat"
set "RESULT=%ERRORLEVEL%"
endlocal & exit /b %RESULT%
