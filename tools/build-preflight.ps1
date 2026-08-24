[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [Parameter(Mandatory = $true)]
    [string]$QuartusRoot,
    [Parameter(Mandatory = $true)]
    [string]$Project,
    [Parameter(Mandatory = $true)]
    [string]$Revision,
    [Parameter(Mandatory = $true)]
    [string]$ReleaseName,
    [Parameter(Mandatory = $true)]
    [string]$FitSeeds,
    [Parameter(Mandatory = $true)]
    [int]$MapRetries,
    [Parameter(Mandatory = $true)]
    [int]$FitRetries,
    [Parameter(Mandatory = $true)]
    [ValidateSet("0", "1")]
    [string]$ResumeFit,
    [string]$ExpectedQuartusVersion = "17.0.2.602"
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$QuartusRoot = (Resolve-Path -LiteralPath $QuartusRoot).Path

function Assert-SafeName([string]$Name, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "$Label '$Name' is invalid. Use only letters, digits, dot, underscore, and hyphen."
    }
}

Assert-SafeName $Project "Project"
Assert-SafeName $Revision "Revision"
Assert-SafeName $ReleaseName "ReleaseName"

if ($MapRetries -lt 1 -or $MapRetries -gt 10) {
    throw "MapRetries must be between 1 and 10."
}
if ($FitRetries -lt 1 -or $FitRetries -gt 10) {
    throw "FitRetries must be between 1 and 10."
}

$seedTokens = @($FitSeeds -split '\s+' | Where-Object { $_ })
if ($seedTokens.Count -eq 0) {
    throw "FitSeeds must contain at least one positive integer."
}
$seeds = @()
foreach ($token in $seedTokens) {
    $parsed = 0
    if (-not [int]::TryParse($token, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 9999) {
        throw "Invalid fitter seed '$token'. Seeds must be integers from 1 through 9999."
    }
    $seeds += $parsed
}
if (($seeds | Select-Object -Unique).Count -ne $seeds.Count) {
    throw "FitSeeds contains a duplicate seed: $FitSeeds"
}

$projectPath = Join-Path $ProjectRoot "$Project.qpf"
$revisionPath = Join-Path $ProjectRoot "$Revision.qsf"
foreach ($required in @($projectPath, $revisionPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required project file is missing: $required"
    }
}
$qpfText = [IO.File]::ReadAllText($projectPath)
$qpfRevisions = [regex]::Matches(
    $qpfText,
    '(?m)^PROJECT_REVISION\s*=\s*"([^"]+)"\s*$'
)
if ($qpfRevisions.Count -eq 0) {
    throw "Project file does not declare PROJECT_REVISION: $projectPath"
}
$declaredRevision = $qpfRevisions[$qpfRevisions.Count - 1].Groups[1].Value
if ($declaredRevision -cne $Revision) {
    throw "Project $Project declares revision '$declaredRevision', not requested revision '$Revision'."
}

$qbin = Join-Path $QuartusRoot "quartus\bin64"
$qsys = Join-Path $QuartusRoot "quartus\sopc_builder\bin"
$executables = @(
    (Join-Path $qbin "quartus_sh.exe"),
    (Join-Path $qbin "quartus_map.exe"),
    (Join-Path $qbin "quartus_fit.exe"),
    (Join-Path $qbin "quartus_asm.exe"),
    (Join-Path $qbin "quartus_sta.exe"),
    (Join-Path $qsys "qsys-script.exe"),
    (Join-Path $qsys "qsys-generate.exe")
)
foreach ($executable in $executables) {
    $item = Get-Item -LiteralPath $executable -ErrorAction SilentlyContinue
    if (-not $item -or $item.Length -le 0) {
        throw "Required Quartus executable is missing or empty: $executable"
    }
}

$versionPath = Join-Path $QuartusRoot "quartus\version.txt"
$versionText = if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
    [IO.File]::ReadAllText($versionPath)
} else {
    ""
}
$versionMatch = [regex]::Match($versionText, '(?m)^Version=([^\r\n]+)')
$quartusVersion = if ($versionMatch.Success) { $versionMatch.Groups[1].Value.Trim() } else { $null }
if (-not $quartusVersion) {
    throw "Could not determine Quartus version from $versionPath."
}
if ($ExpectedQuartusVersion -and $quartusVersion -ne $ExpectedQuartusVersion) {
    throw "Quartus version mismatch: expected $ExpectedQuartusVersion, found $quartusVersion in $QuartusRoot."
}

# Keep direct/preflight-only invocations safe too. Even a wrapper that owns
# the mutex must reject a compiler that was started outside the wrapper: a
# named mutex cannot detect an uncooperative legacy/manual Quartus process.
$compilerNames = @(
    "quartus_map", "quartus_fit", "quartus_asm", "quartus_sta",
    "qsys-script", "qsys-generate"
)
$active = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $compilerNames -contains $_.ProcessName.ToLowerInvariant()
})
if ($active.Count -gt 0) {
    $details = ($active | ForEach-Object { "$($_.ProcessName) (PID $($_.Id))" }) -join ", "
    throw "Another Quartus/Qsys compiler process is active: $details"
}

$root = [IO.Path]::GetPathRoot($ProjectRoot)
$drive = [IO.DriveInfo]::new($root)
$freeGiB = [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
if ($drive.AvailableFreeSpace -lt 5GB) {
    throw "Only $freeGiB GiB is free on $root; at least 5 GiB is required for a clean build."
}

$memory = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$freeMemoryGiB = if ($memory) {
    [Math]::Round(([double]$memory.FreePhysicalMemory * 1KB) / 1GB, 1)
} else {
    $null
}
if ($null -ne $freeMemoryGiB -and $freeMemoryGiB -lt 4) {
    throw "Only $freeMemoryGiB GiB of physical memory is free; close memory-heavy applications before building."
}
if ($null -ne $freeMemoryGiB -and $freeMemoryGiB -lt 8) {
    Write-Warning "Only $freeMemoryGiB GiB of physical memory is free; Quartus may be less reliable."
}

Write-Host "Build preflight passed."
Write-Host "  Project root:     $ProjectRoot"
Write-Host "  Quartus:          $QuartusRoot ($quartusVersion)"
Write-Host "  Project/revision: $Project / $Revision"
Write-Host "  Release:          $ReleaseName.rbf"
Write-Host "  Seeds:            $($seeds -join ', ')"
Write-Host "  Retries:          map=$MapRetries, fit-crash=$FitRetries"
Write-Host "  Resume fit:       $ResumeFit"
Write-Host "  Free disk:        $freeGiB GiB"
if ($null -ne $freeMemoryGiB) {
    Write-Host "  Free memory:      $freeMemoryGiB GiB"
}
