# Build the repository-owned native live System 32 Verilator model.
#
# This is intentionally separate from Quartus. It uses the safe Verilator
# scheduler, a no-space model directory, a content signature, and the existing
# real-ROM file list. A repository-owned timing loop serializes the complete
# model and Verilated context so long visual runs can checkpoint and resume.

[CmdletBinding()]
param(
    [string]$ModelDirectory = "",
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Safe = (Get-Command "verilator-safe.exe" -ErrorAction Stop).Source
. (Join-Path $PSScriptRoot 'verilator-workspace.ps1')
if ([string]::IsNullOrWhiteSpace($ModelDirectory)) {
    $ModelDirectory = New-S32VerilatorWorkspace -SafeLauncher $Safe -ModelDirectoryName 's32_visual'
}
else {
    $ModelDirectory = [IO.Path]::GetFullPath($ModelDirectory)
    if ($ModelDirectory -notmatch '^[Rr]:\\Verilator\\') {
        throw "ModelDirectory must be under R:\Verilator: $ModelDirectory"
    }
    $env:VERILATOR_WORKSPACE = Split-Path -Parent $ModelDirectory
}
$BuildTemp = Join-Path $env:VERILATOR_WORKSPACE 'temp'
New-Item -ItemType Directory -Force -Path $BuildTemp | Out-Null

if ($ModelDirectory.Contains(" ")) {
    throw "ModelDirectory must not contain spaces: $ModelDirectory"
}
$fileList = Join-Path $Root "scratch\romboot.f"
if (-not (Test-Path -LiteralPath $fileList)) {
    throw "Missing source file list: $fileList"
}

& $Safe status
$sources = @(Get-Content -LiteralPath $fileList | Where-Object {
    $_.Trim() -and -not $_.Trim().StartsWith("#")
} | ForEach-Object {
    $path = if ([IO.Path]::IsPathRooted($_.Trim())) { $_.Trim() } else { Join-Path $Root $_.Trim() }
    [IO.Path]::GetFullPath($path)
})
foreach ($source in $sources) {
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing visual source: $source" }
}

$defines = @(
    "+define+SIMULATION",
    "+define+S32_REAL_FB_SIM",
    "+define+S32_PCB_TIMING",
    "+define+S32_EXTERNAL_CLOCKS",
    "+define+S32_SYSTEM32_ONLY",
    "+define+S32_PROFILE_STANDARD",
    "+define+S32_GAME_ONLY_STD",
    "+define+S32_UNIVERSAL",
    "+define+S32_V25_HW"
)
$warnings = @(
    "-Wno-fatal", "-Wno-WIDTHTRUNC", "-Wno-WIDTHEXPAND", "-Wno-UNOPTFLAT",
    "-Wno-BLKANDNBLK", "-Wno-CASEINCOMPLETE", "-Wno-MULTIDRIVEN",
    "-Wno-INITIALDLY", "-Wno-DECLFILENAME"
)
$exe = Join-Path $ModelDirectory "s32_visual.exe"
$signaturePath = Join-Path $ModelDirectory "s32_visual.signature"
$signatureParts = [Collections.Generic.List[string]]::new()
$signatureParts.Add(((& $Safe --version 2>&1 | Out-String).Trim()))
$visualMain = Join-Path $Root "verif\visual\s32_visual_main.cpp"
if (-not (Test-Path -LiteralPath $visualMain)) { throw "Missing visual frontend: $visualMain" }
$signatureParts.Add("threads=1;verilate-jobs=4;build-jobs=4;savable=1;profile=segas32")
$signatureParts.Add(($defines -join ";"))
$signatureParts.Add(($warnings -join ";"))
foreach ($source in $sources) {
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $signatureParts.Add($source + "=" + $sourceHash)
}
$signatureParts.Add($visualMain + "=" + (Get-FileHash -LiteralPath $visualMain -Algorithm SHA256).Hash)
$signatureBytes = [Text.Encoding]::UTF8.GetBytes(($signatureParts -join "`n"))
$signatureHashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash($signatureBytes)
$signature = (($signatureHashBytes | ForEach-Object { $_.ToString("x2") }) -join "")

$cached = (Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $signaturePath) -and
    ((Get-Content -LiteralPath $signaturePath -Raw).Trim() -eq $signature)
if ($Force -or -not $cached) {
    New-Item -ItemType Directory -Force -Path $ModelDirectory | Out-Null
    $arguments = @(
        "--cc", "--exe", "--build", "--no-timing", "--savable", "--threads", "1",
        "--verilate-jobs", "4", "--build-jobs", "4",
        "--top-module", "tb_core_romboot", "--Mdir", $ModelDirectory, "-o", "s32_visual",
        "-CFLAGS", "-D_GLIBCXX_USE_CXX11_ABI=0 -O3 -march=native -mtune=native -fomit-frame-pointer"
    ) + $warnings + $defines + @("-f", $fileList, $visualMain)
    Write-Host ("Building native visual model in {0}" -f $ModelDirectory)
    & $Safe @arguments
    if ($LASTEXITCODE -ne 0) { throw "verilator-safe build failed with exit code $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $exe)) { throw "Visual executable was not produced: $exe" }
    Set-Content -LiteralPath $signaturePath -Value $signature -Encoding ASCII
}
else {
    Write-Host "Reusing cached native visual model: $exe"
}

# The generated executable dynamically links the MSYS2 UCRT64 C++ runtime.
# Pin those DLLs beside the model so the safe native launcher cannot resolve
# an ABI-incompatible MinGW/MSYS copy from the host PATH.
foreach ($runtimeDll in @("libgcc_s_seh-1.dll", "libstdc++-6.dll", "libwinpthread-1.dll")) {
    $runtimeSource = Join-Path "D:\vibes\fpga\toolchains\msys64\ucrt64\bin" $runtimeDll
    if (-not (Test-Path -LiteralPath $runtimeSource)) {
        throw "Missing UCRT64 runtime DLL: $runtimeSource"
    }
    Copy-Item -LiteralPath $runtimeSource -Destination $ModelDirectory -Force
}

Write-Host "VISUAL BUILD PASS"
Write-Host "Verilator: $((& $Safe --version 2>&1 | Select-Object -First 1))"
Write-Host "Top module: tb_core_romboot"
Write-Host "Executable: $exe"
