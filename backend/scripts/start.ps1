$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendRoot = Split-Path -Parent $scriptRoot
$binaryPath = Join-Path $backendRoot 'bin\yt-dlp.exe'

if (-not (Test-Path -LiteralPath $binaryPath)) {
    & (Join-Path $scriptRoot 'bootstrap.ps1')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Push-Location $backendRoot
try {
    & node '.\src\index.js'
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
