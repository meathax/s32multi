# Native Windows equivalent of run_regression.sh for ModelSim Intel FPGA.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File verif/run_regression.ps1
#   pwsh -File verif/run_regression.ps1 -Seeds 50 -KeepWork
#
# MODELSIM_BIN may point at the directory containing vlog.exe/vsim.exe.
# A complete transcript is written to verif/modelsim-regression.log.

#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateRange(1, 10000)]
    [int]$Seeds = 50,

    [string]$ModelSimBin = "",

    [string]$Python = "",

    [string]$LogPath = "",

    [switch]$KeepWork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if (-not $LogPath) {
    $LogPath = Join-Path $PSScriptRoot "modelsim-regression.log"
}
elseif (-not [IO.Path]::IsPathRooted($LogPath)) {
    $LogPath = [IO.Path]::GetFullPath((Join-Path $Root $LogPath))
}

$RunRoot = Join-Path ([IO.Path]::GetTempPath()) ("s32-modelsim-regression-" + [guid]::NewGuid().ToString("N"))
$Completed = $false
$Summary = [Collections.Generic.List[string]]::new()

function Write-RunLine {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    Write-Host $Text
    if ($Text.Length -gt 0) {
        Add-Content -LiteralPath $script:LogPath -Value $Text
    }
}

function Add-RawLog {
    param([object[]]$Lines)
    if ($null -ne $Lines -and $Lines.Count -gt 0) {
        Add-Content -LiteralPath $script:LogPath -Value $Lines
    }
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][string]$Label
    )

    Add-Content -LiteralPath $script:LogPath -Value ("`n> {0} {1}" -f $FilePath, ($ArgumentList -join " "))
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    Add-RawLog $lines

    # ModelSim Intel 10.5b occasionally exits 211 with its own SIGSEGV stack
    # during long -novopt full-core runs.  The identical compiled soak is
    # deterministic and passes when relaunched, so retry this simulator-only
    # process fault once; all RTL/test failures keep their original result.
    if ($exitCode -eq 211 -and [IO.Path]::GetFileName($FilePath) -ieq "vsim.exe") {
        Write-RunLine "${Label}: ModelSim internal exit 211; retrying once"
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $retryLines = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { $_.ToString() })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $savedPreference
        }
        Add-RawLog $retryLines
        $lines = $retryLines
    }

    if ($exitCode -ne 0) {
        $lines | Select-Object -Last 120 | ForEach-Object { Write-Host $_ }
        throw "$Label exited with code $exitCode. See $LogPath"
    }
    return [string[]]$lines
}

function Resolve-ModelSimDirectory {
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @($ModelSimBin, $env:MODELSIM_BIN, $env:MODELSIM_HOME)) {
        if ($candidate) { $candidates.Add($candidate) }
    }

    $vsimCommand = Get-Command "vsim.exe" -ErrorAction SilentlyContinue
    if ($vsimCommand) { $candidates.Add((Split-Path -Parent $vsimCommand.Source)) }

    foreach ($candidate in $candidates) {
        foreach ($directory in @($candidate, (Join-Path $candidate "win32aloem"))) {
            if ((Test-Path -LiteralPath (Join-Path $directory "vlib.exe")) -and
                (Test-Path -LiteralPath (Join-Path $directory "vlog.exe")) -and
                (Test-Path -LiteralPath (Join-Path $directory "vsim.exe"))) {
                return [IO.Path]::GetFullPath($directory)
            }
        }
    }
    throw "ModelSim was not found. Pass -ModelSimBin or set MODELSIM_BIN to the directory containing vlib.exe, vlog.exe, and vsim.exe."
}

function Resolve-PythonCommand {
    foreach ($candidate in @($Python, "python3.exe", "python.exe")) {
        if (-not $candidate) { continue }
        if (Test-Path -LiteralPath $candidate) {
            return [IO.Path]::GetFullPath($candidate)
        }
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    throw "Python 3 was not found. Pass -Python with the Python 3 executable path."
}

function Resolve-Sources {
    param([Parameter(Mandatory = $true)][string[]]$Sources)
    $resolved = [Collections.Generic.List[string]]::new()
    foreach ($source in $Sources) {
        $path = if ([IO.Path]::IsPathRooted($source)) { $source } else { Join-Path $script:Root $source }
        if (-not (Test-Path -LiteralPath $path)) { throw "RTL/test source not found: $source" }
        $resolved.Add([IO.Path]::GetFullPath($path))
    }
    return [string[]]$resolved
}

function New-WorkLibrary {
    param([Parameter(Mandatory = $true)][string]$Name)
    $directory = Join-Path $script:RunRoot $Name
    $library = Join-Path $directory "work"
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    [void](Invoke-NativeCapture $script:Vlib @($library) "vlib ($Name)")
    return $library
}

function Assert-Marker {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Output,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not ($Output | Where-Object { $_.Contains($Marker) } | Select-Object -First 1)) {
        $Output | Select-Object -Last 120 | ForEach-Object { Write-Host $_ }
        throw "$Label did not emit expected marker '$Marker'. See $LogPath"
    }
    $script:Summary.Add($Marker)
    Write-RunLine $Marker
}

