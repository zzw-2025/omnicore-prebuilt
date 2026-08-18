[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Za-z._-]+$')]
    [string]$Version,

    [ValidateSet('cpu', 'cuda')]
    [string]$Variant = 'cpu',

    [string]$CudaVersion,

    [string]$CudaArchitectures = '75;80;86;89;90',

    [string]$WorkDir,

    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    $WorkDir = Join-Path $scriptRoot '..\.work\windows'
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $scriptRoot '..\dist'
}

function Invoke-Checked {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Command)
    & $Command[0] $Command[1..($Command.Length - 1)]
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $($Command -join ' ')"
    }
}

function Resolve-CleanDirectory([string]$PathValue) {
    $resolved = (Resolve-Path -LiteralPath $PathValue).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "Directory does not exist: $PathValue"
    }
    return $resolved
}

function Copy-Redistributable([string]$Root, [string]$Subdirectory, [string]$Name, [string]$Destination) {
    $candidate = Join-Path (Join-Path $Root 'x64') (Join-Path $Subdirectory $Name)
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Required MSVC redistributable not found: $candidate"
    }
    Copy-Item -LiteralPath $candidate -Destination $Destination
}

function Copy-SingleMatchingFile([string]$Root, [string]$Pattern, [string]$Destination) {
    $matches = @(Get-ChildItem -LiteralPath $Root -Filter $Pattern -File)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one $Pattern in $Root, found $($matches.Count)"
    }
    Copy-Item -LiteralPath $matches[0].FullName -Destination $Destination
    return $matches[0].Name
}

function New-PortableZipArchive(
    [string]$SourceDirectory,
    [string]$DestinationPath
) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $sourceRoot = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\')
    $sourceName = Split-Path -Leaf $sourceRoot
    $archive = [IO.Compression.ZipFile]::Open(
        $DestinationPath,
        [IO.Compression.ZipArchiveMode]::Create
    )
    try {
        foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Sort-Object FullName) {
            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
            $entryName = "$sourceName/$($relative.Replace('\', '/'))"
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $file.FullName,
                $entryName,
                [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
}

$source = Resolve-CleanDirectory $SourceDir
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    throw 'cmake is required'
}
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw 'cl.exe is required; run this script from an x64 Visual Studio developer shell'
}
if ($Variant -eq 'cuda' -and -not (Get-Command nvcc.exe -ErrorAction SilentlyContinue)) {
    throw 'nvcc.exe is required for the CUDA package'
}
if ($Variant -eq 'cuda' -and [string]::IsNullOrWhiteSpace($CudaVersion)) {
    throw '-CudaVersion is required when -Variant cuda is selected'
}

$dirty = (& git -C $source status --porcelain=v1)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect OmniCore checkout: $source"
}
if ($dirty) {
    throw 'OmniCore source checkout is dirty; package only an immutable clean commit'
}
$sourceCommit = (& git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Unable to resolve the OmniCore source commit'
}

