[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$Revision,
    [Parameter(Mandatory = $true)]
    [ValidateSet("Fresh", "MapRetry", "DatabaseRetry", "RevisionFresh", "Candidate")]
    [string]$Mode
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$rootPrefix = $ProjectRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar

function Assert-ContainedPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside the project root: $full"
    }
    return $full
}

function Remove-CheckedPath([string]$Path) {
    $full = Assert-ContainedPath $Path
    if (-not (Test-Path -LiteralPath $full)) {
        return
    }
    $item = Get-Item -LiteralPath $full -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to remove reparse-point path: $full"
    }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $full) {
        throw "Cleanup failed; path still exists: $full"
    }
    Write-Host "Removed $full"
}

$outputDir = Join-Path $ProjectRoot "output_files"
switch ($Mode) {
    "Fresh" {
        Remove-CheckedPath (Join-Path $ProjectRoot "db")
        Remove-CheckedPath (Join-Path $ProjectRoot "incremental_db")
        Remove-CheckedPath $outputDir
        Remove-CheckedPath (Join-Path $ProjectRoot "rtl\pll\synthesis")
    }
    "MapRetry" {
        Remove-CheckedPath (Join-Path $ProjectRoot "db")
        Remove-CheckedPath (Join-Path $ProjectRoot "incremental_db")
        Remove-CheckedPath $outputDir
    }
    "DatabaseRetry" {
        # Recover generated elaboration databases after a no-summary map crash
        # while retaining reports, seed archives, and programming artifacts.
        Remove-CheckedPath (Join-Path $ProjectRoot "db")
        Remove-CheckedPath (Join-Path $ProjectRoot "incremental_db")
    }
    "RevisionFresh" {
        # Recover one demonstrably corrupt revision without discarding the
        # compilation databases and caches belonging to other revisions.
        foreach ($directory in @(
            (Join-Path $ProjectRoot "db"),
            (Join-Path $ProjectRoot "incremental_db"),
            $outputDir
        )) {
            if (Test-Path -LiteralPath $directory -PathType Container) {
                Get-ChildItem -LiteralPath $directory -Recurse -File -Force |
                    Where-Object { $_.Name.StartsWith($Revision, [StringComparison]::OrdinalIgnoreCase) } |
                    ForEach-Object { Remove-CheckedPath $_.FullName }
            }
        }
    }
    "Candidate" {
        foreach ($suffix in @(
            "rbf", "sof", "fit.summary", "fit.rpt", "fit.smsg",
            "sta.summary", "sta.rpt", "sta.smsg", "asm.rpt", "asm.summary", "asm.smsg"
        )) {
            Remove-CheckedPath (Join-Path $outputDir "$Revision.$suffix")
        }
        if (Test-Path -LiteralPath $outputDir -PathType Container) {
            Get-ChildItem -LiteralPath $outputDir -File -Filter "timing-*.rpt" |
                ForEach-Object { Remove-CheckedPath $_.FullName }
        }
    }
}
