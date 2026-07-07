#Requires -Version 5.1
<#
.SYNOPSIS
  Build Glue NSIS installer(s) for Windows amd64 and/or arm64.

.EXAMPLE
  .\build-installer.ps1
  .\build-installer.ps1 -Version 0.1.1
  .\build-installer.ps1 -Arch arm64
  .\build-installer.ps1 -Arch amd64,arm64 -Version 0.1.1
#>
param(
    [ValidateSet('amd64', 'arm64')]
    [string[]]$Arch = @('amd64', 'arm64'),

    [string]$Version = '',
    [string]$GlueExe = '',
    [string]$ShimExe = '',
    [string]$ShimReleaseUrl = '',
    [string]$DepsBase = $(if ($env:GLUE_DEPS_BASE) { $env:GLUE_DEPS_BASE.TrimEnd('/') } else { 'https://gluestick.sh/install' }),
    [switch]$SkipBuildGlue,
    [switch]$SkipSha256
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$installerDir = $PSScriptRoot
$repoRoot = Split-Path $installerDir -Parent

function Get-DefaultVersion {
    $versionGo = Join-Path $repoRoot 'version\version.go'
    if (-not (Test-Path -LiteralPath $versionGo)) { return '0.0.0-dev' }
    $content = Get-Content -LiteralPath $versionGo -Raw
    if ($content -match 'Version\s*=\s*"([^"]+)"') { return $Matches[1] }
    return '0.0.0-dev'
}

function Find-Makensis {
    $candidates = @(
        "${env:ProgramFiles(x86)}\NSIS\makensis.exe",
        "$env:ProgramFiles\NSIS\makensis.exe",
        "${env:ProgramFiles(x86)}\NSIS\Bin\makensis.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    throw @"
NSIS not found. Install it first, for example:
  choco install nsis -y
"@
}

function Normalize-Sha256Hex {
    param([string]$Value)
    if (-not $Value) { return '' }
    $Value = $Value.Trim().ToLowerInvariant() -replace '^sha256:', ''
    if ($Value -match '^[0-9a-f]{64}$') { return $Value }
    return ''
}

function Test-FileSha256 {
    param([string]$Path, [string]$Expected)
    $expectedNorm = Normalize-Sha256Hex $Expected
    if (-not $expectedNorm) { return }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expectedNorm) {
        throw "SHA256 mismatch for $(Split-Path -Leaf $Path): expected $expectedNorm got $actual"
    }
}

function Prepare-Payload {
    param(
        [string]$TargetArch,
        [string]$GluePath,
        [string]$ShimPath,
        [string]$DepsRoot
    )

    $outputDir = Join-Path $installerDir "payload\$TargetArch"
    $manifestUrl = "$DepsRoot/deps/manifest.json"
    Write-Host "Fetching manifest: $manifestUrl"
    $manifest = (Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing).Content | ConvertFrom-Json
    $archManifest = $manifest.architectures.$TargetArch
    if (-not $archManifest) {
        throw "No dependency manifest for architecture: $TargetArch"
    }

    if (Test-Path -LiteralPath $outputDir) {
        Remove-Item -LiteralPath $outputDir -Recurse -Force
    }
    $binDir = Join-Path $outputDir 'bin'
    $null = New-Item -ItemType Directory -Force -Path $binDir

    Write-Host "Copying glue.exe and shim.exe -> $outputDir"
    Copy-Item -LiteralPath $GluePath -Destination (Join-Path $outputDir 'glue.exe') -Force
    Copy-Item -LiteralPath $ShimPath -Destination (Join-Path $outputDir 'shim.exe') -Force

    $tempDir = Join-Path $env:TEMP "glue-payload-$TargetArch"
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
    $null = New-Item -ItemType Directory -Force -Path $tempDir

    try {
        foreach ($asset in $archManifest.files) {
            $destPath = Join-Path $outputDir ($asset.dest -replace '/', '\')
            $tempFile = Join-Path $tempDir $asset.file
            $sourceUrl = "$DepsRoot/deps/$TargetArch/$($asset.file)"

            Write-Host "  download $sourceUrl"
            Invoke-WebRequest -Uri $sourceUrl -OutFile $tempFile -UseBasicParsing
            Test-FileSha256 -Path $tempFile -Expected $asset.sha256

            if ($asset.extract) {
                $destPath = Join-Path $binDir $asset.file
            }
            $destParent = Split-Path -Parent $destPath
            if ($destParent) {
                $null = New-Item -ItemType Directory -Force -Path $destParent
            }
            Move-Item -LiteralPath $tempFile -Destination $destPath -Force
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $sevenZ = Join-Path $binDir '7z.exe'
    if (-not (Test-Path -LiteralPath $sevenZ)) {
        throw "7z.exe missing in payload"
    }

    Write-Host "Payload ready: $outputDir"
}

function Ensure-GlueExe {
    param(
        [string]$TargetArch,
        [string]$Path,
        [string]$Ver,
        [switch]$SkipBuild
    )
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $default = Join-Path $repoRoot "glue-windows-$TargetArch.exe"
    if (-not $SkipBuild -or -not (Test-Path -LiteralPath $default)) {
        if ($SkipBuild) {
            throw "Glue binary not found: $default (pass -GlueExe or drop -SkipBuildGlue)"
        }
        Write-Host "Building glue.exe ($TargetArch)..." -ForegroundColor Cyan
        Push-Location $repoRoot
        try {
            $env:GOOS = 'windows'
            $env:GOARCH = $TargetArch
            $env:CGO_ENABLED = '0'
            $date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $commit = ''
            try { $commit = (git rev-parse HEAD).Substring(0, 12) } catch { }
            go build -trimpath `
                -ldflags "-s -w -X github.com/gluestick-sh/cli/version.Version=$Ver -X github.com/gluestick-sh/cli/version.Commit=$commit -X github.com/gluestick-sh/cli/version.Date=$date" `
                -o $default ./glue
        } finally {
            Pop-Location
            Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
        }
    }
    return (Resolve-Path -LiteralPath $default).Path
}

function Ensure-ShimExe {
    param(
        [string]$TargetArch,
        [string]$Path,
        [string]$ReleaseUrl
    )
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $default = Join-Path $installerDir "shim-windows-$TargetArch.exe"
    if (Test-Path -LiteralPath $default) {
        return (Resolve-Path -LiteralPath $default).Path
    }

    $url = $ReleaseUrl
    if (-not $url) {
        $url = "https://github.com/gluestick-sh/shim/releases/latest/download/shim-windows-$TargetArch.exe"
    }
    Write-Host "Downloading shim.exe ($TargetArch)..." -ForegroundColor Cyan
    Write-Host "  $url" -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $url -OutFile $default -UseBasicParsing
    return (Resolve-Path -LiteralPath $default).Path
}

function Build-InstallerForArch {
    param(
        [string]$TargetArch,
        [string]$Ver,
        [string]$Makensis,
        [string]$GluePathOverride,
        [string]$ShimPathOverride,
        [string]$ShimUrl,
        [string]$DepsRoot,
        [switch]$SkipBuild,
        [switch]$SkipHash
    )

    $gluePath = Ensure-GlueExe -TargetArch $TargetArch -Path $GluePathOverride -Ver $Ver -SkipBuild:$SkipBuild
    $shimPath = Ensure-ShimExe -TargetArch $TargetArch -Path $ShimPathOverride -ReleaseUrl $ShimUrl

    Write-Host "Preparing payload ($TargetArch)..." -ForegroundColor Cyan
    Prepare-Payload -TargetArch $TargetArch -GluePath $gluePath -ShimPath $shimPath -DepsRoot $DepsRoot

    $outputDir = Join-Path $installerDir 'output'
    $null = New-Item -ItemType Directory -Force -Path $outputDir
    $setupName = "GlueSetup-$TargetArch.exe"
    $setupPath = Join-Path $outputDir $setupName

    Write-Host "Compiling $setupName (version $Ver)..." -ForegroundColor Cyan
    Push-Location $installerDir
    try {
        & $Makensis "/DPAYLOAD_VERSION=$Ver" "/DPAYLOAD_ARCH=$TargetArch" "Glue.nsi"
    } finally {
        Pop-Location
    }

    if (-not (Test-Path -LiteralPath $setupPath)) {
        throw "Installer not produced: $setupPath"
    }

    if (-not $SkipHash) {
        $hash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLower()
        Set-Content -LiteralPath "$setupPath.sha256" -Value $hash -NoNewline
        Write-Host "SHA256: $hash" -ForegroundColor DarkGray
    }

    Write-Host "Built: $setupPath" -ForegroundColor Green
    return $setupPath
}

if (-not $Version) {
    $Version = Get-DefaultVersion
}

$makensis = Find-Makensis
$built = @()
$singleArch = ($Arch.Count -eq 1)
foreach ($targetArch in $Arch) {
    if (-not $singleArch) {
        Write-Host ""
        Write-Host "=== $targetArch ===" -ForegroundColor Cyan
    }
    $built += Build-InstallerForArch `
        -TargetArch $targetArch `
        -Ver $Version `
        -Makensis $makensis `
        -GluePathOverride $(if ($singleArch) { $GlueExe } else { '' }) `
        -ShimPathOverride $(if ($singleArch) { $ShimExe } else { '' }) `
        -ShimUrl $ShimReleaseUrl `
        -DepsRoot $DepsBase `
        -SkipBuild:$SkipBuildGlue `
        -SkipHash:$SkipSha256
}

Write-Host ""
Write-Host ("Done. {0} installer(s):" -f $built.Count) -ForegroundColor Green
$built | ForEach-Object { Write-Host "  $_" }
