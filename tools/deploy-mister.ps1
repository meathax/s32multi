[CmdletBinding()]
param(
    [string]$MisterHost = $env:S32_MISTER_HOST,
    [string]$Revision = "s32",
    [string]$CoreName = "s32",
    [string]$RbfPath,
    [string]$MraPath,
    [string]$ReportRoot,
    [switch]$SkipMra
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "sha256.ps1")
$repoRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
if (-not $MisterHost) {
    throw "Pass -MisterHost root@<MISTER-IP> or set S32_MISTER_HOST."
}
if ($MisterHost.StartsWith("-") -or $MisterHost -notmatch '^(?:[A-Za-z0-9_.-]+@)?[A-Za-z0-9_.-]+$') {
    throw "MisterHost must be a host name/IP, optionally prefixed by a user name."
}
foreach ($pair in @(
    [pscustomobject]@{ Name = "Revision"; Value = $Revision },
    [pscustomobject]@{ Name = "CoreName"; Value = $CoreName }
)) {
    if ($pair.Value -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "$($pair.Name) may contain only letters, numbers, dot, underscore, and hyphen."
    }
}

if (-not $RbfPath) {
    $RbfPath = Join-Path $repoRoot "releases\$CoreName.rbf"
}
if (-not $ReportRoot) {
    $ReportRoot = $repoRoot
}
$ReportRoot = (Resolve-Path -LiteralPath $ReportRoot).Path
if (-not $MraPath) {
    $MraPath = Join-Path $repoRoot "releases\Holosseum (US, Rev A).mra"
}

foreach ($command in @("ssh", "scp")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command was not found. Install the Windows OpenSSH client first."
    }
}

# Deployment consumes the same release artifacts as the Quartus flow.  Share
# the machine-wide gate so a deployment cannot race an assembler/staging step
# in another worktree or profile.
$mutex = [Threading.Mutex]::new($false, "Global\SegaS32QuartusBuild")
$acquired = $false
$remoteConnected = $false
$remoteRbfTemp = $null
$remoteMraTemp = $null

$sshOptions = @(
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=2"
)

function Invoke-SshChecked([string]$Command, [string]$Failure) {
    $lines = @(& ssh @sshOptions $MisterHost $Command 2>&1)
    $nativeResult = $LASTEXITCODE
    if ($nativeResult -ne 0) {
        if ($lines.Count -gt 0) {
            $lines | ForEach-Object { Write-Host $_ }
        }
        throw "$Failure (ssh exit $nativeResult)"
    }
    return $lines
}

function Invoke-ScpChecked([string]$LocalPath, [string]$RemotePath, [string]$Failure) {
    $target = "$($MisterHost):$RemotePath"
    $lines = @(& scp @sshOptions $LocalPath $target 2>&1)
    $nativeResult = $LASTEXITCODE
    if ($lines.Count -gt 0) {
        $lines | ForEach-Object { Write-Host $_ }
    }
    if ($nativeResult -ne 0) {
        throw "$Failure (scp exit $nativeResult)"
    }
}

function Get-RemoteSha256([string]$Path, [string]$Failure) {
    $lines = Invoke-SshChecked "sha256sum '$Path'" $Failure
    $line = $lines | Select-Object -First 1
    $hash = if ($line) { ([string]$line -split '\s+')[0].ToLowerInvariant() } else { "" }
    if ($hash -notmatch '^[0-9a-f]{64}$') {
        throw "$Failure (invalid sha256sum output)"
    }
    return $hash
}

