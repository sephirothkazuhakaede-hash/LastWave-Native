$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendRoot = Split-Path -Parent $scriptRoot
$cloudflared = (Get-Command cloudflared -ErrorAction Stop).Source
$node = (Get-Command node -ErrorAction Stop).Source

function Publish-TunnelUrl([string]$Url) {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        Write-Warning "GitHub CLI (gh) is not installed. Tunnel works, but CapyFlow discovery cannot update automatically."
        Write-Host "Install once with: winget install --id GitHub.cli"
        return
    }
    & $gh.Source auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "GitHub CLI is not signed in. Run 'gh auth login' once, then restart this launcher."
        return
    }
    $repo = 'sephirothkazuhakaede-hash/LastWave-Native'
    $branch = 'runtime/backend-discovery'
    $path = 'backend.json'
    $payload = @{ url = $Url; updatedAt = [DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $sha = (& $gh.Source api "repos/$repo/contents/$path" -f "ref=$branch" --jq '.sha').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $sha) {
        Write-Warning "Could not read the discovery file from GitHub."
        return
    }
    & $gh.Source api --method PUT "repos/$repo/contents/$path" -f "message=Update active CapyFlow tunnel" -f "content=$encoded" -f "branch=$branch" -f "sha=$sha" --silent
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[CapyFlow] Published tunnel for the iOS app: $Url" -ForegroundColor Green
    } else {
        Write-Warning "Tunnel is live, but publishing its URL to GitHub failed."
    }
}

$backendProcess = $null
$tunnelProcess = $null
Push-Location $backendRoot
try {
    Write-Host "[CapyFlow] Starting backend on port 8787..."
    $backendProcess = Start-Process -FilePath $node -ArgumentList '.\src\index.js' -WorkingDirectory $backendRoot -PassThru -NoNewWindow
    $healthy = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8787/health' -TimeoutSec 1
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) { $healthy = $true; break }
        } catch {}
        if ($backendProcess.HasExited) { throw "CapyFlow backend exited before becoming healthy." }
    }
    if (-not $healthy) { throw "CapyFlow backend did not become healthy on port 8787." }

    Write-Host "[CapyFlow] Starting Cloudflare Quick Tunnel..."
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $cloudflared
    $info.Arguments = 'tunnel --url http://localhost:8787'
    $info.UseShellExecute = $false
    $info.RedirectStandardError = $true
    $info.RedirectStandardOutput = $true
    $info.CreateNoWindow = $true
    $tunnelProcess = New-Object System.Diagnostics.Process
    $tunnelProcess.StartInfo = $info
    [void]$tunnelProcess.Start()

    $published = $false
    while (-not $tunnelProcess.HasExited) {
        $line = $tunnelProcess.StandardError.ReadLine()
        if ($null -eq $line) { Start-Sleep -Milliseconds 50; continue }
        Write-Host $line
        if (-not $published -and $line -match 'https://[a-z0-9-]+\.trycloudflare\.com') {
            $url = $Matches[0]
            Write-Host "[CapyFlow] Public backend: $url" -ForegroundColor Cyan
            Publish-TunnelUrl $url
            $published = $true
        }
    }
    throw "cloudflared exited with code $($tunnelProcess.ExitCode)."
}
finally {
    if ($tunnelProcess -and -not $tunnelProcess.HasExited) { $tunnelProcess.Kill() }
    if ($backendProcess -and -not $backendProcess.HasExited) { $backendProcess.Kill() }
    Pop-Location
}
