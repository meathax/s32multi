@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM The wrapper owns the named mutex and supplies an unguessable per-run token.
if /I "%S32_BUILD_LOCK_HELD%"=="1" if defined S32_BUILD_LOCK_TOKEN goto :build_lock_acquired
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0invoke-build-locked.ps1" -BuildScript "%~f0"
set "LOCK_RESULT=%ERRORLEVEL%"
endlocal & exit /b %LOCK_RESULT%

:build_lock_acquired
REM ===========================================================================
REM Build a Sega System 32 MiSTer RBF with a verified clean/map/fit/STA/ASM
REM chain. QUARTUS_ROOT must point at the pinned Quartus Lite installation.
REM ===========================================================================
cd /d "%~dp0.."
set "CD_RESULT=%ERRORLEVEL%"
if not "%CD_RESULT%"=="0" goto :err
echo Working directory: "%CD%"

REM The repository has one universal production profile. Runtime descriptors
REM select the standard-board or real V25 hardware path; use the single
REM build-segas32.bat wrapper for source/build workflows.
if not defined S32_PROJECT set S32_PROJECT=Arcade-SegaSystem32
if not defined S32_REVISION set S32_REVISION=Arcade-SegaSystem32
if not defined S32_RELEASE_NAME set S32_RELEASE_NAME=Arcade-SegaSystem32
if not defined S32_RESUME_FIT set S32_RESUME_FIT=0
if not defined S32_MAP_RETRIES set S32_MAP_RETRIES=2
if not defined S32_FIT_RETRIES set S32_FIT_RETRIES=2
if not defined S32_FIT_SEEDS set S32_FIT_SEEDS=2 3 4 6 1 5
if not defined S32_SEED_RESULTS_DIR set S32_SEED_RESULTS_DIR=output_files\seed-results

if not defined QUARTUS_ROOT goto :quartus_root_missing
set "QBIN=%QUARTUS_ROOT%\quartus\bin64"
set "QSYS=%QUARTUS_ROOT%\quartus\sopc_builder\bin"

echo [0/7] Validating toolchain, configuration, host resources, and exclusivity...
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-preflight.ps1 -ProjectRoot "%CD%" -QuartusRoot "%QUARTUS_ROOT%" -Project "%S32_PROJECT%" -Revision "%S32_REVISION%" -ReleaseName "%S32_RELEASE_NAME%" -FitSeeds "%S32_FIT_SEEDS%" -MapRetries "%S32_MAP_RETRIES%" -FitRetries "%S32_FIT_RETRIES%" -ResumeFit "%S32_RESUME_FIT%"
set "PREFLIGHT_RESULT=%ERRORLEVEL%"
if not "%PREFLIGHT_RESULT%"=="0" goto :err
echo Quartus project: %S32_PROJECT%  revision: %S32_REVISION%
echo Release output: releases\%S32_RELEASE_NAME%.rbf

if /I "%S32_RESUME_FIT%"=="1" goto :resume_fit

:fresh_build
echo [1/7] Removing stale Quartus databases, generated PLL netlist, and output...
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-clean.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -Mode Fresh
set "CLEAN_RESULT=%ERRORLEVEL%"
if not "%CLEAN_RESULT%"=="0" goto :err

echo [2/7] Generating PLL IP (actual 96.634615 / 48.317307 MHz)...
"%QSYS%\qsys-script.exe" --script=tools/make_pll.tcl
set "QSYS_SCRIPT_RESULT=%ERRORLEVEL%"
if not "%QSYS_SCRIPT_RESULT%"=="0" goto :qsys_script_failed
"%QSYS%\qsys-generate.exe" rtl/pll/pll.qsys --synthesis=VERILOG --output-directory=rtl/pll
set "QSYS_GENERATE_RESULT=%ERRORLEVEL%"
if not "%QSYS_GENERATE_RESULT%"=="0" goto :qsys_generate_failed
if not exist "rtl\pll\pll.qip" goto :qsys_output_missing
if not exist "rtl\pll\synthesis\pll.qip" goto :qsys_output_missing
for %%F in ("rtl\pll\pll.qip" "rtl\pll\synthesis\pll.qip") do if %%~zF LEQ 0 goto :qsys_output_missing

echo [3/7] Running Analysis and Synthesis...
set /A MAP_ATTEMPT=0

