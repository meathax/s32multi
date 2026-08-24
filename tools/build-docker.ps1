[CmdletBinding()]
param(
    [string]$Image = "raetro/quartus:17.0",
    [switch]$SkipPull
)

$ErrorActionPreference = "Stop"
throw @"
The Docker build entrypoint is disabled because it bypasses the locked,
fingerprinted universal-profile release pipeline and cannot safely qualify an RBF.

Use a supported Windows build with the pinned local toolchain:

    set QUARTUS_ROOT=D:\Q17
    tools\build-s32.bat

D:\Q17 is validated as Quartus Lite 17.0.2.602 before any compiler starts.
The Image and SkipPull parameters are retained only so old invocations fail
with this actionable message before Docker, Quartus, or Qsys can run.
"@
