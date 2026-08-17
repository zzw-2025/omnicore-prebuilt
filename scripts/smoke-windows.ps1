[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [string]$ModelPath,

    [string]$ModelUrl = 'https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories15M-q4_0.gguf',

    [string]$ModelSha256 = '66967fbece6dbe97886593fdbb73589584927e29119ec31f08090732d1861739',

    [switch]$RequireCuda,

    [int]$Port = 18081
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-File([string]$PathValue, [string]$Description) {
    $resolved = (Resolve-Path -LiteralPath $PathValue -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Description does not exist: $PathValue"
    }
    return $resolved
}

function Wait-Server([int]$ServerPort, [System.Diagnostics.Process]$Process) {
    $deadline = (Get-Date).AddSeconds(45)
    do {
        Start-Sleep -Milliseconds 500
        if ($Process.HasExited) {
            throw "Packaged server exited before readiness with code $($Process.ExitCode)"
        }
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$ServerPort/health" -TimeoutSec 2
        } catch {
            $health = $null
        }
    } until ($health -or (Get-Date) -gt $deadline)
    if (-not $health -or $health.status -ne 'ok') {
        throw 'Packaged server did not report healthy status'
    }
}

$archive = Resolve-File $ArchivePath 'Archive'
$smokeRoot = Join-Path ([IO.Path]::GetTempPath()) "omnicore-smoke-$([Guid]::NewGuid().ToString('N'))"
$extractRoot = Join-Path $smokeRoot 'runtime'
$stdout = Join-Path $smokeRoot 'server.stdout.log'
$stderr = Join-Path $smokeRoot 'server.stderr.log'
$serverProcess = $null

try {
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $extractRoot
    $servers = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter llama-server.exe -File)
    if ($servers.Count -ne 1) {
        throw "Expected exactly one llama-server.exe, found $($servers.Count)"
    }
    $server = $servers[0].FullName

    & $server --version
    if ($LASTEXITCODE -ne 0) {
        throw 'Packaged server failed --version'
    }
    if ($RequireCuda) {
        $devices = (& $server --list-devices 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $devices -notmatch 'CUDA') {
            throw 'Packaged CUDA server did not report a CUDA device'
        }
    }

    if ([string]::IsNullOrWhiteSpace($ModelPath)) {
        $ModelPath = Join-Path $smokeRoot 'stories15M-q4_0.gguf'
        Invoke-WebRequest -Uri $ModelUrl -OutFile $ModelPath -UseBasicParsing -TimeoutSec 300
    }
    $model = Resolve-File $ModelPath 'Smoke model'
    $actualModelSha256 = (Get-FileHash -LiteralPath $model -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualModelSha256 -ne $ModelSha256) {
        throw "Smoke model SHA-256 mismatch: expected $ModelSha256, got $actualModelSha256"
    }

    $arguments = @('-m', $model, '--host', '127.0.0.1', '--port', "$Port", '-c', '512', '--no-webui')
    if ($RequireCuda) {
        $arguments += '-ngl', '999'
    }
    $serverProcess = Start-Process -FilePath $server -ArgumentList $arguments `
        -WorkingDirectory (Split-Path -Parent $server) -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    Wait-Server $Port $serverProcess

    $payload = @{
        model = 'stories15M'
        messages = @(@{ role = 'user'; content = 'Return a short test response.' })
        max_tokens = 8
        temperature = 0
    } | ConvertTo-Json -Depth 6
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" `
        -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 60
    if (-not $response.choices -or -not $response.choices[0].message) {
        throw 'Packaged server returned no chat completion choice'
    }
    if (-not $response.usage -or [int]$response.usage.completion_tokens -le 0) {
        throw 'Packaged server returned no completion tokens'
    }

    $streamPayload = @{
        model = 'stories15M'
        messages = @(@{ role = 'user'; content = 'Return a short streamed response.' })
        max_tokens = 4
        temperature = 0
        stream = $true
    } | ConvertTo-Json -Depth 6
    $streamResponse = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/v1/chat/completions" `
        -Method Post -ContentType 'application/json' -Body $streamPayload `
        -UseBasicParsing -TimeoutSec 60
    if ($streamResponse.Content -notmatch '(?m)^data: \{' -or
        $streamResponse.Content -notmatch '(?m)^data: \[DONE\]') {
        throw 'Packaged server returned an invalid streaming chat response'
    }
    [ordered]@{
        ok = $true
        archive = $archive
        cuda = [bool]$RequireCuda
        stream = $true
        promptTokens = $response.usage.prompt_tokens
        completionTokens = $response.usage.completion_tokens
    } | ConvertTo-Json
} finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force
        $serverProcess.WaitForExit()
    }
    if (Test-Path -LiteralPath $stderr) {
        Get-Content -LiteralPath $stderr -Tail 80
    }
    if (Test-Path -LiteralPath $smokeRoot) {
        Remove-Item -LiteralPath $smokeRoot -Recurse -Force
    }
}