:map_retry
set /A MAP_ATTEMPT+=1
echo Synthesis attempt %MAP_ATTEMPT% of %S32_MAP_RETRIES%...
"%QBIN%\quartus_map.exe" --read_settings_files=on --write_settings_files=off "%S32_PROJECT%" -c "%S32_REVISION%"
set "MAP_NATIVE_RESULT=%ERRORLEVEL%"
if not exist "output_files\%S32_REVISION%.map.summary" goto :map_transient_failure
findstr /B /C:"Analysis & Synthesis Status : Failed" "output_files\%S32_REVISION%.map.summary" >nul 2>&1
set "MAP_FAILED_STATUS=%ERRORLEVEL%"
if "%MAP_FAILED_STATUS%"=="0" goto :map_deterministic_failure
if not "%MAP_NATIVE_RESULT%"=="0" goto :map_transient_failure
findstr /B /C:"Analysis & Synthesis Status : Successful" "output_files\%S32_REVISION%.map.summary" >nul 2>&1
set "MAP_SUCCESS_STATUS=%ERRORLEVEL%"
if not "%MAP_SUCCESS_STATUS%"=="0" goto :map_transient_failure
goto :record_map_manifest

:map_transient_failure
echo Synthesis crashed or stopped without a conclusive summary. Native exit: %MAP_NATIVE_RESULT%.
if %MAP_ATTEMPT% GEQ %S32_MAP_RETRIES% goto :map_retries_exhausted
echo Clearing only generated build databases and retrying synthesis...
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-clean.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -Mode MapRetry
set "MAP_CLEAN_RESULT=%ERRORLEVEL%"
if not "%MAP_CLEAN_RESULT%"=="0" goto :err
if not exist "rtl\pll\synthesis\pll.qip" goto :qsys_output_missing
goto :map_retry

:map_deterministic_failure
echo ERROR: Analysis and Synthesis reported a deterministic failure; retrying would reproduce it.
goto :err

:map_retries_exhausted
echo ERROR: Analysis and Synthesis exhausted %S32_MAP_RETRIES% crash/no-summary attempts.
goto :err

:record_map_manifest
powershell -NoProfile -ExecutionPolicy Bypass -File tools\report-quartus.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -QuartusRoot "%QUARTUS_ROOT%" -WriteMapManifest -RequireMapCurrent
set "MANIFEST_RESULT=%ERRORLEVEL%"
if not "%MANIFEST_RESULT%"=="0" goto :err
goto :map_ok

:resume_fit
echo [1-3/7] Validating the reusable Analysis and Synthesis database...
if not exist "db\%S32_REVISION%.map.cdb" goto :resume_rebuild
for %%F in ("db\%S32_REVISION%.map.cdb") do if %%~zF LEQ 0 goto :resume_rebuild
if not exist "rtl\pll\pll.qip" goto :resume_rebuild
if not exist "rtl\pll\synthesis\pll.qip" goto :resume_rebuild
for %%F in ("rtl\pll\pll.qip" "rtl\pll\synthesis\pll.qip") do if %%~zF LEQ 0 goto :resume_rebuild
powershell -NoProfile -ExecutionPolicy Bypass -File tools\report-quartus.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -QuartusRoot "%QUARTUS_ROOT%" -RequireMapCurrent
set "RESUME_RESULT=%ERRORLEVEL%"
if "%RESUME_RESULT%"=="0" goto :map_ok

:resume_rebuild
echo Existing synthesis is missing, stale, altered, or from another toolchain; rebuilding it.
goto :fresh_build

:map_ok
echo [4/7] Fitting with classified crash retries and timing seed sweep...
for %%S in (%S32_FIT_SEEDS%) do (
    call :try_seed %%S
    set "SEED_RESULT=!ERRORLEVEL!"
    if "!SEED_RESULT!"=="0" goto :done
    if "!SEED_RESULT!"=="2" goto :err
)
echo ERROR: No fitter seed produced a timing-qualified result.
if exist "%S32_SEED_RESULTS_DIR%\best-timing.json" type "%S32_SEED_RESULTS_DIR%\best-timing.json"
goto :err

:done
echo.
echo DONE: releases\%S32_RELEASE_NAME%.rbf
echo Copy the RBF to \media\fat\_Arcade\cores\ and the matching MRA to \media\fat\_Arcade\.
endlocal & exit /b 0

