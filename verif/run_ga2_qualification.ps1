# Golden Axe: real ROMs through the production framebuffer/DDR path.
# This is intentionally separate from the fast broad regression.

#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateRange(1, 1000)]
    [int]$Frames = 120,

    [string]$ImageDir = "roms/sim/ga2",

    [string]$ModelSimBin = "",

    [string]$LogPath = "verif/modelsim-ga2-ddr-qualification.log",

    [switch]$KeepWork
)

$ErrorActionPreference = "Stop"
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Resolve-WorkspacePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Resolve-ModelSim {
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @($ModelSimBin, $env:MODELSIM_BIN, $env:MODELSIM_HOME)) {
        if ($candidate) { $candidates.Add($candidate) }
    }
    $command = Get-Command "vsim.exe" -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add((Split-Path -Parent $command.Source)) }

    foreach ($candidate in $candidates) {
        foreach ($directory in @($candidate, (Join-Path $candidate "win32aloem"))) {
            if ((Test-Path -LiteralPath (Join-Path $directory "vlib.exe")) -and
                (Test-Path -LiteralPath (Join-Path $directory "vlog.exe")) -and
                (Test-Path -LiteralPath (Join-Path $directory "vsim.exe"))) {
                return [IO.Path]::GetFullPath($directory)
            }
        }
    }
    throw "ModelSim not found. Pass -ModelSimBin or set MODELSIM_BIN."
}

function Invoke-Logged {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label
    )
    "[$Label] $Executable $($Arguments -join ' ')" |
        Tee-Object -FilePath $script:ResolvedLog -Append
    & $Executable @Arguments 2>&1 |
        Tee-Object -FilePath $script:ResolvedLog -Append
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

$ResolvedImage = Resolve-WorkspacePath $ImageDir
$ResolvedLog = Resolve-WorkspacePath $LogPath
$ModelSim = Resolve-ModelSim
$RunRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "s32-ga2-qualification-" + [guid]::NewGuid().ToString("N"))
$Work = Join-Path $RunRoot "work"
$Completed = $false

foreach ($name in @("maincpu.hex", "soundcpu.hex", "tiles.hex", "sprites.hex")) {
    if (-not (Test-Path -LiteralPath (Join-Path $ResolvedImage $name))) {
        throw "Golden Axe simulation image missing: $name in $ResolvedImage"
    }
}

$VideoSources = @(
    Get-ChildItem -LiteralPath (Join-Path $Root "rtl/video") -Filter "*.sv" |
        Sort-Object Name |
        ForEach-Object { $_.FullName }
)
$Sources = @(
    (Join-Path $Root "rtl/s32_pkg.sv"),
    (Join-Path $Root "rtl/cpu/v60/s32_v60.sv"),
    (Join-Path $Root "rtl/cpu/v60/s32_v60_bus.sv")
) + $VideoSources + @(
    (Join-Path $Root "rtl/audio/s32_rf5c68.sv"),
    (Join-Path $Root "rtl/audio/s32_multipcm.sv"),
    (Join-Path $Root "rtl/audio/s32_audio_mix.sv"),
    (Join-Path $Root "rtl/audio/s32_soundsys.sv"),
    (Join-Path $Root "rtl/io/s32_io.sv"),
    (Join-Path $Root "rtl/prot/s32_prot.sv"),
    (Join-Path $Root "verif/common/jt12_stub.v"),
    (Join-Path $Root "rtl/s32_core.sv"),
    (Join-Path $Root "rtl/mem/s32_fb_if.sv"),
    (Join-Path $Root "verif/common/s32_fb_ddr_model.sv"),
    (Join-Path $Root "verif/common/tb_core_romboot.sv")
)

New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ResolvedLog) | Out-Null
Set-Content -LiteralPath $ResolvedLog -Value @(
    "Golden Axe production framebuffer qualification",
    "Started: $([DateTime]::Now.ToString('o'))",
    "Frames: $Frames",
    "Images: $ResolvedImage",
    "ModelSim: $ModelSim",
    "Work: $RunRoot"
)

Push-Location $Root
try {
    Invoke-Logged (Join-Path $ModelSim "vlib.exe") @($Work) "vlib"
    Invoke-Logged (Join-Path $ModelSim "vlog.exe") (
        @(
            "-sv", "-work", $Work,
            "+define+SIMULATION",
            "+define+S32_SYSTEM32_ONLY",
            "+define+S32_PROFILE_STANDARD",
            "+define+S32_REAL_FB_SIM"
        ) + $Sources
    ) "vlog"

    $imageArg = $ResolvedImage.Replace("\", "/")
    Invoke-Logged (Join-Path $ModelSim "vsim.exe") @(
        "-c", "-lib", $Work,
        "-l", (Join-Path $RunRoot "vsim.log"),
        "-wlf", (Join-Path $RunRoot "ga2-qualification.wlf"),
        "tb_core_romboot", "-novopt",
        "+IMG=$imageArg", "+B0=22", "+FRAMES=$Frames",
        "+COINAT=41", "+COINLEN=2",
        "+STARTAT=51", "+STARTLEN=2",
        "+P1AT0=82", "+P1LEN0=2", "+P1MASK0=01",
        "+P1AT1=95", "+P1LEN1=20", "+P1MASK1=40",
        "+P1AT2=104", "+P1LEN2=2", "+P1MASK2=01",
        "+EEPSKIP=1000000000",
        "-do", "run -all; quit -f"
    ) "vsim"

    $text = Get-Content -Raw -LiteralPath $ResolvedLog
    if ($text -notmatch "GA2 DDR QUALIFICATION PASS") {
        throw "Qualification pass marker missing; inspect $ResolvedLog"
    }
    if ($text -notmatch "ROMBOOT DONE") {
        throw "ROM boot completion marker missing; inspect $ResolvedLog"
    }

    $Completed = $true
    Write-Host "GOLDEN AXE PRODUCTION-FRAMEBUFFER QUALIFICATION: PASS"
    Write-Host "Transcript: $ResolvedLog"
}
finally {
    Pop-Location
    if ($Completed -and -not $KeepWork) {
        Remove-Item -LiteralPath $RunRoot -Recurse -Force
    }
    else {
        Write-Host "ModelSim work retained at: $RunRoot"
    }
}