$work = [IO.Path]::GetFullPath($WorkDir)
$output = [IO.Path]::GetFullPath($OutputDir)
$workRoot = [IO.Path]::GetPathRoot($work)
if ($work.TrimEnd('\') -eq $workRoot.TrimEnd('\')) {
    throw "WorkDir cannot be a drive root: $work"
}
if ($work.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $source.StartsWith($work + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'WorkDir and SourceDir must not contain one another'
}

$workMarker = Join-Path $work '.omnicore-prebuilt-work-root'
if (Test-Path -LiteralPath $work -PathType Container) {
    if (-not (Test-Path -LiteralPath $workMarker -PathType Leaf)) {
        $existing = @(Get-ChildItem -LiteralPath $work -Force)
        if ($existing.Count -ne 0) {
            throw "WorkDir is non-empty and is not owned by this script: $work"
        }
    }
} else {
    New-Item -ItemType Directory -Force -Path $work | Out-Null
}
if (-not (Test-Path -LiteralPath $workMarker -PathType Leaf)) {
    'Owned by omnicore-prebuilt scripts/build-windows.ps1' |
        Set-Content -LiteralPath $workMarker -Encoding ascii
}

$build = Join-Path $work "build-$Variant"
$stage = Join-Path $work "stage-$Variant\omnicore-runtime"
foreach ($ownedPath in @($build, (Split-Path -Parent $stage))) {
    if (Test-Path -LiteralPath $ownedPath) {
        Remove-Item -LiteralPath $ownedPath -Recurse -Force
    }
}
New-Item -ItemType Directory -Force -Path $build, $stage, $output | Out-Null

$generator = if (Get-Command ninja.exe -ErrorAction SilentlyContinue) { 'Ninja' } else { 'NMake Makefiles' }
$configure = @(
    '-S', $source,
    '-B', $build,
    '-G', $generator,
    '-DCMAKE_BUILD_TYPE=Release',
    '-DBUILD_SHARED_LIBS=OFF',
    '-DGGML_NATIVE=OFF',
    '-DGGML_VULKAN=OFF',
    '-DGGML_METAL=OFF',
    '-DLLAMA_BUILD_TESTS=OFF',
    '-DLLAMA_BUILD_EXAMPLES=OFF',
    '-DLLAMA_BUILD_APP=OFF',
    '-DLLAMA_BUILD_TOOLS=ON',
    '-DLLAMA_BUILD_SERVER=ON',
    '-DLLAMA_BUILD_UI=OFF',
    '-DLLAMA_USE_PREBUILT_UI=OFF'
)
if ($Variant -eq 'cuda') {
    $configure += '-DGGML_CUDA=ON', "-DCMAKE_CUDA_ARCHITECTURES=$CudaArchitectures"
} else {
    $configure += '-DGGML_CUDA=OFF'
}

Invoke-Checked cmake @configure
Invoke-Checked cmake --build $build --config Release --target llama-server

$server = Get-ChildItem -LiteralPath $build -Recurse -Filter llama-server.exe -File |
    Where-Object { $_.FullName -match '[\\/]bin[\\/]' } |
    Select-Object -First 1
if (-not $server) {
    throw 'llama-server.exe was not produced'
}
Copy-Item -LiteralPath $server.FullName -Destination $stage
Copy-Item -LiteralPath (Join-Path $source 'LICENSE') -Destination $stage
Copy-Item -LiteralPath (Join-Path $scriptRoot '..\THIRD_PARTY_NOTICES.md') -Destination $stage

$redistRoot = $env:VCToolsRedistDir
if ([string]::IsNullOrWhiteSpace($redistRoot) -and -not [string]::IsNullOrWhiteSpace($env:VCINSTALLDIR)) {
    $redistBase = Join-Path $env:VCINSTALLDIR 'Redist\MSVC'
    $redistRoot = Get-ChildItem -LiteralPath $redistBase -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if ([string]::IsNullOrWhiteSpace($redistRoot)) {
    throw 'MSVC redistributables were not found; install the x64 Visual C++ runtime components'
}
Copy-Redistributable $redistRoot 'Microsoft.VC143.CRT' 'msvcp140.dll' $stage
Copy-Redistributable $redistRoot 'Microsoft.VC143.CRT' 'vcruntime140.dll' $stage
Copy-Redistributable $redistRoot 'Microsoft.VC143.CRT' 'vcruntime140_1.dll' $stage
Copy-Redistributable $redistRoot 'Microsoft.VC143.OpenMP' 'vcomp140.dll' $stage

$cudaRequiredFiles = @()
if ($Variant -eq 'cuda') {
    if ([string]::IsNullOrWhiteSpace($env:CUDA_PATH)) {
        throw 'CUDA_PATH is not set'
    }
    $cudaBin = Join-Path $env:CUDA_PATH 'bin'
    if (-not (Test-Path -LiteralPath $cudaBin -PathType Container)) {
        throw 'CUDA_PATH does not identify a CUDA toolkit with a bin directory'
    }
    foreach ($pattern in @('cudart64_*.dll', 'cublas64_*.dll', 'cublasLt64_*.dll')) {
        $cudaRequiredFiles += Copy-SingleMatchingFile $cudaBin $pattern $stage
    }
}

$backendId = if ($Variant -eq 'cpu') { 'omnicore-cpu' } else { 'omnicore-cuda' }
$metadata = [ordered]@{
    formatVersion = 1
    backendId = $backendId
    sourceRepository = 'https://github.com/omnimind-ai/OmniCore'
    sourceCommit = $sourceCommit
    platform = 'windows'
    architecture = 'x86_64'
    accelerator = $Variant
    cudaVersion = if ($Variant -eq 'cuda') { $CudaVersion } else { $null }
    cudaArchitectures = if ($Variant -eq 'cuda') { $CudaArchitectures } else { $null }
    cudaRuntimeFiles = $cudaRequiredFiles
    buildSharedLibraries = $false
    portableCpuDispatch = $true
}
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage 'build-metadata.json') -Encoding utf8

& (Join-Path $stage 'llama-server.exe') --version
if ($LASTEXITCODE -ne 0) {
    throw 'Packaged launcher failed the --version smoke test'
}

$suffix = if ($Variant -eq 'cpu') { 'cpu' } else { "cuda-$CudaVersion" }
$assetName = "omnicore-$Version-windows-x86_64-$suffix.zip"
$assetPath = Join-Path $output $assetName
if (Test-Path -LiteralPath $assetPath) {
    Remove-Item -LiteralPath $assetPath -Force
}
$archiveError = $null
for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
        New-PortableZipArchive -SourceDirectory $stage -DestinationPath $assetPath
        $archiveError = $null
        break
    } catch {
        $archiveError = $_
        if (Test-Path -LiteralPath $assetPath) {
            Remove-Item -LiteralPath $assetPath -Force
        }
        Start-Sleep -Milliseconds (500 * $attempt)
    }
}
if ($archiveError) {
    throw $archiveError
}
$zip = [IO.Compression.ZipFile]::OpenRead($assetPath)
try {
    $invalidEntries = @($zip.Entries | Where-Object { $_.FullName.Contains('\') })
    if ($invalidEntries.Count -ne 0) {
        throw "ZIP entry paths must use forward slashes: $($invalidEntries[0].FullName)"
    }
} finally {
    $zip.Dispose()
}
$digest = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$digest  $assetName" | Set-Content -LiteralPath "$assetPath.sha256" -Encoding ascii

$verifyRoot = Join-Path $work "verify-$Variant"
if (Test-Path -LiteralPath $verifyRoot) {
    Remove-Item -LiteralPath $verifyRoot -Recurse -Force
}
Expand-Archive -LiteralPath $assetPath -DestinationPath $verifyRoot
$verifyBin = Join-Path $verifyRoot 'omnicore-runtime\llama-server.exe'
$requiredFiles = @(
    'llama-server.exe',
    'msvcp140.dll',
    'vcomp140.dll',
    'vcruntime140.dll',
    'vcruntime140_1.dll',
    'LICENSE',
    'THIRD_PARTY_NOTICES.md',
    'build-metadata.json'
) + $cudaRequiredFiles
foreach ($required in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $verifyBin) $required) -PathType Leaf)) {
        throw "Packaged archive is missing required file: $required"
    }
}
& $verifyBin --version
if ($LASTEXITCODE -ne 0) {
    throw 'Extracted launcher failed the --version smoke test'
}

[ordered]@{
    backendId = $backendId
    asset = $assetPath
    sizeBytes = (Get-Item -LiteralPath $assetPath).Length
    sha256 = $digest
    sourceCommit = $sourceCommit
} | ConvertTo-Json