:try_seed
set "FIT_SEED=%~1"
set /A FIT_ATTEMPT=0

:fit_retry
set /A FIT_ATTEMPT+=1
echo.
echo Fitter seed %FIT_SEED%, attempt %FIT_ATTEMPT% of %S32_FIT_RETRIES%...
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-clean.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -Mode Candidate
set "CANDIDATE_CLEAN_RESULT=%ERRORLEVEL%"
if not "%CANDIDATE_CLEAN_RESULT%"=="0" exit /b 2

"%QBIN%\quartus_fit.exe" --read_settings_files=on --write_settings_files=off --seed=%FIT_SEED% "%S32_PROJECT%" -c "%S32_REVISION%"
set "FIT_NATIVE_RESULT=%ERRORLEVEL%"
if not exist "output_files\%S32_REVISION%.fit.summary" goto :fit_transient_failure
findstr /B /C:"Fitter Status : Failed" "output_files\%S32_REVISION%.fit.summary" >nul 2>&1
set "FIT_FAILED_STATUS=%ERRORLEVEL%"
if "%FIT_FAILED_STATUS%"=="0" goto :fit_deterministic_failure
if not "%FIT_NATIVE_RESULT%"=="0" goto :fit_transient_failure
findstr /B /C:"Fitter Status : Successful" "output_files\%S32_REVISION%.fit.summary" >nul 2>&1
set "FIT_SUCCESS_STATUS=%ERRORLEVEL%"
if not "%FIT_SUCCESS_STATUS%"=="0" goto :fit_transient_failure
goto :fit_ok

:fit_transient_failure
echo Fitter seed %FIT_SEED% crashed or stopped without a conclusive summary. Native exit: %FIT_NATIVE_RESULT%.
if %FIT_ATTEMPT% GEQ %S32_FIT_RETRIES% goto :fit_transient_exhausted
echo Retrying the same seed from the preserved synthesized netlist...
goto :fit_retry

:fit_transient_exhausted
echo Seed %FIT_SEED% exhausted %S32_FIT_RETRIES% crash/no-summary attempts.
call :archive_seed
set "ARCHIVE_RESULT=%ERRORLEVEL%"
if not "%ARCHIVE_RESULT%"=="0" exit /b 2
exit /b 1

:fit_deterministic_failure
echo Seed %FIT_SEED% reported a deterministic fit failure; moving to the next seed.
call :archive_seed
set "ARCHIVE_RESULT=%ERRORLEVEL%"
if not "%ARCHIVE_RESULT%"=="0" exit /b 2
exit /b 1

:fit_ok
echo [5/7] Running multicorner timing analysis before assembly...
"%QBIN%\quartus_sta.exe" "%S32_PROJECT%" -c "%S32_REVISION%"
set "STA_NATIVE_RESULT=%ERRORLEVEL%"
if not "%STA_NATIVE_RESULT%"=="0" goto :seed_structural_failure

powershell -NoProfile -ExecutionPolicy Bypass -File tools\report-quartus.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -QuartusRoot "%QUARTUS_ROOT%" -ExpectedSeed %FIT_SEED% -RequireTiming
set "TIMING_RESULT=%ERRORLEVEL%"
if "%TIMING_RESULT%"=="0" goto :timing_ok
if "%TIMING_RESULT%"=="1" goto :timing_negative
goto :seed_structural_failure

:timing_negative
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-seed-state.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -ExpectedSeed %FIT_SEED% -StatePath "%S32_SEED_RESULTS_DIR%\best-timing.json"
set "BEST_RESULT=%ERRORLEVEL%"
if "%BEST_RESULT%"=="10" goto :run_detailed_timing
if not "%BEST_RESULT%"=="0" goto :seed_structural_failure
goto :archive_unqualified_seed

:run_detailed_timing
echo Seed %FIT_SEED% is a new timing best; generating full paths at every operating condition...
"%QBIN%\quartus_sta.exe" -t tools\report-timing-paths.tcl "%S32_REVISION%"
set "DIAGNOSTIC_RESULT=%ERRORLEVEL%"
if not "%DIAGNOSTIC_RESULT%"=="0" echo WARNING: Detailed timing diagnostics exited %DIAGNOSTIC_RESULT%; the seed remains unqualified.

