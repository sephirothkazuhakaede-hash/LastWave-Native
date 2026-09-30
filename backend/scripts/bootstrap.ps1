param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendRoot = Split-Path -Parent $scriptRoot
$binRoot = Join-Path $backendRoot 'bin'
$binaryPath = Join-Path $binRoot 'yt-dlp.exe'

New-Item -ItemType Directory -Force -Path $binRoot | Out-Null

if ((Test-Path -LiteralPath $binaryPath) -and -not $Force) {
    Write-Host "yt-dlp is already installed: $binaryPath"
    & $binaryPath --version
    exit $LASTEXITCODE
}

$downloadPath = Join-Path $binRoot 'yt-dlp.exe.tmp'
$sumPath = Join-Path $binRoot 'SHA2-256SUMS.tmp'
$releaseRoot = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download'

try {
    Write-Host 'Downloading the current stable yt-dlp Windows binary...'
    Invoke-WebRequest -Uri "$releaseRoot/yt-dlp.exe" -OutFile $downloadPath -Headers @{ 'User-Agent' = 'CapyFlow-Backend-Bootstrap' }
    Invoke-WebRequest -Uri "$releaseRoot/SHA2-256SUMS" -OutFile $sumPath -Headers @{ 'User-Agent' = 'CapyFlow-Backend-Bootstrap' }

    $sumLine = Get-Content -LiteralPath $sumPath | Where-Object { $_ -match '(?i)^[0-9a-f]{64}\s+\*?yt-dlp\.exe$' } | Select-Object -First 1
    if (-not $sumLine) {
        throw 'The official checksum list did not contain yt-dlp.exe.'
    }

    $expected = ($sumLine -split '\s+')[0].ToUpperInvariant()
    # Windows PowerShell normally includes Get-FileHash, but some stripped-down
    # installations do not. Use the .NET implementation so bootstrap remains
    # portable across ordinary Windows and recovery-style shells.
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($downloadPath)
    try {
        $actualBytes = $sha256.ComputeHash($stream)
        $actual = ([System.BitConverter]::ToString($actualBytes)).Replace('-', '').ToUpperInvariant()
    }
    finally {
        $stream.Dispose()
        $sha256.Dispose()
    }
    if ($actual -ne $expected) {
        throw "yt-dlp checksum mismatch. Expected $expected but received $actual."
    }

    Move-Item -LiteralPath $downloadPath -Destination $binaryPath -Force
    Write-Host "Verified yt-dlp installed at $binaryPath"
    & $binaryPath --version
    exit $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sumPath -Force -ErrorAction SilentlyContinue
}
