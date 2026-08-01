<#
.SYNOPSIS
    Build Name Your Summons into a .pak (and a distributable .zip).

.DESCRIPTION
    Wraps Norbyte's LSLib CLI (divine.exe) to pack the mod, exactly like the
    BG3 Modder's Multitool does under the hood - but from one command with no
    GUI. A pinned LSLib release is downloaded into .tools/ on first run and
    reused afterwards; nothing about the toolchain is committed to the repo.

    Output lands in build/:
        build/NameYourSummons.pak            <- drop into the game's Mods dir
        build/NameYourSummons-<version>.zip  <- Nexus / mod.io upload

    Requires the .NET 8 Desktop Runtime (divine.exe is a .NET app). If it is
    missing the script tells you where to get it.

.EXAMPLE
    ./build.ps1
        Build the .pak and .zip into build/.

.EXAMPLE
    ./build.ps1 -Clean
        Wipe build/ first, then build.
#>
[CmdletBinding()]
param(
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pinned LSLib release. Bump this (and check the CLI still accepts the same
# flags) when you want a newer packer; divine picks the correct BG3 package
# version and compression from '--game bg3', so we do not spell those out.
$LSLibVersion = 'v1.20.4'
$LSLibAsset   = "ExportTool-$LSLibVersion.zip"
$LSLibUrl     = "https://github.com/Norbyte/lslib/releases/download/$LSLibVersion/$LSLibAsset"

$Root      = $PSScriptRoot
$ModName   = 'NameYourSummons'
$SourceDir = Join-Path $Root $ModName
$BuildDir  = Join-Path $Root 'build'
$ToolsDir  = Join-Path $Root '.tools'
$LSLibDir  = Join-Path $ToolsDir "lslib-$LSLibVersion"

function Get-ModVersion {
    # Decode the mod's packed Version64 so the zip is self-identifying. The
    # top-level <version> node is the LSX file-format version, not the mod's.
    $meta = Join-Path $SourceDir "Mods/$ModName/meta.lsx"
    try {
        $node = Select-Xml -Path $meta -XPath "//attribute[@id='Version64']" | Select-Object -First 1
        $packed   = [int64]$node.Node.value
        $major    = ($packed -shr 55) -band 0x7f
        $minor    = ($packed -shr 47) -band 0xff
        $revision = ($packed -shr 31) -band 0xffff
        $build    =  $packed -band 0x7fffffff
        return "$major.$minor.$revision.$build"
    } catch {
        Write-Warning "Could not read version from meta.lsx: $($_.Exception.Message)"
        return '0.0.0.0'
    }
}

function Resolve-Divine {
    # Return the path to divine.exe, downloading the pinned LSLib release on
    # first use. The ExportTool zip lays divine.exe next to its DLLs; the exact
    # subfolder has shifted between releases, so locate it by search.
    $existing = Get-ChildItem -Path $LSLibDir -Filter 'divine.exe' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($existing) { return $existing.FullName }

    Write-Host "Downloading LSLib $LSLibVersion ..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $LSLibDir | Out-Null
    $zip = Join-Path $ToolsDir $LSLibAsset
    Invoke-WebRequest -Uri $LSLibUrl -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $LSLibDir -Force
    Remove-Item $zip -Force

    $divine = Get-ChildItem -Path $LSLibDir -Filter 'divine.exe' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $divine) {
        throw "divine.exe not found in $LSLibAsset after extraction - the release layout may have changed."
    }
    return $divine.FullName
}

if (-not (Test-Path (Join-Path $SourceDir "Mods/$ModName/meta.lsx"))) {
    throw "Source folder '$SourceDir' does not look like the mod (no Mods/$ModName/meta.lsx)."
}

if ($Clean -and (Test-Path $BuildDir)) {
    Remove-Item $BuildDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

$version = Get-ModVersion
$pak     = Join-Path $BuildDir "$ModName.pak"
$zipOut  = Join-Path $BuildDir "$ModName-$version.zip"
$divine  = Resolve-Divine

# divine drops any file whose ABSOLUTE path has a dot-segment (e.g. a .paseo
# worktree) and offers no flag to disable it, silently emitting an empty pak.
# Stage into a dot-free temp dir and pack from there.
$stage = Join-Path ([System.IO.Path]::GetTempPath()) "nys-build-$([Guid]::NewGuid().ToString('N'))"
if ($stage -split '[\\/]' | Where-Object { $_.StartsWith('.') }) {
    throw "Temp path '$stage' contains a dot-segment; divine would exclude all files. Set a TEMP without leading-dot folders."
}

Write-Host "Packing $ModName $version ..." -ForegroundColor Cyan
try {
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -Path (Join-Path $SourceDir '*') -Destination $stage -Recurse -Force

    & $divine --game bg3 --action create-package --source $stage --destination $pak --loglevel warn
    if ($LASTEXITCODE -ne 0) {
        throw "divine.exe failed with exit code $LASTEXITCODE. If it complained about a missing runtime, install the .NET 8 Desktop Runtime: https://dotnet.microsoft.com/download/dotnet/8.0"
    }
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

if ((Get-Item $pak).Length -le 64) {
    throw "Packed .pak is empty ($((Get-Item $pak).Length) bytes) - divine found no files to include."
}

if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path $pak -DestinationPath $zipOut

Write-Host ""
Write-Host "Built:" -ForegroundColor Green
Write-Host "  $pak"
Write-Host "  $zipOut"
