param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactZip
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LocalRoot = Join-Path $RepoRoot "Vendor\MPVKit\Local"
$XcframeworkRoot = Join-Path $LocalRoot "xcframework"
$TempRoot = Join-Path $env:TEMP ("kyomiru-mpv-" + [guid]::NewGuid().ToString("N"))

$required = @(
    "Libmpv.xcframework",
    "Libcrypto.xcframework",
    "Libssl.xcframework",
    "gmp.xcframework",
    "nettle.xcframework",
    "hogweed.xcframework",
    "gnutls.xcframework",
    "Libunibreak.xcframework",
    "Libfreetype.xcframework",
    "Libfribidi.xcframework",
    "Libharfbuzz.xcframework",
    "Libass.xcframework",
    "Libbluray.xcframework",
    "Libuavs3d.xcframework",
    "Libdovi.xcframework",
    "MoltenVK.xcframework",
    "Libshaderc_combined.xcframework",
    "lcms2.xcframework",
    "Libplacebo.xcframework",
    "Libdav1d.xcframework",
    "Libuchardet.xcframework"
)

if (-not (Test-Path -LiteralPath $ArtifactZip)) {
    throw "Artifact zip not found: $ArtifactZip"
}

if (Test-Path -LiteralPath $TempRoot) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $TempRoot | Out-Null

try {
    Expand-Archive -LiteralPath $ArtifactZip -DestinationPath $TempRoot -Force

    $extractedLocal = Join-Path $TempRoot "Local"
    if (-not (Test-Path -LiteralPath $extractedLocal)) {
        throw "Expected a top-level 'Local' folder in the artifact."
    }

    if (Test-Path -LiteralPath $LocalRoot) {
        Remove-Item -LiteralPath $LocalRoot -Recurse -Force
    }

    Move-Item -LiteralPath $extractedLocal -Destination $LocalRoot

    if (-not (Test-Path -LiteralPath $XcframeworkRoot)) {
        throw "Missing xcframework directory after install: $XcframeworkRoot"
    }

    $missing = @()
    foreach ($name in $required) {
        $path = Join-Path $XcframeworkRoot $name
        if (-not (Test-Path -LiteralPath $path)) {
            $missing += $name
        }
    }

    if ($missing.Count -gt 0) {
        throw ("Installed artifact is incomplete. Missing: " + ($missing -join ", "))
    }

    Write-Host "Installed Local MPV frameworks into $LocalRoot"
    Write-Host "Next step: git add Vendor/MPVKit/Local"
}
finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