function Run-HdlTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Top,
        [Parameter(Mandatory = $true)][string[]]$Sources,
        [Parameter(Mandatory = $true)][string]$Marker,
        [string[]]$Defines = @(),
        [string[]]$VsimArguments = @()
    )

    $library = New-WorkLibrary $Name
    $arguments = @("-sv", "-work", $library)
    $arguments += "+define+SIMULATION"
    foreach ($define in $Defines) { $arguments += "+define+$define" }
    $arguments += Resolve-Sources $Sources
    [void](Invoke-NativeCapture $script:Vlog $arguments "vlog ($Name)")

    $testDirectory = Split-Path -Parent $library
    $simLog = Join-Path $testDirectory "vsim.log"
    $wlf = Join-Path $testDirectory "vsim.wlf"
    $arguments = @("-c", "-lib", $library, "-l", $simLog, "-wlf", $wlf, $Top) + $VsimArguments + @("-do", "run -all; quit -f")
    $output = @(Invoke-NativeCapture $script:Vsim $arguments "vsim ($Name)")
    Assert-Marker $output $Marker $Name
}

function Run-HdlCompile {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Sources,
        [Parameter(Mandatory = $true)][string]$Marker,
        [string[]]$Defines = @()
    )

    $library = New-WorkLibrary $Name
    $arguments = @("-sv", "-work", $library)
    foreach ($define in $Defines) { $arguments += "+define+$define" }
    $arguments += Resolve-Sources $Sources
    [void](Invoke-NativeCapture $script:Vlog $arguments "vlog ($Name)")
    $script:Summary.Add($Marker)
    Write-RunLine $Marker
}
function Run-JT12ResetTest {
    $name = "t30_jt12_reset"
    $library = New-WorkLibrary $name
    $jt12Directory = Join-Path $Root "rtl/audio/jt12"
    $jt12Sources = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath (Join-Path $jt12Directory "jt12.qip")) {
        if ($line -match '"([^"]+)"') {
            $jt12Sources.Add((Join-Path $jt12Directory $Matches[1]))
        }
    }
    $sources = @($jt12Sources) + (Resolve-Sources @("verif/common/tb_jt12_reset.sv"))
    [void](Invoke-NativeCapture $script:Vlog (@(
        "-sv", "-work", $library
    ) + $sources) "vlog ($name)")

    $testDirectory = Split-Path -Parent $library
    $output = @(Invoke-NativeCapture $script:Vsim @(
        "-c", "-lib", $library,
        "-l", (Join-Path $testDirectory "vsim.log"),
        "-wlf", (Join-Path $testDirectory "vsim.wlf"),
        "tb_jt12_reset", "-do", "run -all; quit -f"
    ) "vsim ($name)")
    Assert-Marker $output "JT12 RESET PASS" $name
}

function Write-Tier {    param([int]$Number, [string]$Description)
    Write-RunLine ("`n[{0}/35] {1}" -f $Number, $Description)
}

