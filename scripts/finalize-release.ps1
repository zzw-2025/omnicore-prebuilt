[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v[0-9A-Za-z._-]+$')]
    [string]$Tag,

    [Parameter(Mandatory = $true)]
    [ValidateSet('full', 'windows-cpu-preview')]
    [string]$Profile,

    [ValidateSet('none', 'minisign')]
    [string]$SignatureMode = 'none',

    [string]$AssetsDir,

    [string]$Repository = 'zzw-2025/omnicore-prebuilt',

    [string]$MinisignSecretKey,

    [string]$MinisignPublicKey,

    [string]$PublicKeyId,

    [string]$OutputDir,

    [string]$WorkRoot,

    [switch]$Publish,

    [switch]$AllowUnsignedPublish
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $Command $($Arguments -join ' ')"
    }
}

function Resolve-InputFile([string]$PathValue, [string]$Description) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        throw "$Description is required"
    }
    $resolved = (Resolve-Path -LiteralPath $PathValue -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Description does not exist: $PathValue"
    }
    return $resolved
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $scriptRoot '..'))
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    throw 'python is required'
}

if ($Publish -and $SignatureMode -eq 'none' -and -not $AllowUnsignedPublish) {
    throw 'Unsigned publication requires the explicit -AllowUnsignedPublish switch'
}
if ($SignatureMode -eq 'minisign') {
    if (-not (Get-Command minisign -ErrorAction SilentlyContinue)) {
        throw 'minisign is required when -SignatureMode minisign is selected'
    }
    $MinisignSecretKey = Resolve-InputFile $MinisignSecretKey 'Minisign secret key'
    $MinisignPublicKey = Resolve-InputFile $MinisignPublicKey 'Minisign public key'
    if ([string]::IsNullOrWhiteSpace($PublicKeyId)) {
        throw '-PublicKeyId is required when -SignatureMode minisign is selected'
    }
}

$safeTag = $Tag -replace '[^0-9A-Za-z._-]', '-'
$workRoot = if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    Join-Path ([IO.Path]::GetTempPath()) 'omnicore-prebuilt'
} else {
    [IO.Path]::GetFullPath($WorkRoot)
}
$work = Join-Path $workRoot "finalize-$safeTag-$([Guid]::NewGuid().ToString('N'))"
$assetWork = Join-Path $work 'release-assets'
$marker = Join-Path $work '.omnicore-finalize-work-root'
New-Item -ItemType Directory -Force -Path $assetWork | Out-Null
'Owned by scripts/finalize-release.ps1' | Set-Content -LiteralPath $marker -Encoding ascii

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repositoryRoot (Join-Path 'dist\finalized' $safeTag)
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

try {
    if ($Publish) {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            throw 'gh is required for publication'
        }
        $releaseJson = & gh release view $Tag --repo $Repository --json isDraft,isPrerelease
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect Release $Tag in $Repository"
        }
        $release = $releaseJson | ConvertFrom-Json
        if (-not $release.isDraft) {
            throw "Release must be an unpublished draft: $Tag"
        }
        if ($Profile -eq 'windows-cpu-preview' -and -not $release.isPrerelease) {
            throw 'windows-cpu-preview must be marked as a prerelease'
        }
        Invoke-Checked gh release download $Tag --repo $Repository --dir $assetWork
    } else {
        if ([string]::IsNullOrWhiteSpace($AssetsDir)) {
            $AssetsDir = Join-Path $repositoryRoot 'dist'
        }
        $resolvedAssets = (Resolve-Path -LiteralPath $AssetsDir -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $resolvedAssets -PathType Container)) {
            throw "AssetsDir does not exist: $AssetsDir"
        }
        Get-ChildItem -LiteralPath $resolvedAssets -File |
            Where-Object {
                $_.Name -like 'omnicore-*.zip' -or
                $_.Name -like 'omnicore-*.tar.gz' -or
                $_.Name -like 'omnicore-*.sha256'
            } |
            Copy-Item -Destination $assetWork
    }

    $unexpected = @(Get-ChildItem -LiteralPath $assetWork -File | Where-Object {
        $_.Name -notlike 'omnicore-*.zip' -and
        $_.Name -notlike 'omnicore-*.tar.gz' -and
        $_.Name -notlike 'omnicore-*.sha256'
    })
    if ($unexpected.Count -ne 0) {
        throw "Draft contains unexpected pre-finalization asset: $($unexpected[0].Name)"
    }

    Invoke-Checked python (Join-Path $scriptRoot 'validate-release-assets.py') `
        --assets-dir $assetWork --tag $Tag --profile $Profile

    $signatureFiles = @()
    if ($SignatureMode -eq 'minisign') {
        $archives = @(Get-ChildItem -LiteralPath $assetWork -File | Where-Object {
            $_.Name.EndsWith('.zip') -or $_.Name.EndsWith('.tar.gz')
        })
        foreach ($archive in $archives) {
            $signature = "$($archive.FullName).minisig"
            Invoke-Checked minisign -S -s $MinisignSecretKey -m $archive.FullName -x $signature
            Invoke-Checked minisign -V -p $MinisignPublicKey -m $archive.FullName -x $signature
            $signatureFiles += $signature
        }
    }

    $releaseManifest = Join-Path $work 'release-manifest.json'
    $catalog = Join-Path $work 'omniinfer-catalog.json'
    $manifestArguments = @(
        (Join-Path $scriptRoot 'prepare-release-manifest.py'),
        '--assets-dir', $assetWork,
        '--tag', $Tag,
        '--signature-mode', $SignatureMode,
        '--output', $releaseManifest
    )
    if ($SignatureMode -eq 'minisign') {
        $manifestArguments += '--public-key-id', $PublicKeyId
    }
    Invoke-Checked python @manifestArguments
    Invoke-Checked python (Join-Path $scriptRoot 'emit-omniinfer-catalog.py') `
        --manifest $releaseManifest --output $catalog

    Copy-Item -LiteralPath $releaseManifest, $catalog -Destination $OutputDir -Force
    foreach ($signatureFile in $signatureFiles) {
        Copy-Item -LiteralPath $signatureFile -Destination $OutputDir -Force
    }

    if ($Publish) {
        if ($signatureFiles.Count -ne 0) {
            Invoke-Checked gh release upload $Tag @signatureFiles --repo $Repository
        }
        Invoke-Checked gh release upload $Tag $releaseManifest $catalog --repo $Repository
        Invoke-Checked gh release edit $Tag --repo $Repository --draft=false
    }

    [ordered]@{
        ok = $true
        tag = $Tag
        profile = $Profile
        signatureMode = $SignatureMode
        published = [bool]$Publish
        outputDir = $OutputDir
        generatedManifest = (Join-Path $OutputDir 'release-manifest.json')
    } | ConvertTo-Json
} finally {
    if (Test-Path -LiteralPath $work -PathType Container) {
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
            throw "Refusing to remove unowned work directory: $work"
        }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
