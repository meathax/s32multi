# Standalone 315-5386A constrained-random differential replay.
# Copyrighted ROM fixtures are generated under the caller-selected output
# directory and are never added to the repository.
[CmdletBinding()]
param(
    [string]$Output = "",
    [int]$Seed = 342122,
    [ValidateRange(0,1024)][int]$Commands = 64,
    [ValidateSet(320,416)][int]$Width = 320,
    [string]$ModelSimBin = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if (-not $Output) {
    $Output = Join-Path ([IO.Path]::GetTempPath()) ("s32-sprite-replay-" + [guid]::NewGuid().ToString("N"))
}
$Output = [IO.Path]::GetFullPath($Output)

Push-Location $Root
try {
    # Exhaust every hardware-visible combination.  Bank counts correspond to
    # 4, 8, and 16 MiB physical OBJECT regions; Holo uses the two-bank cases.
    $Cases = @()
    foreach ($Banks in @(1, 2, 4)) {
        foreach ($Flip in 0..3) {
            foreach ($CaseWidth in @(320, 416)) {
                $Cases += @{
                    Name = "bank${Banks}_flip${Flip}_w${CaseWidth}"
                    Banks = $Banks
                    Flip = $Flip
                    Width = $CaseWidth
                    Commands = $Commands
                }
            }
        }
    }
    # A random initial framebuffer with no DRAW entries proves that the
    # MAME-scanout/RTL-storage flip adapter preserves untouched pixels.  Use
    # Holo's two-bank geometry for these eight baselines.
    foreach ($Flip in 0..3) {
        foreach ($CaseWidth in @(320, 416)) {
            $Cases += @{
                Name = "baseline_bank2_flip${Flip}_w${CaseWidth}"
                Banks = 2
                Flip = $Flip
                Width = $CaseWidth
                Commands = 0
            }
        }
    }
    for ($Index = 0; $Index -lt $Cases.Count; $Index++) {
        $Case = $Cases[$Index]
        $Fixture = Join-Path $Output ("fixture-" + $Case.Name)
        $Work = Join-Path $Output ("work-" + $Case.Name)
        $CaseSeed = $Seed + $Index * 7919
        $RomSize = $Case.Banks * 0x400000
        & python -m verif.sprite_replay.generate_cases $Fixture --seed $CaseSeed --commands $Case.Commands --width $Case.Width --rom-size $RomSize --global-flip $Case.Flip
        if ($LASTEXITCODE -ne 0) { throw "sprite fixture generation failed: $($Case.Name)" }
        $Arguments = @("-m", "verif.sprite_replay.run", (Join-Path $Fixture "manifest.json"), "--work-dir", $Work, "--seed", $CaseSeed)
        if ($ModelSimBin) { $Arguments += @("--modelsim-bin", $ModelSimBin) }
        & python @Arguments
        if ($LASTEXITCODE -ne 0) { throw "sprite differential replay failed: $($Case.Name)" }
    }
    Write-Host "SPRITE DIFFERENTIAL SUITE: PASS ($($Cases.Count)/$($Cases.Count) cases)"
    Write-Host "Artifacts: $Output"
}
finally {
    Pop-Location
}
