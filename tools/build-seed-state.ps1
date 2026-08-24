[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$Revision,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 9999)]
    [int]$ExpectedSeed,
    [string]$StatePath = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "sha256.ps1")
try {
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ProjectRoot = Split-Path -Parent $PSScriptRoot
    }
    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Join-Path $ProjectRoot "output_files\seed-results\best-timing.json"
    }

    $reportScript = Join-Path $PSScriptRoot "report-quartus.ps1"
    $json = & $reportScript -ProjectRoot $ProjectRoot -Revision $Revision -ExpectedSeed $ExpectedSeed -AsJson
    $result = $json | ConvertFrom-Json
    if (-not $result.MapCurrent -or -not $result.FitCurrent -or -not $result.TimingCurrent) {
        throw "Seed $ExpectedSeed does not have a current map/fit/timing chain."
    }
    if ($null -eq $result.WorstSlackNs) {
        throw "Seed $ExpectedSeed has no parsed timing slack."
    }

    $previous = $null
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
            $previous = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "Ignoring unreadable prior best-state file: $StatePath"
        }
    }

    $isNewBest = $null -eq $previous -or
        $null -eq $previous.WorstSlackNs -or
        [double]$result.WorstSlackNs -gt [double]$previous.WorstSlackNs

    if (-not $isNewBest) {
        Write-Host "Seed $ExpectedSeed slack $($result.WorstSlackNs) ns did not beat $($previous.WorstSlackNs) ns."
        exit 0
    }

    $fitReportPath = Join-Path $ProjectRoot "output_files\$Revision.fit.rpt"
    $state = [ordered]@{
        Revision = $Revision
        Seed = $ExpectedSeed
        WorstSlackNs = [double]$result.WorstSlackNs
        WorstTimingType = $result.WorstTimingType
        InputFingerprint = $result.InputFingerprint
        FitReportSha256 = if (Test-Path -LiteralPath $fitReportPath -PathType Leaf) {
            (Get-S32FileSha256 -LiteralPath $fitReportPath)
        } else {
            $null
        }
        RecordedUtc = [DateTime]::UtcNow.ToString("o")
    }

    $parent = Split-Path -Parent $StatePath
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = "$StatePath.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText(
            $temp,
            ([pscustomobject]$state | ConvertTo-Json -Depth 4) + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temp -Destination $StatePath -Force
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Seed $ExpectedSeed is the new best at $($result.WorstSlackNs) ns."
    exit 10
}
catch {
    Write-Error $_
    exit 3
}