try {
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        throw "A Quartus build or another deployment is active on this machine."
    }

    $reportScript = Join-Path $repoRoot "tools\report-quartus.ps1"
    $powerShellExe = (Get-Process -Id $PID).Path
    Write-Host "Checking fitter, timing, input fingerprint, and RBF release gates..."
    $reportArguments = @(
        "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", $reportScript,
        "-ProjectRoot", $ReportRoot,
        "-Revision", $Revision,
        "-RequireReady"
    )
    if (-not [string]::IsNullOrWhiteSpace($env:QUARTUS_ROOT)) {
        $reportArguments += @("-QuartusRoot", $env:QUARTUS_ROOT)
    }
    & $powerShellExe @reportArguments
    $reportResult = $LASTEXITCODE
    if ($reportResult -ne 0) {
        throw "Quartus reports do not qualify this build for deployment (exit $reportResult)."
    }

    $resolvedRbf = (Resolve-Path -LiteralPath $RbfPath).Path
    $rbf = Get-Item -LiteralPath $resolvedRbf -ErrorAction Stop
    if ($rbf.PSIsContainer -or $rbf.Length -le 0) {
        throw "Selected RBF is empty: $resolvedRbf"
    }
    $localRbfHash = Get-S32FileSha256 -LiteralPath $resolvedRbf
    $qualifiedRbf = Join-Path $ReportRoot "output_files\$Revision.rbf"
    $qualified = Get-Item -LiteralPath $qualifiedRbf -ErrorAction Stop
    if ($qualified.Length -le 0) {
        throw "The report-qualified RBF is empty: $qualifiedRbf"
    }
    $qualifiedRbfHash = Get-S32FileSha256 -LiteralPath $qualifiedRbf
    if ($localRbfHash -ne $qualifiedRbfHash) {
        throw "Selected RBF does not match the RBF qualified by the Quartus reports."
    }

    $resolvedMra = $null
    $localMraHash = $null
    $mraLeaf = $null
    if (-not $SkipMra) {
        $resolvedMra = (Resolve-Path -LiteralPath $MraPath).Path
        $mraLeaf = [IO.Path]::GetFileName($resolvedMra)
        if ($mraLeaf.Contains("'") -or $mraLeaf -match '[\r\n]') {
            throw "MRA filenames containing apostrophes or line breaks are not supported."
        }
        [xml]$mraXml = [IO.File]::ReadAllText($resolvedMra)
        $rbfNodes = @($mraXml.SelectNodes("/misterromdescription/rbf"))
        if ($rbfNodes.Count -ne 1) {
            throw "MRA must contain exactly one /misterromdescription/rbf element."
        }
        $mraCore = $rbfNodes[0].InnerText.Trim()
        if ($mraCore -cne $CoreName) {
            throw "MRA targets RBF '$mraCore', but this deployment targets '$CoreName'."
        }
        $localMraHash = Get-S32FileSha256 -LiteralPath $resolvedMra
    }

    $remoteCoreDir = "/media/fat/_Arcade/cores"
    $remoteArcadeDir = "/media/fat/_Arcade"
    $remoteRbfFinal = "$remoteCoreDir/$CoreName.rbf"
    $remoteMraFinal = if ($mraLeaf) { "$remoteArcadeDir/$mraLeaf" } else { $null }
    $uploadId = [Guid]::NewGuid().ToString("N")
    $remoteRbfTemp = "$remoteCoreDir/.$CoreName.rbf.upload-$uploadId"
    $remoteMraTemp = if ($mraLeaf) { "$remoteArcadeDir/.$CoreName.mra.upload-$uploadId" } else { $null }

    Write-Host "Checking MiSTer connection..."
    [void](Invoke-SshChecked "mkdir -p '$remoteCoreDir' '$remoteArcadeDir'" "Could not connect to $MisterHost or create the target directories")
    $remoteConnected = $true

    Write-Host "Uploading and verifying $CoreName.rbf..."
    Invoke-ScpChecked $resolvedRbf $remoteRbfTemp "RBF upload failed"
    $remoteRbfHash = Get-RemoteSha256 $remoteRbfTemp "Could not hash the uploaded RBF"
    if ($remoteRbfHash -ne $localRbfHash) {
        throw "RBF hash mismatch: local $localRbfHash, remote $remoteRbfHash."
    }

    if ($resolvedMra) {
        Write-Host "Uploading and verifying $mraLeaf..."
        Invoke-ScpChecked $resolvedMra $remoteMraTemp "MRA upload failed"
        $remoteMraHash = Get-RemoteSha256 $remoteMraTemp "Could not hash the uploaded MRA"
        if ($remoteMraHash -ne $localMraHash) {
            throw "MRA hash mismatch: local $localMraHash, remote $remoteMraHash."
        }
    }

    # Activate the core first. The old MRA remains usable until its matching
    # replacement has also uploaded and verified.
    [void](Invoke-SshChecked "mv -f '$remoteRbfTemp' '$remoteRbfFinal'" "Could not activate the verified RBF")
    $remoteRbfTemp = $null
    if ($resolvedMra) {
        [void](Invoke-SshChecked "mv -f '$remoteMraTemp' '$remoteMraFinal'" "Could not activate the verified MRA")
        $remoteMraTemp = $null
    }
    [void](Invoke-SshChecked "sync" "Could not flush the MiSTer filesystem")

    $finalRbfHash = Get-RemoteSha256 $remoteRbfFinal "Could not verify the active RBF"
    if ($finalRbfHash -ne $localRbfHash) {
        throw "Active RBF hash changed after activation."
    }
    if ($resolvedMra) {
        $finalMraHash = Get-RemoteSha256 $remoteMraFinal "Could not verify the active MRA"
        if ($finalMraHash -ne $localMraHash) {
            throw "Active MRA hash changed after activation."
        }
    }

    Write-Host "DEPLOYED: $remoteRbfFinal"
    Write-Host "SHA256:  $localRbfHash"
    if ($resolvedMra) {
        Write-Host "MRA:     $remoteMraFinal"
    }
    Write-Host "ROM files were not copied or modified."
}
finally {
    if ($remoteConnected -and ($remoteRbfTemp -or $remoteMraTemp)) {
        $cleanup = @($remoteRbfTemp, $remoteMraTemp) | Where-Object { $_ }
        $quoted = ($cleanup | ForEach-Object { "'$_'" }) -join " "
        & ssh @sshOptions $MisterHost "rm -f $quoted" 2>&1 | Out-Null
    }
    if ($acquired) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
