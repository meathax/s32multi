[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$Revision = "s32",
    [int]$ExpectedSeed = -1,
    [string]$QuartusRoot = $env:QUARTUS_ROOT,
    [switch]$AsJson,
    [switch]$WriteMapManifest,
    [switch]$RequireMapCurrent,
    [switch]$RequireTiming,
    [switch]$RequireTimingCoverage,
    [switch]$RequireReady
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "sha256.ps1")
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
if ($Revision -notmatch '^[A-Za-z0-9_.-]+$') {
    throw "Revision may contain only letters, numbers, dot, underscore, and hyphen."
}
$outputDir = Join-Path $ProjectRoot "output_files"

function Read-OptionalFile([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return [IO.File]::ReadAllText($Path)
    }
    return $null
}

function Get-NonemptyFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($item -and -not $item.PSIsContainer -and $item.Length -gt 0) {
        return $item
    }
    return $null
}

function Match-Value([string]$Text, [string]$Pattern) {
    if (-not $Text) {
        return $null
    }
    $match = [regex]::Match($Text, $Pattern)
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    return $null
}

function Get-QuartusVersion([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return $null
    }
    $versionPath = Join-Path $Root "quartus\version.txt"
    $text = Read-OptionalFile $versionPath
    return Match-Value $text '(?m)^Version=([^\r\n]+)'
}

function Get-InputFiles([string]$Root, [string]$Rev) {
    $extensions = @(
        '.qip', '.qsys', '.sdc',
        '.sv', '.svh', '.v', '.vh', '.vhd', '.vhdl',
        '.mif', '.hex', '.mem'
    )
    $files = [Collections.Generic.List[IO.FileInfo]]::new()

    foreach ($projectFile in @("$Rev.qpf", "$Rev.qsf")) {
        $path = Join-Path $Root $projectFile
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($item) {
            $files.Add($item)
        }
    }

    Get-ChildItem -LiteralPath $Root -File -ErrorAction SilentlyContinue |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
        ForEach-Object { $files.Add($_) }

    foreach ($treeName in @('rtl', 'sys')) {
        $tree = Join-Path $Root $treeName
        if (Test-Path -LiteralPath $tree -PathType Container) {
            Get-ChildItem -LiteralPath $tree -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
                ForEach-Object { $files.Add($_) }
        }
    }

    $pllGenerator = Get-Item -LiteralPath (Join-Path $Root "tools\make_pll.tcl") -ErrorAction SilentlyContinue
    if ($pllGenerator) {
        $files.Add($pllGenerator)
    }

    # Sort-Object's default string collation differs between Windows PowerShell
    # 5.1 and PowerShell 7.  The build uses the former while deployment may use
    # the latter, which made identical inputs produce different fingerprints.
    $filesByPath = @{}
    foreach ($file in $files) {
        $filesByPath[$file.FullName] = $file
    }
    [string[]]$paths = @($filesByPath.Keys)
    [Array]::Sort($paths, [StringComparer]::OrdinalIgnoreCase)
    return @($paths | ForEach-Object { $filesByPath[$_] })
}

function Get-InputSnapshot([string]$Root, [IO.FileInfo[]]$Files) {
    $rows = @()
    foreach ($file in $Files) {
        $relative = $file.FullName.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
        $rows += [pscustomobject][ordered]@{
            Path = $relative
            Length = [int64]$file.Length
            Sha256 = (Get-S32FileSha256 -LiteralPath $file.FullName)
        }
    }

    $builder = [Text.StringBuilder]::new()
    foreach ($row in $rows) {
        [void]$builder.Append($row.Path)
        [void]$builder.Append([char]0)
        [void]$builder.Append($row.Length)
        [void]$builder.Append([char]0)
        [void]$builder.Append($row.Sha256)
        [void]$builder.Append([char]10)
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($builder.ToString()))
    }
    finally {
        $sha.Dispose()
    }

    return [pscustomobject]@{
        Fingerprint = ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
        Files = $rows
    }
}

