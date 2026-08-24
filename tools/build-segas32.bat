@echo off
REM Thin wrapper for the universal segas32 production profile.
REM See tools/build.bat for the actual pipeline.
set S32_PROJECT=Arcade-SegaSystem32
set S32_REVISION=Arcade-SegaSystem32
if not defined S32_RELEASE_NAME set S32_RELEASE_NAME=Arcade-SegaSystem32
call "%~dp0build.bat" %*