:archive_unqualified_seed
call :archive_seed
set "ARCHIVE_RESULT=%ERRORLEVEL%"
if not "%ARCHIVE_RESULT%"=="0" exit /b 2
echo Seed %FIT_SEED% did not meet timing; trying the next seed.
exit /b 1

:timing_ok
echo [6/7] Assembling the timing-qualified candidate RBF...
"%QBIN%\quartus_asm.exe" --read_settings_files=on --write_settings_files=off "%S32_PROJECT%" -c "%S32_REVISION%"
set "ASM_NATIVE_RESULT=%ERRORLEVEL%"
if not "%ASM_NATIVE_RESULT%"=="0" goto :seed_structural_failure

echo [7/7] Verifying the complete input/map/fit/STA/ASM/RBF chain...
powershell -NoProfile -ExecutionPolicy Bypass -File tools\report-quartus.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -QuartusRoot "%QUARTUS_ROOT%" -ExpectedSeed %FIT_SEED% -RequireReady
set "QUALIFY_RESULT=%ERRORLEVEL%"
call :archive_seed
set "ARCHIVE_RESULT=%ERRORLEVEL%"
if not "%ARCHIVE_RESULT%"=="0" exit /b 2
if not "%QUALIFY_RESULT%"=="0" exit /b 2

powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-stage-release.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -ReleaseName "%S32_RELEASE_NAME%"
set "STAGE_RESULT=%ERRORLEVEL%"
if not "%STAGE_RESULT%"=="0" exit /b 2
echo Qualified fitter seed %FIT_SEED%.
exit /b 0

:seed_structural_failure
echo ERROR: Seed %FIT_SEED% produced a stale, malformed, or incomplete build stage; the seed sweep is stopping.
call :archive_seed
exit /b 2

:archive_seed
set "SEED_ARCHIVE=%S32_SEED_RESULTS_DIR%\seed-%FIT_SEED%"
if not exist "%SEED_ARCHIVE%" mkdir "%SEED_ARCHIVE%"
if not exist "%SEED_ARCHIVE%" exit /b 2
for %%F in (fit.summary fit.rpt fit.smsg sta.summary sta.rpt sta.smsg asm.summary asm.rpt asm.smsg map.inputs.json) do (
    call :archive_one "output_files\%S32_REVISION%.%%F"
    if not "!ERRORLEVEL!"=="0" exit /b 2
)
for %%F in ("output_files\timing-*.rpt") do (
    call :archive_one "%%~fF"
    if not "!ERRORLEVEL!"=="0" exit /b 2
)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\report-quartus.ps1 -ProjectRoot "%CD%" -Revision "%S32_REVISION%" -QuartusRoot "%QUARTUS_ROOT%" -ExpectedSeed %FIT_SEED% -AsJson > "%SEED_ARCHIVE%\qualification.json.tmp"
set "ARCHIVE_REPORT_RESULT=%ERRORLEVEL%"
if not "%ARCHIVE_REPORT_RESULT%"=="0" exit /b 2
move /Y "%SEED_ARCHIVE%\qualification.json.tmp" "%SEED_ARCHIVE%\qualification.json" >nul
set "ARCHIVE_MOVE_RESULT=%ERRORLEVEL%"
if not "%ARCHIVE_MOVE_RESULT%"=="0" exit /b 2
exit /b 0

:archive_one
if not exist "%~1" exit /b 0
copy /Y "%~1" "%SEED_ARCHIVE%\" >nul
set "ARCHIVE_COPY_RESULT=%ERRORLEVEL%"
if not "%ARCHIVE_COPY_RESULT%"=="0" exit /b 2
exit /b 0

:quartus_root_missing
echo ERROR: QUARTUS_ROOT is not set.
echo Set it to the pinned installation, for example: set QUARTUS_ROOT=D:\Q17
goto :err

:qsys_script_failed
echo ERROR: qsys-script exited %QSYS_SCRIPT_RESULT%.
goto :err

:qsys_generate_failed
echo ERROR: qsys-generate exited %QSYS_GENERATE_RESULT%.
goto :err

:qsys_output_missing
echo ERROR: Qsys did not generate nonempty rtl\pll\pll.qip and rtl\pll\synthesis\pll.qip files.
goto :err

:err
echo.
echo BUILD FAILED - inspect the persistent build-*.log and output_files\*.rpt files.
endlocal & exit /b 1
