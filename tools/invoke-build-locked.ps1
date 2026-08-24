[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BuildScript,
    [ValidateRange(0, 3600)]
    [int]$WaitSeconds = 0
)

$ErrorActionPreference = "Stop"
$resolvedScript = (Resolve-Path -LiteralPath $BuildScript).Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $resolvedScript) "..")).Path

# Quartus 17 is a machine-wide resource in this workspace.  The databases
# remain per-project, but two fits must never run at the same time: they can
# contend for memory/CPU and make placement comparisons non-reproducible.
# Use a stable machine-wide name rather than a root hash so separate worktrees
# and the universal production profile serializes as well.
$mutexName = "Global\SegaS32QuartusBuild"
$mutex = [Threading.Mutex]::new($false, $mutexName)
$acquired = $false
$buildExitCode = 1
$startedUtc = [DateTime]::UtcNow
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $repoRoot "build-$stamp-$PID.log"
$pidPath = Join-Path $repoRoot ".s32-build.pid"
$token = [Guid]::NewGuid().ToString("N")
$priorHeld = [Environment]::GetEnvironmentVariable("S32_BUILD_LOCK_HELD", "Process")
$priorToken = [Environment]::GetEnvironmentVariable("S32_BUILD_LOCK_TOKEN", "Process")

function Append-Log([string]$Text) {
    [IO.File]::AppendAllText(
        $logPath,
        $Text + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
}

try {
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($WaitSeconds))
    }
    catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        throw "Another Sega System 32 Quartus build is already active on this machine after waiting $WaitSeconds second(s)."
    }

    $gitHead = "unavailable"
    $gitDirty = "unknown"
    try {
        $headText = & git -C $repoRoot rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $headText) {
            $gitHead = ($headText | Select-Object -First 1).Trim()
        }
        $dirtyText = @(& git -C $repoRoot status --porcelain --untracked-files=normal 2>$null)
        if ($LASTEXITCODE -eq 0) {
            $gitDirty = if ($dirtyText.Count -gt 0) { "true" } else { "false" }
        }
    }
    catch {
        $gitHead = "unavailable"
        $gitDirty = "unknown"
    }

    Append-Log "Sega System 32 Quartus build"
    Append-Log "StartedUtc: $($startedUtc.ToString('o'))"
    Append-Log "Host: $env:COMPUTERNAME"
    Append-Log "PowerShellPid: $PID"
    Append-Log "Script: $resolvedScript"
    Append-Log "RepoRoot: $repoRoot"
    Append-Log "Mutex: $mutexName"
    Append-Log "GitHead: $gitHead"
    Append-Log "GitDirty: $gitDirty"
    Append-Log ""

    $pidMetadata = [ordered]@{
        PowerShellPid = $PID
        StartedUtc = $startedUtc.ToString("o")
        Script = $resolvedScript
        RepoRoot = $repoRoot
        Mutex = $mutexName
        LogPath = $logPath
        GitHead = $gitHead
        GitDirty = $gitDirty
    }
    $pidTemp = "$pidPath.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText(
            $pidTemp,
            ([pscustomobject]$pidMetadata | ConvertTo-Json -Depth 3) + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $pidTemp -Destination $pidPath -Force
    }
    finally {
        Remove-Item -LiteralPath $pidTemp -Force -ErrorAction SilentlyContinue
    }

    $env:S32_BUILD_LOCK_HELD = "1"
    $env:S32_BUILD_LOCK_TOKEN = $token
    Write-Host "Build lock acquired. Persistent log: $logPath"

    $commandLine = [char]34 + $resolvedScript + [char]34
    # Windows PowerShell 5.1 wraps native stderr lines as ErrorRecord objects.
    # With the script-wide Stop preference, benign tools such as qsys-script
    # can otherwise abort the wrapper merely by printing an informational line
    # to stderr even when their native exit status is zero. Stream every line
    # explicitly and make the native exit code the sole success authority.
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $env:ComSpec /d /c $commandLine 2>&1 | ForEach-Object {
            $line = $_.ToString()
            Write-Host $line
            Append-Log $line
        }
        $buildExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    Append-Log ""
    Append-Log "FinishedUtc: $([DateTime]::UtcNow.ToString('o'))"
    Append-Log "NativeExitCode: $buildExitCode"
}
catch {
    try {
        Append-Log "FAILED: $($_.Exception.Message)"
        Append-Log "FinishedUtc: $([DateTime]::UtcNow.ToString('o'))"
        Append-Log "NativeExitCode: $buildExitCode"
    }
    catch {
    }
    Write-Error $_
    $buildExitCode = 1
}
finally {
    if ($null -eq $priorHeld) {
        Remove-Item Env:S32_BUILD_LOCK_HELD -ErrorAction SilentlyContinue
    }
    else {
        $env:S32_BUILD_LOCK_HELD = $priorHeld
    }
    if ($null -eq $priorToken) {
        Remove-Item Env:S32_BUILD_LOCK_TOKEN -ErrorAction SilentlyContinue
    }
    else {
        $env:S32_BUILD_LOCK_TOKEN = $priorToken
    }
    if ($acquired) {
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}

exit $buildExitCode