function Write-AtomicUtf8([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = "$Path.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temp, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

$mapSummaryPath = Join-Path $outputDir "$Revision.map.summary"
$fitSummaryPath = Join-Path $outputDir "$Revision.fit.summary"
$staSummaryPath = Join-Path $outputDir "$Revision.sta.summary"
$mapReportPath = Join-Path $outputDir "$Revision.map.rpt"
$fitReportPath = Join-Path $outputDir "$Revision.fit.rpt"
$staReportPath = Join-Path $outputDir "$Revision.sta.rpt"
$asmReportPath = Join-Path $outputDir "$Revision.asm.rpt"
$rbfPath = Join-Path $outputDir "$Revision.rbf"
$qsfPath = Join-Path $ProjectRoot "$Revision.qsf"
$manifestPath = Join-Path $outputDir "$Revision.map.inputs.json"

$mapSummary = Read-OptionalFile $mapSummaryPath
$fitSummary = Read-OptionalFile $fitSummaryPath
$staSummary = Read-OptionalFile $staSummaryPath
$mapReport = Read-OptionalFile $mapReportPath
$fitReport = Read-OptionalFile $fitReportPath
$staReport = Read-OptionalFile $staReportPath
$qsf = Read-OptionalFile $qsfPath

$mapStatus = Match-Value $mapSummary '(?m)^Analysis & Synthesis Status\s*:\s*(.+)$'
$fitStatus = Match-Value $fitSummary '(?m)^Fitter Status\s*:\s*(.+)$'
$mapSuccessful = $mapStatus -like 'Successful*'
$fitSuccessful = $fitStatus -like 'Successful*'
$fitFinished = [bool]$fitStatus

$inputFiles = Get-InputFiles $ProjectRoot $Revision
$inputSnapshot = Get-InputSnapshot $ProjectRoot $inputFiles
$quartusVersion = Get-QuartusVersion $QuartusRoot

$mapSummaryFile = Get-NonemptyFile $mapSummaryPath
$mapReportFile = Get-NonemptyFile $mapReportPath
$fitSummaryFile = Get-NonemptyFile $fitSummaryPath
$fitReportFile = Get-NonemptyFile $fitReportPath
$staSummaryFile = Get-NonemptyFile $staSummaryPath
$staReportFile = Get-NonemptyFile $staReportPath
$asmReportFile = Get-NonemptyFile $asmReportPath

if ($WriteMapManifest) {
    if (-not $mapSuccessful -or -not $mapSummaryFile -or -not $mapReportFile) {
        Write-Error "Cannot record a map input manifest without successful, nonempty map summary and report files."
        exit 2
    }
    $manifest = [ordered]@{
        Schema = 1
        Revision = $Revision
        QuartusVersion = $quartusVersion
        InputFingerprint = $inputSnapshot.Fingerprint
        Inputs = $inputSnapshot.Files
        MapSummarySha256 = (Get-S32FileSha256 -LiteralPath $mapSummaryPath)
        MapReportSha256 = (Get-S32FileSha256 -LiteralPath $mapReportPath)
        RecordedUtc = [DateTime]::UtcNow.ToString("o")
    }
    Write-AtomicUtf8 $manifestPath (([pscustomobject]$manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    Write-Host "Recorded synthesis input fingerprint $($inputSnapshot.Fingerprint)."
}

$manifestFile = Get-NonemptyFile $manifestPath
$manifest = $null
$manifestReadable = $false
if ($manifestFile) {
    try {
        $manifest = Read-OptionalFile $manifestPath | ConvertFrom-Json
        $manifestReadable = $null -ne $manifest
    }
    catch {
        $manifestReadable = $false
    }
}

$manifestRevisionMatches = $manifestReadable -and $manifest.Revision -eq $Revision
$manifestInputRowsMatch = $false
if ($manifestRevisionMatches -and $null -ne $manifest.Inputs) {
    # Schema-1 manifests used the host PowerShell's collation order when
    # calculating the aggregate fingerprint. Compare their actual path/hash
    # rows as a set so an ordering-only runtime difference cannot stale a fit.
    $recordedInputs = @{}
    $currentInputs = @{}
    $rowsValid = $true
    foreach ($row in @($manifest.Inputs)) {
        $path = [string]$row.Path
        if ([string]::IsNullOrWhiteSpace($path) -or $recordedInputs.ContainsKey($path)) {
            $rowsValid = $false
            break
        }
        $recordedInputs[$path] = "$([int64]$row.Length)|$([string]$row.Sha256)"
    }
    foreach ($row in @($inputSnapshot.Files)) {
        $currentInputs[[string]$row.Path] = "$([int64]$row.Length)|$([string]$row.Sha256)"
    }
    if ($rowsValid -and $recordedInputs.Count -eq $currentInputs.Count) {
        $manifestInputRowsMatch = $true
        foreach ($path in $recordedInputs.Keys) {
            if (-not $currentInputs.ContainsKey($path) -or
                $currentInputs[$path] -cne $recordedInputs[$path]) {
                $manifestInputRowsMatch = $false
                break
            }
        }
    }
}
$manifestInputMatches = $manifestRevisionMatches -and
    ($manifest.InputFingerprint -eq $inputSnapshot.Fingerprint -or $manifestInputRowsMatch)
$manifestToolMatches = $manifestRevisionMatches -and
    ([string]::IsNullOrWhiteSpace($quartusVersion) -or $manifest.QuartusVersion -eq $quartusVersion)
$manifestMapHashesMatch = $false
if ($manifestRevisionMatches -and $mapSummaryFile -and $mapReportFile) {
    $manifestMapHashesMatch =
        $manifest.MapSummarySha256 -eq (Get-S32FileSha256 -LiteralPath $mapSummaryPath) -and
        $manifest.MapReportSha256 -eq (Get-S32FileSha256 -LiteralPath $mapReportPath)
}
$mapIsCurrent = $mapSuccessful -and [bool]$mapSummaryFile -and [bool]$mapReportFile -and
    $manifestReadable -and $manifestInputMatches -and $manifestToolMatches -and $manifestMapHashesMatch -and
    $manifestFile.LastWriteTimeUtc -ge $mapSummaryFile.LastWriteTimeUtc -and
    $manifestFile.LastWriteTimeUtc -ge $mapReportFile.LastWriteTimeUtc

$fitSeed = Match-Value $fitReport '(?m)^;\s*Fitter Initial Placement Seed\s*;\s*(\d+)\s*;'
$configuredSeed = Match-Value $qsf '(?m)^set_global_assignment -name SEED\s+(\d+)\s*$'
$seedMatchesExpected = $ExpectedSeed -lt 0 -or
    ($fitSeed -and [int]$fitSeed -eq $ExpectedSeed)
$mapNewestUtc = [DateTime]::MinValue
foreach ($item in @($mapSummaryFile, $mapReportFile)) {
    if ($item -and $item.LastWriteTimeUtc -gt $mapNewestUtc) {
        $mapNewestUtc = $item.LastWriteTimeUtc
    }
}
# The clean flow writes the manifest immediately after map, whereas the Smart
# Recompile flow records it after Quartus completes.  In both cases the map
# hashes and input fingerprint above establish provenance; fit freshness must
# therefore be ordered after the hashed map artifacts, not after the time at
# which their manifest happened to be written.
$fitIsCurrent = $fitSuccessful -and $mapIsCurrent -and [bool]$fitSummaryFile -and
    [bool]$fitReportFile -and $fitSummaryFile.LastWriteTimeUtc -ge $mapNewestUtc -and
    $fitReportFile.LastWriteTimeUtc -ge $mapNewestUtc -and $seedMatchesExpected
$fitNewestUtc = [DateTime]::MinValue
foreach ($item in @($fitSummaryFile, $fitReportFile)) {
    if ($item -and $item.LastWriteTimeUtc -gt $fitNewestUtc) {
        $fitNewestUtc = $item.LastWriteTimeUtc
    }
}
$staIsCurrent = $fitIsCurrent -and [bool]$staSummaryFile -and [bool]$staReportFile -and
    $staSummaryFile.LastWriteTimeUtc -ge $fitNewestUtc -and
    $staReportFile.LastWriteTimeUtc -ge $fitNewestUtc
$staNewestUtc = [DateTime]::MinValue
foreach ($item in @($staSummaryFile, $staReportFile)) {
    if ($item -and $item.LastWriteTimeUtc -gt $staNewestUtc) {
        $staNewestUtc = $item.LastWriteTimeUtc
    }
}

$timingRows = @()
if ($staIsCurrent -and $staSummary) {
    $timingMatches = [regex]::Matches(
        $staSummary,
        "(?ms)^Type\s+:\s+(.+?)\r?\nSlack\s+:\s+(-?\d+(?:\.\d+)?)"
    )
    foreach ($match in $timingMatches) {
        $timingRows += [pscustomobject]@{
            Type = $match.Groups[1].Value.Trim()
            Slack = [double]::Parse(
                $match.Groups[2].Value,
                [Globalization.CultureInfo]::InvariantCulture
            )
        }
    }
}

$worstTiming = $timingRows | Sort-Object Slack | Select-Object -First 1
$timingMet = $staIsCurrent -and $timingRows.Count -gt 0 -and $worstTiming.Slack -ge 0
$notFullyConstrained = [bool]($staReport -match '(?i)design is not fully constrained')
$timingCoverageComplete = $staIsCurrent -and -not $notFullyConstrained

$rbf = Get-NonemptyFile $rbfPath
$rbfIsCurrent = $staIsCurrent -and [bool]$rbf -and [bool]$asmReportFile -and
    $asmReportFile.LastWriteTimeUtc -ge $staNewestUtc -and
    $rbf.LastWriteTimeUtc -ge $staNewestUtc

$routeAverage = Match-Value $fitReport 'Router estimated average interconnect usage is (\d+%)'
$routePeak = Match-Value $fitReport 'Router estimated peak interconnect usage is (\d+%)'
$routeRegionMatch = if ($fitReport) {
    [regex]::Match($fitReport, 'region that extends from location (\S+) to location (\S+)')
} else {
    $null
}
$routeRegion = if ($routeRegionMatch -and $routeRegionMatch.Success) {
    "$($routeRegionMatch.Groups[1].Value) to $($routeRegionMatch.Groups[2].Value)"
} else {
    $null
}
$congestionFailure = [bool]($fitReport -match 'routing phase terminated due to routing congestion')

$ready = $mapIsCurrent -and $fitIsCurrent -and $staIsCurrent -and $timingMet -and $rbfIsCurrent
$result = [ordered]@{
    ProjectRoot = $ProjectRoot
    Revision = $Revision
    QuartusVersion = $quartusVersion
    ManifestQuartusVersion = if ($manifest) { $manifest.QuartusVersion } else { $null }
    InputFingerprint = $inputSnapshot.Fingerprint
    ManifestPath = $manifestPath
    ManifestReadable = $manifestReadable
    ManifestInputMatches = $manifestInputMatches
    ManifestToolMatches = $manifestToolMatches
    ManifestMapHashesMatch = $manifestMapHashesMatch
    Seed = $fitSeed
    ConfiguredSeed = $configuredSeed
    ExpectedSeed = if ($ExpectedSeed -ge 0) { $ExpectedSeed } else { $null }
    SeedMatchesExpected = $seedMatchesExpected
    MapStatus = $mapStatus
    MapCurrent = $mapIsCurrent
    MapEstimatedALMs = Match-Value $mapReport '; Estimate of Logic utilization \(ALMs needed\)\s*;\s*(\d+)'
    MapCombinationalALUTs = Match-Value $mapReport '; Combinational ALUT usage for logic\s*;\s*(\d+)'
    MapDedicatedRegisters = Match-Value $mapReport '; Dedicated logic registers\s*;\s*(\d+)'
    FitStatus = $fitStatus
    FitFinished = $fitFinished
    FitCurrent = $fitIsCurrent
    LogicALMs = Match-Value $fitSummary '(?m)^Logic utilization \(in ALMs\)\s*:\s*(.+)$'
    Registers = Match-Value $fitSummary '(?m)^Total registers\s*:\s*(.+)$'
    BlockMemoryBits = Match-Value $fitSummary '(?m)^Total block memory bits\s*:\s*(.+)$'
    RAMBlocks = Match-Value $fitSummary '(?m)^Total RAM Blocks\s*:\s*(.+)$'
    DSPBlocks = Match-Value $fitSummary '(?m)^Total DSP Blocks\s*:\s*(.+)$'
    PLLs = Match-Value $fitSummary '(?m)^Total PLLs\s*:\s*(.+)$'
    RouteAverage = $routeAverage
    RoutePeak = $routePeak
    RoutePeakRegion = $routeRegion
    CongestionFailure = $congestionFailure
    WorstTimingType = if ($worstTiming) { $worstTiming.Type } else { $null }
    WorstSlackNs = if ($worstTiming) { $worstTiming.Slack } else { $null }
    TimingRows = $timingRows.Count
    TimingMet = $timingMet
    TimingCurrent = $staIsCurrent
    NotFullyConstrained = $notFullyConstrained
    TimingCoverageComplete = $timingCoverageComplete
    LatestBuildInput = if ($inputFiles.Count -gt 0) {
        ($inputFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
    } else {
        $null
    }
    RbfPath = if ($rbf) { $rbf.FullName } else { $null }
    RbfSize = if ($rbf) { $rbf.Length } else { $null }
    RbfCurrent = $rbfIsCurrent
    ReadyToDeploy = $ready
}

if ($AsJson) {
    [pscustomobject]$result | ConvertTo-Json -Depth 6
}
else {
    Write-Host "Quartus result: fitted seed $(if ($result.Seed) { $result.Seed } else { 'unknown' }); configured seed $(if ($configuredSeed) { $configuredSeed } else { 'unknown' })"
    Write-Host "  Inputs:     $($result.InputFingerprint); manifest=$manifestReadable; matched=$manifestInputMatches; tool=$manifestToolMatches"
    Write-Host "  Map:        $(if ($result.MapStatus) { $result.MapStatus } else { 'pending or not run' }); current=$mapIsCurrent"
    if ($result.MapEstimatedALMs) {
        Write-Host "  Map area:   $($result.MapEstimatedALMs) estimated ALMs; $($result.MapCombinationalALUTs) combinational ALUTs"
    }
    Write-Host "  Fit:        $(if ($result.FitStatus) { $result.FitStatus } else { 'pending or not run' }); current=$fitIsCurrent"
    if ($result.LogicALMs) {
        Write-Host "  Resources:  $($result.LogicALMs) ALMs; $($result.RAMBlocks) RAM blocks"
    }
    if ($routeAverage -or $routePeak) {
        Write-Host "  Routing:    average $routeAverage; peak $routePeak; $routeRegion"
    }
    if ($staIsCurrent) {
        Write-Host "  Timing:     worst $($result.WorstSlackNs) ns ($($result.WorstTimingType)); met=$timingMet; current=True"
        Write-Host "  Coverage:   complete=$timingCoverageComplete; not-fully-constrained=$notFullyConstrained"
    }
    else {
        Write-Host "  Timing:     pending or stale; current=False"
    }
    Write-Host "  RBF:        $(if ($rbf) { "$($rbf.FullName) ($($rbf.Length) bytes)" } else { 'missing' }); current=$rbfIsCurrent"
    Write-Host "  Deployable: $ready"
}

$structuralTimingFailure = -not $mapIsCurrent -or -not $fitIsCurrent -or
    -not $staIsCurrent -or $timingRows.Count -eq 0
$coverageFailure = $RequireTimingCoverage -and -not $timingCoverageComplete

if ($RequireMapCurrent -and -not $mapIsCurrent) {
    exit 2
}
if ($RequireTiming -or $RequireReady) {
    if ($structuralTimingFailure -or $coverageFailure) {
        exit 2
    }
    if (-not $timingMet) {
        exit 1
    }
}
if ($RequireReady -and -not $rbfIsCurrent) {
    exit 2
}
