function Get-S32FileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    $stream = [IO.File]::OpenRead($LiteralPath)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}
