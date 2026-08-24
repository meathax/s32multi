[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$Revision,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$ReleaseName,
    [string]$SourcePath = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "sha256.ps1")
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path $ProjectRoot "output_files\$Revision.rbf"
}
$source = Get-Item -LiteralPath $SourcePath -ErrorAction Stop
if ($source.PSIsContainer -or $source.Length -le 0) {
    throw "Qualified RBF is missing or empty: $SourcePath"
}

$releaseDir = Join-Path $ProjectRoot "releases"
[IO.Directory]::CreateDirectory($releaseDir) | Out-Null
$destination = Join-Path $releaseDir "$ReleaseName.rbf"
$temp = Join-Path $releaseDir ".$ReleaseName.rbf.partial.$PID.$([Guid]::NewGuid().ToString('N'))"

try {
    [IO.File]::Copy($source.FullName, $temp, $false)
    $sourceHash = Get-S32FileSha256 -LiteralPath $source.FullName
    $tempHash = Get-S32FileSha256 -LiteralPath $temp
    if ($sourceHash -ne $tempHash) {
        throw "RBF staging hash mismatch before activation."
    }

    Move-Item -LiteralPath $temp -Destination $destination -Force
    $final = Get-Item -LiteralPath $destination -ErrorAction Stop
    if ($final.Length -ne $source.Length) {
        throw "Staged release size differs from the qualified RBF."
    }
    $finalHash = Get-S32FileSha256 -LiteralPath $destination
    if ($finalHash -ne $sourceHash) {
        throw "Staged release hash differs from the qualified RBF."
    }

    Write-Host "Staged verified release: $destination"
    Write-Host "SHA256: $($sourceHash.ToLowerInvariant())"
}
finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
