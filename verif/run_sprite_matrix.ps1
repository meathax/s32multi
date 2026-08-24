# Exhaustive 315-5386A constrained-random differential matrix.
# Covers every supported logical ROM bank mask, ctl2 global flip, and width.
# A zero-draw baseline is run for every width/flip pair; ROM-bank behavior is
# immaterial in those cases because no sprite-ROM request may be issued.
[CmdletBinding()]
param(
    [string]$Output = "",
    [int]$Seed = 342122,
    [ValidateRange(1,1024)][int]$Commands = 64,
    [string]$ModelSimBin = "",
    [switch]$SkipBaselines
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if (-not $Output) {
    $Output = Join-Path ([IO.Path]::GetTempPath()) ("s32-sprite-matrix-" + [guid]::NewGuid().ToString("N"))
}
$Output = [IO.Path]::GetFullPath($Output)
$Results = @()

function Invoke-SpriteCase {
    param(
        [string]$Name,
        [int]$Banks,
        [int]$Flip,
        [int]$Width,
        [int]$Draws,
        [int]$CaseSeed,
        [int]$RomStall
    )
    $Fixture = Join-Path $Output ("fixture-" + $Name)
    $Work = Join-Path $Output ("work-" + $Name)
    $RomSize = $Banks * 0x400000
    & python -m verif.sprite_replay.generate_cases $Fixture --seed $CaseSeed --commands $Draws --width $Width --rom-size $RomSize --global-flip $Flip
    if ($LASTEXITCODE -ne 0) { throw "sprite fixture generation failed: $Name" }
    $Arguments = @(
        "-m", "verif.sprite_replay.run", (Join-Path $Fixture "manifest.json"),
        "--work-dir", $Work, "--seed", $CaseSeed, "--rom-stall", $RomStall
    )
    if ($ModelSimBin) { $Arguments += @("--modelsim-bin", $ModelSimBin) }
    & python @Arguments
    if ($LASTEXITCODE -ne 0) { throw "sprite differential replay failed: $Name" }
    $Replay = Get-Content -Raw -LiteralPath (Join-Path $Work "replay_result.json") | ConvertFrom-Json
    $script:Results += [pscustomobject]@{
        case = $Name
        banks = $Banks
        flip = $Flip
        width = $Width
        draws = $Draws
        seed = $CaseSeed
        rom_stall = $RomStall
        visible_mismatches = $Replay.comparison_visible.mismatch_count
        physical_mismatches = $Replay.comparison_physical.mismatch_count
        physical_required = $Replay.physical_match_required
        raw_banks = $Replay.descriptor_bank_audit.raw_bank_histogram
        effective_banks = $Replay.descriptor_bank_audit.effective_bank_histogram
        rtl_summary = $Replay.rtl_summary
    }
}

Push-Location $Root
try {
    $CaseIndex = 0
    foreach ($Banks in @(1, 2, 4)) {
        foreach ($Flip in @(0, 1, 2, 3)) {
            foreach ($Width in @(320, 416)) {
                $CaseSeed = $Seed + $CaseIndex * 7919
                $RomStall = 1 + (($CaseIndex * 37 + 7) % 31)
                $Name = "bank${Banks}_flip${Flip}_w${Width}"
                Invoke-SpriteCase $Name $Banks $Flip $Width $Commands $CaseSeed $RomStall
                $CaseIndex++
            }
        }
    }
    if (-not $SkipBaselines) {
        foreach ($Flip in @(0, 1, 2, 3)) {
            foreach ($Width in @(320, 416)) {
                $CaseSeed = $Seed + $CaseIndex * 7919
                $RomStall = 1 + (($CaseIndex * 37 + 7) % 31)
                $Name = "baseline_flip${Flip}_w${Width}"
                Invoke-SpriteCase $Name 1 $Flip $Width 0 $CaseSeed $RomStall
                $CaseIndex++
            }
        }
    }
    $Results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Output "matrix_results.json") -Encoding utf8
    $Results | Format-Table case,visible_mismatches,physical_mismatches,physical_required,rtl_summary -AutoSize
    Write-Host "SPRITE DIFFERENTIAL MATRIX: PASS ($($Results.Count) cases)"
    Write-Host "Artifacts: $Output"
}
finally {
    Pop-Location
}
