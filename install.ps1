#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$ZevRepo = "arvandz/zev"
$ZevVersion = if ($env:ZEV_VERSION) { $env:ZEV_VERSION } else { "v0.2.0" }
$ZigVersion = if ($env:ZIG_VERSION) { $env:ZIG_VERSION } else { "0.17.0-dev.1567+f0354179a" }
$InstallDir = if ($env:ZEV_INSTALL_DIR) { $env:ZEV_INSTALL_DIR } else { "$env:LOCALAPPDATA\Programs\zev" }
$BuildDir = Join-Path $env:TEMP "zev-install-$(Get-Random)"

function Write-Info($msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-WarnMsg($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Fail($msg)  { Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }

function Get-Sha256($path) {
    (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
}

function Invoke-Fetch($url, $out) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
    } catch {
        Write-Fail "Download failed: $url`n$($_.Exception.Message)"
    }
    if (-not (Test-Path $out) -or (Get-Item $out).Length -eq 0) {
        Write-Fail "Downloaded file is empty: $url"
    }
}

function Test-ZipFile($path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 4) { return $false }
    return ($bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)
}

function Find-SystemZig {
    $zig = Get-Command zig -ErrorAction SilentlyContinue
    if ($zig) {
        $ver = & zig version 2>$null
        if ($ver -like "0.17.*") {
            return $zig.Source
        }
    }
    return $null
}

Write-Info "Zev installer (Windows)"
Write-Host "   Version: $ZevVersion"
Write-Host "   Install: $InstallDir"
Write-Host ""

Write-WarnMsg "Native Windows support is experimental and less tested than Linux/macOS."
Write-WarnMsg "For the most reliable experience, consider using WSL:"
Write-Host "     wsl --install"
Write-Host "     wsl curl -fsSL https://raw.githubusercontent.com/$ZevRepo/main/install.sh | bash"
Write-Host ""
$continue = Read-Host "Continue with native Windows install? [y/N]"
if ($continue -ne "y" -and $continue -ne "Y") {
    Write-Host "Aborted. Use WSL for a fully supported install."
    exit 0
}

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

try {
    $zigBin = Find-SystemZig
    if ($zigBin) {
        Write-Ok "Found compatible system Zig: $zigBin"
    } else {
        Write-Info "Downloading Zig $ZigVersion for Windows x86_64..."
        $zigUrl = "https://ziglang.org/builds/zig-x86_64-windows-$ZigVersion.zip"
        $zigZip = Join-Path $BuildDir "zig.zip"
        Invoke-Fetch $zigUrl $zigZip

        if (-not (Test-ZipFile $zigZip)) {
            Write-Fail "Downloaded file is not a valid ZIP archive.`nThis Zig nightly may have been pruned from ziglang.org.`nCheck https://ziglang.org/download/ for a current build and set `$env:ZIG_VERSION."
        }
        Write-Ok "Downloaded and verified Zig archive"

        Write-Info "Extracting Zig..."
        Expand-Archive -Path $zigZip -DestinationPath $BuildDir -Force
        $zigBin = Get-ChildItem -Path $BuildDir -Filter "zig.exe" -Recurse | Select-Object -First 1 -ExpandProperty FullName
        if (-not $zigBin) { Write-Fail "Could not locate zig.exe after extraction" }
        Write-Ok "Zig ready: $(& $zigBin version)"
    }

    $srcDir = Join-Path $BuildDir "zev-src"
    if ((Test-Path ".\build.zig") -and (Test-Path ".\src")) {
        Write-Info "Building from local source in $(Get-Location)"
        $srcDir = (Get-Location).Path
    } else {
        Write-Info "Downloading Zev $ZevVersion source..."
        $srcUrl = "https://github.com/$ZevRepo/archive/refs/tags/$ZevVersion.zip"
        $srcZip = Join-Path $BuildDir "zev-src.zip"
        Invoke-Fetch $srcUrl $srcZip

        if (-not (Test-ZipFile $srcZip)) {
            Write-Fail "Downloaded source is not a valid ZIP archive.`nCheck that $ZevVersion exists at github.com/$ZevRepo/releases"
        }
        Write-Ok "Downloaded and verified source archive"

        Expand-Archive -Path $srcZip -DestinationPath $BuildDir -Force
        $extracted = Get-ChildItem -Path $BuildDir -Directory | Where-Object { $_.Name -like "zev-*" } | Select-Object -First 1
        if (-not $extracted) { Write-Fail "Could not find extracted source directory" }
        $srcDir = $extracted.FullName
    }

    Write-Info "Building Zev (ReleaseSafe)..."
    Push-Location $srcDir
    try {
        & $zigBin build -Doptimize=ReleaseSafe
        if ($LASTEXITCODE -ne 0) { Write-Fail "zig build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    $builtExe = Join-Path $srcDir "zig-out\bin\zev.exe"
    if (-not (Test-Path $builtExe)) { Write-Fail "Build did not produce zig-out\bin\zev.exe" }
    Write-Ok "Build complete"

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item -Path $builtExe -Destination (Join-Path $InstallDir "zev.exe") -Force
    Write-Ok "Installed to $InstallDir\zev.exe"

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$InstallDir*") {
        Write-Info "Adding $InstallDir to user PATH"
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
        Write-WarnMsg "Restart your terminal for PATH changes to take effect"
    }

    Write-Host ""
    Write-Info "Verifying installation"
    & $builtExe version

    Write-Host ""
    Write-Ok "Zev installed successfully"
    Write-Host ""
    Write-Host "Quick start (after restarting your terminal):"
    Write-Host "  zev init"
    Write-Host "  zev config set user.name 'Your Name'"
    Write-Host "  zev add <file>"
    Write-Host "  zev commit 'Initial commit'"
    Write-Host ""
} finally {
    Remove-Item -Path $BuildDir -Recurse -Force -ErrorAction SilentlyContinue
}