function Run-Differential {
    param([int]$Count)

    $name = "t05_v60_diff"
    $library = New-WorkLibrary $name
    $sources = Resolve-Sources @(
        "rtl/cpu/v60/s32_v60.sv",
        "rtl/cpu/v60/s32_v60_bus.sv",
        "verif/v60/tb_v60_diff.sv"
    )
    [void](Invoke-NativeCapture $script:Vlog (@("-sv", "-work", $library, "+define+SIMULATION") + $sources) "vlog ($name)")
    [void](Invoke-NativeCapture $script:PythonExe @("verif/cosim/v60_ref.py") "V60 reference self-test")

    $testDirectory = Split-Path -Parent $library
    for ($seed = 1; $seed -le $Count; $seed++) {
        $prefix = Join-Path $testDirectory ("p{0}" -f $seed)
        [void](Invoke-NativeCapture $script:PythonExe @("verif/cosim/gen_diff_program.py", $seed.ToString(), $prefix) "generate differential seed $seed")

        $hexPath = ($prefix + ".hex").Replace("\", "/")
        $simLog = Join-Path $testDirectory ("seed-{0}.log" -f $seed)
        $wlf = Join-Path $testDirectory ("seed-{0}.wlf" -f $seed)
        $output = @(Invoke-NativeCapture $script:Vsim @(
            "-c", "-lib", $library, "-l", $simLog, "-wlf", $wlf,
            "tb_v60_diff", "+hex=$hexPath", "-do", "run -all; quit -f"
        ) "vsim (differential seed $seed)")

        $actual = @(
            foreach ($line in $output) {
                if ($line -match '^\s*#\s*([RM][0-9]+=[0-9a-fA-FxXzZ]+)\s*$') { $Matches[1] }
            }
        )
        $expected = @(Get-Content -LiteralPath ($prefix + ".expected"))
        if ([string]::Join("`n", $expected) -cne [string]::Join("`n", $actual)) {
            Write-Host "SEED $seed DIVERGES:"
            Write-Host "Expected:"
            $expected | ForEach-Object { Write-Host "  $_" }
            Write-Host "RTL:"
            $actual | ForEach-Object { Write-Host "  $_" }
            throw "V60 differential seed $seed diverged. Work retained at $RunRoot"
        }
        if (($seed % 10) -eq 0 -or $seed -eq $Count) {
            Write-RunLine ("  differential seeds: {0}/{1}" -f $seed, $Count)
        }
    }

    $marker = "V60 DIFF: PASS ($Count/$Count seeds match reference)"
    $script:Summary.Add($marker)
    Write-RunLine $marker
}

$ModelSimDirectory = Resolve-ModelSimDirectory
$Vlib = Join-Path $ModelSimDirectory "vlib.exe"
$Vlog = Join-Path $ModelSimDirectory "vlog.exe"
$Vcom = Join-Path $ModelSimDirectory "vcom.exe"
$Vsim = Join-Path $ModelSimDirectory "vsim.exe"
$PythonExe = Resolve-PythonCommand

New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
Set-Content -LiteralPath $LogPath -Value @(
    "System 32 ModelSim regression",
    "Started: $([DateTime]::Now.ToString('o'))",
    "ModelSim: $ModelSimDirectory",
    "Python: $PythonExe",
    "Work: $RunRoot"
)

$VideoSources = @(
    Get-ChildItem -LiteralPath (Join-Path $Root "rtl/video") -Filter "*.sv" |
        Sort-Object Name |
        ForEach-Object { $_.FullName }
)
# ModelSim's full-core tests use the HLE-compatible shape. OutRunners has no
# V25/protection MCU: the core is unprotected hardware (MAME's init_orunners()
# installs no protection), so rtl/cpu/v25/, rtl/prot/, and rtl/comm/epr14084/
# were removed and no longer appear in this source list.
$FullCoreSources = @(
    "rtl/s32_pkg.sv",
    "rtl/cpu/v60/s32_v60.sv",
    "rtl/cpu/v60/s32_v60_bus.sv"
) + $VideoSources + @(
    "rtl/audio/s32_multipcm.sv",
    "rtl/audio/s32_audio_mix.sv",
    "rtl/audio/s32_soundsys.sv",
    "rtl/io/s32_io.sv",
    "verif/common/jt12_stub.v",
    "rtl/s32_core.sv"
)
$V60Sources = @("rtl/cpu/v60/s32_v60.sv", "rtl/cpu/v60/s32_v60_bus.sv")

Push-Location $Root
try {
    Write-RunLine "ModelSim native regression (no Cygwin/Icarus dependency)"

    Write-Tier 1 "ModelSim full-core lint (compatible HLE shape)"
    Run-HdlTest "t01_lint_standard" "tb_core_lint" ($FullCoreSources + "verif/common/tb_core_lint.sv") "CORE STANDARD PROFILE LINT PASS" @("SIMULATION", "S32_SYSTEM32_ONLY", "S32_PROFILE_STANDARD", "S32_GAME_ONLY_STD", "S32_PCB_TIMING")
    Write-RunLine "CORE MODELSIM STANDARD PROFILE: PASS"

    Write-Tier 2 "V60 smoke test"
    Run-HdlTest "t02_v60_smoke" "tb_v60_smoke" ($V60Sources + "verif/v60/tb_v60_smoke.sv") "SMOKE PASS"

    Write-Tier 3 "V60 directed suite"
    Run-HdlTest "t03_v60_directed" "tb_v60_directed" ($V60Sources + "verif/v60/tb_v60_directed.sv") "DIRECTED PASS"

    Write-Tier 4 "ModelSim full-core integration boot (compatible HLE shape)"
    Run-HdlTest "t04_boot_standard" "tb_core_boot" ($FullCoreSources + "verif/common/tb_core_boot.sv") "CORE BOOT PASS" @("SIMULATION", "S32_SYSTEM32_ONLY", "S32_PROFILE_STANDARD", "S32_GAME_ONLY_STD", "S32_PCB_TIMING") @("-novopt")
    Write-RunLine "CORE MODELSIM STANDARD BOOT: PASS"

    Write-Tier 5 "V60 differential co-sim vs independent reference ($Seeds seeds)"
    Run-Differential $Seeds

    Write-Tier 6 "full-core soak / simulator-tier acceptance (extended multi-frame)"
    Run-HdlTest "t06_core_soak" "tb_core_soak" ($FullCoreSources + "verif/common/tb_core_soak.sv") "CORE SOAK PASS" @("SIMULATION") @("-novopt")

    Write-Tier 7 "V60 audit-fix directed tests (string/CALL/RET/RSR + SEARCH)"
    Run-HdlTest "t07_v60_audit" "tb_v60_audit" ($V60Sources + "verif/v60/tb_v60_audit.sv") "AUDIT PASS"
    Run-HdlTest "t07_v60_search" "tb_v60_search" ($V60Sources + "verif/v60/tb_v60_search.sv") "V60 SEARCH PASS"
    Run-HdlTest "t07_v60_flags" "tb_v60_flags" ($V60Sources + "verif/v60/tb_v60_flags.sv") "V60 FLAGS PASS"
    Run-HdlTest "t07_v60_ga2_bossbar" "tb_v60_ga2_bossbar" ($V60Sources + "verif/v60/tb_v60_ga2_bossbar.sv") "V60 GA2 BOSSBAR PASS"
    Run-HdlTest "t07_v60_shaov" "tb_v60_shaov" ($V60Sources + "verif/v60/tb_v60_shaov.sv") "V60 SHAOV PASS"
    Run-HdlTest "t07_v60_incdecmem" "tb_v60_incdecmem" ($V60Sources + "verif/v60/tb_v60_incdecmem.sv") "V60 INCDECMEM PASS"
    Run-HdlTest "t07_v60_movd" "tb_v60_movd" ($V60Sources + "verif/v60/tb_v60_movd.sv") "V60 MOVD PASS"
    Run-HdlTest "t07_v60_divxmem" "tb_v60_divxmem" ($V60Sources + "verif/v60/tb_v60_divxmem.sv") "V60 DIVXMEM PASS"
    Run-HdlTest "t07_v60_cmpc" "tb_v60_cmpc" ($V60Sources + "verif/v60/tb_v60_cmpc.sv") "V60 CMPC PASS"
    Run-HdlTest "t07_v60_movcd" "tb_v60_movcd" ($V60Sources + "verif/v60/tb_v60_movcd.sv") "V60 MOVCD PASS"
    Run-HdlTest "t07_v60_schd" "tb_v60_schd" ($V60Sources + "verif/v60/tb_v60_schd.sv") "V60 SCHD PASS"
    Run-HdlTest "t07_v60_strfs" "tb_v60_strfs" ($V60Sources + "verif/v60/tb_v60_strfs.sv") "V60 STRFS PASS"
    Run-HdlTest "t07_v60_fp" "tb_v60_fp" ($V60Sources + "verif/v60/tb_v60_fp.sv") "V60 FP PASS"
    Run-HdlTest "t07_v60_fpdecode" "tb_v60_fpdecode" ($V60Sources + "verif/v60/tb_v60_fpdecode.sv") "V60 FPDECODE PASS"
    Run-HdlTest "t07_v60_no_fp" "tb_v60_no_fp" ($V60Sources + "verif/v60/tb_v60_no_fp.sv") "V60 NO-FP PASS" @("S32_V60_NO_FP")

    Write-Tier 8 "release contracts + exact dedicated-game profile boot/cache"
    $releaseOutput = @(Invoke-NativeCapture $PythonExe @("verif/check_holo_release.py") "Holo release MRA check")
    Assert-Marker $releaseOutput "HOLO RELEASE MRA PASS" "Holo release MRA check"
    $ga2MraOutput = @(Invoke-NativeCapture $PythonExe @("verif/check_ga2_release.py") "GA2 compatibility MRA check")
    Assert-Marker $ga2MraOutput "GA2 COMPAT MRA PASS" "GA2 compatibility MRA check"
    $arabMraOutput = @(Invoke-NativeCapture $PythonExe @("verif/check_arabianfight_release.py") "Arabian Fight release MRA check")
    Assert-Marker $arabMraOutput "ARABIAN FIGHT RELEASE PASS" "Arabian Fight release MRA check"
    Run-HdlTest "t08_ga2_path" "tb_core_ga2path" ($FullCoreSources + "verif/common/tb_core_ga2path.sv") "GA2 PATH PASS" @(
        "SIMULATION", "S32_SYSTEM32_ONLY", "S32_PROFILE_STANDARD", "S32_PCB_TIMING"
    ) @("-novopt")
    Run-HdlTest "t08_ga_rom_cache" "tb_ga_rom_cache" @(
        "rtl/s32_pkg.sv", "rtl/s32_core.sv", "verif/common/tb_ga_rom_cache.sv"
    ) "PASS: Golden Axe ROM cache directed/reference tests passed" @(
        "SIMULATION", "S32_SYSTEM32_ONLY", "S32_PROFILE_STANDARD", "S32_PCB_TIMING"
    )
    Run-HdlTest "t08_ga_rom_cache_32_baseline" "tb_ga_rom_cache" @(
        "rtl/s32_pkg.sv", "rtl/s32_core.sv", "verif/common/tb_ga_rom_cache.sv"
    ) "CACHE CONFLICT index_bits=5 pressure_requests=8" @(
        "SIMULATION", "S32_SYSTEM32_ONLY", "S32_PROFILE_STANDARD", "S32_PCB_TIMING",
        "S32_TEST_CACHE32"
    )

    Write-Tier 9 "framebuffer interface directed test (runs / shadow RMW / erase / read)"
    Run-HdlTest "t09_fb_if" "tb_fb_if" @("rtl/mem/s32_fb_if.sv", "verif/common/tb_fb_if.sv") "FB IF PASS"
    Run-HdlTest "t09_fb_if_throughput" "tb_fb_if_throughput" @(
        "rtl/mem/s32_fb_if.sv", "verif/common/tb_fb_if_throughput.sv"
    ) "FB THROUGHPUT PASS" @("SIMULATION")

    Write-Tier 10 "mixer directed + pixel latency + 512-case independent differential test"
    Run-HdlTest "t10_mixer" "tb_mixer" @("rtl/video/s32_linebuf.sv", "rtl/video/s32_mixer.sv", "rtl/video/s32_palette.sv", "verif/common/tb_mixer.sv") "MIXER PASS"
    # The mixer must finish a pixel inside one 416-wide pixel period (12
    # clk_ram edges). At 13 the picture is displayed one column late.
    Run-HdlTest "t10_mixer_latency" "tb_mixer_pixel_latency" @("rtl/video/s32_linebuf.sv", "rtl/video/s32_mixer.sv", "rtl/video/s32_palette.sv", "verif/common/tb_mixer_pixel_latency.sv") "MIXER PIXEL LATENCY PASS"
    $mixerDiffOutput = @(Invoke-NativeCapture $PythonExe @(
        "-m", "verif.mixer_diff.run",
        "--modelsim-bin", $ModelSimDirectory,
        "--seed", "5387", "--count", "512"
    ) "mixer differential")
    Assert-Marker $mixerDiffOutput "MIXER DIFF PASS cases=512" "mixer differential"
    Write-RunLine "MIXER DIFFERENTIAL: PASS (512 cases)"

    Write-Tier 11 "sprite pixel-path directed test (pen rules / end codes / flip / zoom / indirect)"
    Run-HdlTest "t11_sprite" "tb_sprite" @("rtl/video/s32_sprite.sv", "verif/common/tb_sprite.sv") "SPRITE PASS"
    Run-HdlTest "t11_sprite_fallback" "tb_sprite_fallback" @("rtl/video/s32_sprite.sv", "verif/common/tb_sprite.sv", "verif/common/tb_sprite_fallback.sv") "SPRITE FALLBACK PASS"

    Write-Tier 12 "sprite scale divider exactness / fixed-latency test"
    Run-HdlTest "t12_sprite_div" "tb_sprite_div" @("rtl/video/s32_sprite.sv", "verif/common/tb_sprite_div.sv") "SPRITE DIV PASS"

    Write-Tier 13 "V60 DIVX/DIVUX iterative 64/32 exactness / latency test"
    Run-HdlTest "t13_v60_divx" "tb_v60_divx" ($V60Sources + "verif/v60/tb_v60_divx.sv") "DIVX PASS"

    Write-Tier 14 "V60 decimal group directed test (ADDDC/SUBDC/SUBRDC/CVTDPZ/CVTDZP)"
    Run-HdlTest "t14_v60_decimal" "tb_v60_decimal" ($V60Sources + "verif/v60/tb_v60_decimal.sv") "DECIMAL PASS"

    Write-Tier 15 "V60 bit string/field directed test (EXTBF/INSBF/SCHBS/MOVBS)"
    Run-HdlTest "t15_v60_bits" "tb_v60_bits" ($V60Sources + "verif/v60/tb_v60_bits.sv") "BITS PASS"

    Write-Tier 16 "V60 short backward-branch fetch performance"
    Run-HdlTest "t16_v60_fetch" "tb_v60_fetch" ($V60Sources + "verif/v60/tb_v60_fetch.sv") "FETCH PERF PASS"
    # tb_v60_fetch_wide / tb_v60_fetch_ram were removed together with the
    # optional fast instruction-fetch transport (the core always uses the PCB
    # fetch path now); their manifest entries go with them.
    Run-HdlTest "t16_v60_ea_overlap" "tb_v60_ea_overlap_disp" ($V60Sources + "verif/v60/tb_v60_ea_overlap_disp.sv") "V60 EA_OVERLAP DISP PASS"

    Write-Tier 17 "ROM loader reset / mapping / completion gating"
    Run-HdlTest "t17_rom_loader" "tb_rom_loader" @("rtl/s32_pkg.sv", "rtl/mem/s32_rom_loader.sv", "verif/common/tb_rom_loader.sv") "ROM LOADER PASS"
    Run-HdlTest "t17_rom_loader_wide" "tb_rom_loader_wide" @("rtl/s32_pkg.sv", "rtl/mem/s32_rom_loader.sv", "verif/common/tb_rom_loader_wide.sv") "WIDE ROM LOADER PASS"
    Run-HdlTest "t17_rom_loader_wave_clear" "tb_rom_loader_wave_clear" @(
        "rtl/s32_pkg.sv", "rtl/mem/s32_rom_loader.sv",
        "verif/common/tb_rom_loader_wave_clear.sv"
    ) "ROM LOADER WAVE CLEAR PASS"

    Write-Tier 18 "EEPROM persistence and HPS upload-boundary directed tests"
    Run-HdlTest "t18_eeprom" "tb_eeprom_nvram" @("rtl/s32_pkg.sv", "rtl/io/s32_io.sv", "verif/common/tb_eeprom_nvram.sv") "EEPROM NVRAM PASS"
    Run-HdlTest "t18_hps_eeprom" "tb_hps_eeprom_nvram" @(
        "sys/hps_io.sv", "rtl/s32_pkg.sv", "rtl/io/s32_io.sv",
        "verif/common/tb_hps_eeprom_nvram.sv"
    ) "HPS EEPROM NVRAM PASS"

    Write-Tier 19 "V60 20-byte F1 / high fetch-buffer offset regression"
    Run-HdlTest "t19_v60_long_ea" "tb_v60_long_ea" ($V60Sources + "verif/v60/tb_v60_long_ea.sv") "LONG EA PASS"

    Write-Tier 20 "palette RAM alias / byte-enable / write-both / dual-port timing"
    Run-HdlTest "t21_palette" "tb_palette" @("rtl/video/s32_palette.sv", "verif/common/tb_palette.sv") "PALETTE PASS"

    Write-Tier 21 "shared tile/bitmap line-buffer latency / layer / parity isolation"
    Run-HdlTest "t22_linebuf" "tb_linebuf" @("rtl/video/s32_linebuf.sv", "verif/common/tb_linebuf.sv") "LINEBUF PASS"

    Write-Tier 22 "tilemap VRAM fetches and deadline-safe scanline scheduling"
    Run-HdlTest "t23_tilemap_vram" "tb_tilemap_vram" @("rtl/video/s32_big_dpram.sv", "rtl/video/s32_vram.sv", "rtl/video/s32_tilemap.sv", "verif/common/tb_tilemap_vram.sv") "TILEMAP VRAM PASS" @("SIMULATION")
    Run-HdlTest "t23_tilemap_scale" "tb_tilemap_scale" @("rtl/video/s32_tilemap.sv", "verif/common/tb_tilemap_scale.sv") "TILEMAP SCALE PASS"
    Run-HdlTest "t23_tile_scheduler" "tb_tile_scheduler" @(
        "rtl/video/s32_tilemap.sv", "verif/common/tb_tile_scheduler.sv"
    ) "TILE SCHEDULER PASS" @("SIMULATION")
    Run-HdlTest "t23_tile_backpressure" "tb_tile_backpressure" @(
        "rtl/video/s32_tilemap.sv", "verif/common/tb_tile_backpressure.sv"
    ) "TILE BACKPRESSURE PASS" @("SIMULATION")
    Run-HdlTest "t23_video_mode" "tb_video_mode" @(
        "rtl/video/s32_video.sv", "verif/common/tb_video_mode.sv"
    ) "VIDEO MODE LATCH PASS"
    Run-HdlTest "t23_splitscreen_composer" "tb_splitscreen_composer" @(
        "rtl/video/s32_video.sv", "rtl/video/s32_splitscreen_composer.sv",
        "verif/common/tb_splitscreen_composer.sv"
    ) "SPLITSCREEN COMPOSER OVERALL PASS"

    Write-Tier 23 "byte-wide true-dual-port BRAM and audio clock cadence"
    Run-HdlTest "t24_byte_dpram" "tb_byte_dpram" @("rtl/video/s32_big_dpram.sv", "verif/common/tb_byte_dpram.sv") "BYTE DPRAM PASS"
    Run-HdlTest "t24_audio_ce" "tb_audio_ce" @(
        "rtl/audio/s32_audio_ce.sv", "verif/common/tb_audio_ce.sv"
    ) "AUDIO CE PASS"

    Write-Tier 24 "SDRAM CL2 capture / row-open ROM write throughput / burst ordering"
    Run-HdlTest "t26_sdram" "tb_sdram" @("rtl/mem/sdram.sv", "verif/common/tb_sdram.sv") "SDRAM CAPTURE PASS"
    Run-HdlTest "t26_sdram_write" "tb_sdram_write_throughput" @("rtl/mem/sdram.sv", "verif/common/tb_sdram_write_throughput.sv") "SDRAM WRITE THROUGHPUT PASS"
    Run-HdlTest "t26_sdram_write_mux2" "tb_sdram_write_mux2" @(
        "rtl/mem/s32_sdram_write_mux2.sv", "verif/common/tb_sdram_write_mux2.sv"
    ) "SDRAM WRITE MUX2 PASS" @("SIMULATION")
    Run-HdlTest "t26_sdram_tile_deadline" "tb_sdram_tile_deadline" @(
        "rtl/mem/sdram.sv", "verif/common/tb_sdram_tile_deadline.sv"
    ) "SDRAM TILE DEADLINE PASS"
    Run-HdlTest "t26_sdram_p0_throughput" "tb_sdram_p0_throughput" @(
        "rtl/mem/sdram.sv", "verif/common/tb_sdram_p0_throughput.sv"
    ) "SDRAM P0 THROUGHPUT PASS"
    Write-Tier 25 "integrated sprite renderer / backpressured DDR framebuffer stress"
    Run-HdlTest "t27_sprite_fb" "tb_sprite_fb" @("rtl/video/s32_sprite.sv", "rtl/mem/s32_fb_if.sv", "verif/common/tb_sprite_fb.sv") "SPRITE FB PASS"
    Run-HdlTest "t27_sprite_vblank" "tb_sprite_vblank" @("rtl/video/s32_sprite.sv", "rtl/mem/s32_fb_if.sv", "verif/common/tb_sprite_vblank.sv") "SPRITE VBLANK PASS"

    Write-Tier 26 "interrupt controller reset / source+ack collision / timers / doorbell"
    Run-HdlTest "t28_intc" "tb_intc" @("rtl/s32_pkg.sv", "rtl/io/s32_io.sv", "verif/common/tb_intc.sv") "INTC PASS"

    Write-Tier 27 "audio route arithmetic + generic/Golden Axe differential"
    Run-HdlTest "t29_audio_mix" "tb_audio_mix" @("rtl/audio/s32_audio_mix.sv", "verif/common/tb_audio_mix.sv") "AUDIO MIX PASS"
    Run-HdlTest "t29b_monitor_audio_route" "tb_monitor_audio_route" @("rtl/audio/s32_monitor_audio_route.sv", "verif/common/tb_monitor_audio_route.sv") "MONITOR AUDIO ROUTE PASS"
    Run-HdlTest "t29_audio_mix_diff_generic" "tb_audio_mix_diff" @(
        "rtl/audio/s32_audio_mix.sv", "verif/common/tb_audio_mix_diff.sv"
    ) "PASS: audio mixer differential checks=20012"
    Run-HdlTest "t29_audio_mix_diff_ga" "tb_audio_mix_diff" @(
        "rtl/audio/s32_audio_mix.sv", "verif/common/tb_audio_mix_diff.sv"
    ) "PASS: audio mixer differential checks=20012" @("S32_SYSTEM32_ONLY")

    Write-Tier 28 "sound map/cache throughput + production JT12 default-storage reset"
    Run-HdlTest "t30_soundsys_bus" "tb_soundsys_bus" @(
        "rtl/s32_pkg.sv", "rtl/video/s32_big_dpram.sv",
        "rtl/audio/s32_multipcm.sv",
        "rtl/audio/s32_audio_mix.sv", "rtl/audio/s32_soundsys.sv",
        "verif/common/jt12_stub.v", "verif/common/tb_soundsys_bus.sv"
    ) "SOUNDSYS BUS PASS" @("SIMULATION")
    $soundCacheSources = @(
        "rtl/s32_pkg.sv", "rtl/video/s32_big_dpram.sv",
        "rtl/audio/s32_multipcm.sv",
        "rtl/audio/s32_audio_mix.sv", "rtl/audio/s32_soundsys.sv",
        "verif/common/jt12_stub.v", "verif/common/tb_soundsys_zrom_cache.sv"
    )
    Run-HdlTest "t30_soundsys_zrom_cache_2" "tb_soundsys_zrom_cache" $soundCacheSources `
        "SOUNDSYS ZROM CACHE sets=1 ldir_requests=33 conflict_requests=160" @() @("-gZROM_CACHE_SETS=1")
    Run-HdlTest "t30_soundsys_zrom_cache_8" "tb_soundsys_zrom_cache" $soundCacheSources `
        "SOUNDSYS ZROM CACHE sets=4 ldir_requests=33 conflict_requests=8" @() @("-gZROM_CACHE_SETS=4")
    Run-JT12ResetTest

    Write-Tier 29 "MAME-backed MultiPCM descriptor / pitch / pan / loop / ACK semantics"
    Run-HdlTest "t31_multipcm" "tb_multipcm" @(
        "rtl/audio/s32_multipcm.sv", "verif/common/tb_multipcm.sv"
    ) "MULTIPCM PASS"
    Run-HdlTest "t31b_multipcm_output_level" "tb_multipcm_output_level" @(
        "rtl/audio/s32_multipcm.sv", "verif/common/tb_multipcm_output_level.sv"
    ) "AUDIO_LEVEL_RATIO reference_over_rtl=1"
    Run-HdlTest "t31c_multipcm_pan" "tb_multipcm_pan" @(
        "rtl/audio/s32_multipcm.sv", "verif/common/tb_multipcm_pan.sv"
    ) "MULTIPCM PAN PASS cases=32"

    Write-Tier 30 "V60 ROT/ROTC carry and active-width semantics"
    Run-HdlTest "t32_v60_rotate" "tb_v60_rotate" ($V60Sources + "verif/v60/tb_v60_rotate.sv") "V60 ROTATE PASS"

    Write-Tier 31 "V60 external bus byte/half/dword lane and alignment cycles"
    Run-HdlTest "t33_v60_bus_lanes" "tb_v60_bus_lanes" @(
        "rtl/cpu/v60/s32_v60_bus.sv", "verif/v60/tb_v60_bus_lanes.sv"
    ) "V60 BUS LANES PASS"
    Run-HdlTest "t33_v60_bus_nco_timing" "tb_v60_bus_nco_timing" @(
        "rtl/s32_pkg.sv", "rtl/cpu/v60/s32_v60_bus.sv",
        "verif/v60/tb_v60_bus_nco_timing.sv"
    ) "V60 BUS NCO TIMING PASS"
    $execCadenceSources = @(
        "rtl/s32_pkg.sv", "rtl/s32_core.sv",
        "verif/common/tb_v60_exec_cadence.sv"
    )
    Run-HdlTest "t33_v60_exec_cadence_universal" "tb_v60_exec_cadence" $execCadenceSources "V60 EXEC CADENCE PASS" @(
        "S32_SYSTEM32_ONLY", "S32_PROFILE_STANDARD", "S32_UNIVERSAL", "S32_V25_HW", "S32_GAME_ONLY_STD", "S32_PCB_TIMING"
    )
    Run-HdlTest "t33_v60_exec_retire" "tb_v60_exec_retire" @(
        "rtl/cpu/v60/s32_v60.sv", "rtl/cpu/v60/s32_v60_bus.sv",
        "verif/common/tb_v60_exec_retire.sv"
    ) "V60 EXEC RETIRE PASS"

    Write-Tier 32 "System32 palette/mixer/I-O mirrored address decode"
    Run-HdlTest "t34_core_map" "tb_core_map_decode" ($FullCoreSources + "verif/common/tb_core_map_decode.sv") "CORE MAP DECODE PASS" @("SIMULATION")

    Write-Tier 33 "direct positional wheel, right-stick pedals, and digital fallbacks"
    Run-HdlTest "t35_driving_controls" "tb_driving_controls" @(
        "rtl/io/s32_driving_controls.sv", "verif/common/tb_driving_controls.sv"
    ) "PASS: System 32 driving controls"

    Write-Tier 34 "MAME-backed Rad Mobile MSM6253 channel and MSB-first read semantics"
    Run-HdlTest "t37_radm_msm6253" "tb_radm_msm6253" @(
        "rtl/s32_pkg.sv", "rtl/io/s32_io.sv", "verif/common/tb_radm_msm6253.sv"
    ) "RAD MOBILE MSM6253 PASS"

    Write-Tier 35 "MCU download integrity: HPS ioctl pacing end-to-end"
    Run-HdlTest "t37_loader_hpspace" "tb_loader_hpspace" @(
        "rtl/s32_pkg.sv", "rtl/mem/s32_rom_loader.sv", "rtl/mem/sdram.sv",
        "verif/common/tb_loader_hpspace.sv"
    ) "LOADER HPSPACE PASS"

    Write-RunLine "`nSYSTEM 32 REGRESSION: PASS (35/35 tiers)"
    Write-RunLine "Detailed log: $LogPath"
    $Completed = $true
}
finally {
    Pop-Location
    if ($Completed -and -not $KeepWork) {
        # RunRoot is a GUID-named child created by this invocation only.
        Remove-Item -LiteralPath $RunRoot -Recurse -Force
    }
    else {
        Write-Host "ModelSim work retained at: $RunRoot"
        Add-Content -LiteralPath $LogPath -Value "ModelSim work retained at: $RunRoot"
    }
}
