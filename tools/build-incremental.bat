@echo off
setlocal EnableExtensions

REM The caller must own the repository mutex. Preserve every Quartus database
REM so SMART_RECOMPILE can reuse unchanged analysis, placement, and routing.
if /I not "%S32_BUILD_LOCK_HELD%"=="1" goto :lock_missing
if not defined S32_BUILD_LOCK_TOKEN goto :lock_missing

cd /d "%~dp0.."
if not "%ERRORLEVEL%"=="0" goto :err
if not defined S32_PROJECT set "S32_PROJECT=s32"
if not defined S32_REVISION set "S32_REVISION=s32"
if not defined S32_RELEASE_NAME set "S32_RELEASE_NAME=s32"
if not defined S32_FIT_SEED set "S32_FIT_SEED=2"
if not defined QUARTUS_ROOT goto :quartus_root_missing
set "QBIN=%QUARTUS_ROOT%\quartus\bin64"

echo [0/4] Validating toolchain, active revision, resources, and exclusivity...
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-preflight.ps1 -ProjectRoot "%CD%" -QuartusRoot "%QUARTUS_ROOT%" -Project "%S32_PROJECT%" -Revision "%S32_REVISION%" -ReleaseName "%S32_RELEASE_NAME%" -FitSeeds "%S32_FIT_SEED%" -MapRetries "1" -FitRetries "1" -ResumeFit "1"
if not "%ERRORLEVEL%"=="0" goto :err

echo [1/4] Smart Recompile flow compile; preserving db, incremental_db, and output caches...
"%QBIN%\quartus_sh.exe" --flow compile "%S32_PROJECT%" -c "%S32_REVISION%"
if not "%ERRORLEVEL%"=="0" goto :err

echo [2/4] Recording the current map input fingerprint...
powershell -NoProfile -ExecutionPolicy Bypass -File tools\report-quartus.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -QuartusRoot "%QUARTUS_ROOT%" -WriteMapManifest -RequireMapCurrent
if not "%ERRORLEVEL%"=="0" goto :err

echo [3/5] Qualifying fit and multicorner timing...
powershell -NoProfile -ExecutionPolicy Bypass -File tools\report-quartus.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -QuartusRoot "%QUARTUS_ROOT%" -ExpectedSeed %S32_FIT_SEED% -RequireTiming
if not "%ERRORLEVEL%"=="0" goto :err

REM Full-flow compilation may run assembler before TimeQuest. Reassemble only
REM after timing qualification so the RBF is provably newer than the STA result.
echo [4/5] Assembling the timing-qualified RBF...
"%QBIN%\quartus_asm.exe" --read_settings_files=on --write_settings_files=off "%S32_PROJECT%" -c "%S32_REVISION%"
if not "%ERRORLEVEL%"=="0" goto :err

powershell -NoProfile -ExecutionPolicy Bypass -File tools\report-quartus.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -QuartusRoot "%QUARTUS_ROOT%" -ExpectedSeed %S32_FIT_SEED% -RequireReady
if not "%ERRORLEVEL%"=="0" goto :err

echo [5/5] Staging the hash-verified release...
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-stage-release.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -ReleaseName "%S32_RELEASE_NAME%"
if not "%ERRORLEVEL%"=="0" goto :err

echo DONE: releases\%S32_RELEASE_NAME%.rbf
endlocal & exit /b 0

:lock_missing
echo ERROR: build-incremental.bat must run under invoke-build-locked.ps1.
endlocal & exit /b 1

:quartus_root_missing
echo ERROR: QUARTUS_ROOT is not set.
endlocal & exit /b 1

:err
echo ERROR: incremental Quartus build failed.
endlocal & exit /b 1
