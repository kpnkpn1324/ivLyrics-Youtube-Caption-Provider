# ivLyrics YouTube Caption Server - Windows Install Script
# Usage: iwr -useb https://your-url/install.ps1 | iex

$ErrorActionPreference = "Stop"
$ServerDir = "$env:LOCALAPPDATA\ivLyrics\ytcaption-server"
$VersionUrl = "https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/version.json?ts=$(Get-Date -Format yyyyMMddHHmmss)"
$ServerUrl  = "https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/server.py"
$Port = 8080

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  ivLyrics YouTube Caption Server Install" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Check Python ────────────────────────────────────────────────────────────
Write-Host "[1/5] Checking Python..." -ForegroundColor Yellow
$python = $null
foreach ($cmd in @("python", "python3")) {
    try {
        $ver = & $cmd --version 2>&1
        if ($ver -match "Python 3\.") {
            $python = $cmd
            Write-Host "  [OK] $ver found" -ForegroundColor Green
            break
        }
    } catch {}
}

if (-not $python) {
    Write-Host "  Python 3 not found. Installing..." -ForegroundColor Yellow
    try {
        winget install Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
        $python = "python"
        Write-Host "  [OK] Python installed" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] Python auto-install failed. Please install manually from https://python.org" -ForegroundColor Red
        exit 1
    }
}

# ── 2. Check FFmpeg ────────────────────────────────────────────────────────────
Write-Host "[2/5] Checking FFmpeg..." -ForegroundColor Yellow
$ffmpegPath = $null
$ffmpegExe = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($ffmpegExe) {
    $ffmpegPath = Split-Path $ffmpegExe.Path
    Write-Host "  [OK] FFmpeg found: $ffmpegPath" -ForegroundColor Green
} else {
    Write-Host "  FFmpeg not found. Installing..." -ForegroundColor Yellow
    try {
        winget install Gyan.FFmpeg --silent --accept-package-agreements --accept-source-agreements
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
        $ffmpegExe = Get-Command ffmpeg -ErrorAction SilentlyContinue
        if ($ffmpegExe) {
            $ffmpegPath = Split-Path $ffmpegExe.Path
            Write-Host "  [OK] FFmpeg installed: $ffmpegPath" -ForegroundColor Green
        }
    } catch {}

    # Direct download if winget fails
    if (-not $ffmpegPath) {
        Write-Host "  winget failed, downloading directly..." -ForegroundColor Yellow
        $ffmpegDir = "$ServerDir\ffmpeg"
        $ffmpegZip = "$env:TEMP\ffmpeg.zip"
        New-Item -ItemType Directory -Force -Path $ffmpegDir | Out-Null
        Invoke-WebRequest -Uri "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip" -OutFile $ffmpegZip
        Expand-Archive -Path $ffmpegZip -DestinationPath $ffmpegDir -Force
        $ffmpegBin = Get-ChildItem -Path $ffmpegDir -Filter "ffmpeg.exe" -Recurse | Select-Object -First 1
        if ($ffmpegBin) {
            $ffmpegPath = $ffmpegBin.DirectoryName
            Write-Host "  [OK] FFmpeg downloaded: $ffmpegPath" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] FFmpeg install failed. Manual install required." -ForegroundColor Red
            exit 1
        }
    }
}

# ── 3. Package install ───────────────────────────────────────────────────────────
Write-Host "[3/5] Installing Python packages..." -ForegroundColor Yellow
& $python -m pip install --quiet --upgrade fastapi uvicorn yt-dlp python-dotenv "uvicorn[standard]"
Write-Host "  [OK] Packages installed" -ForegroundColor Green

# ── 4. Download server.py ────────────────────────────────────────────────────
Write-Host "[4/5] Downloading server files..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $ServerDir | Out-Null

# Check latest server.py URL from version.json
try {
    $versionInfo = Invoke-RestMethod -Uri $VersionUrl -TimeoutSec 5
    $latestVersion = $versionInfo.server
    if ($versionInfo.serverUrl) { $ServerUrl = $versionInfo.serverUrl }
    Write-Host "  Latest version: v$latestVersion" -ForegroundColor Cyan
} catch {
    Write-Host "  Version check failed, using default URL" -ForegroundColor Yellow
}

try {
    Invoke-WebRequest -Uri "$ServerUrl?ts=$(Get-Date -Format yyyyMMddHHmmss)" -OutFile "$ServerDir\server.py"
    Write-Host "  [OK] server.py downloaded" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] Download failed. Please copy server.py to $ServerDir manually." -ForegroundColor Red
    exit 1
}

# Create .env file (save FFmpeg path)
$envContent = "FFMPEG_LOCATION=$ffmpegPath"
Set-Content -Path "$ServerDir\.env" -Value $envContent
Write-Host "  [OK] .env configured (FFMPEG_LOCATION=$ffmpegPath)" -ForegroundColor Green

# ── 5. Register auto-start (run on Windows startup) ────────────────────────
Write-Host "[5/5] Registering auto-start..." -ForegroundColor Yellow

$startupScript = "$ServerDir\start.ps1"
$startupContent = @"
# ivLyrics YouTube Caption Server auto-start
Set-Location "$ServerDir"
& $python -m uvicorn server:app --host 127.0.0.1 --port $Port --log-level warning
"@
Set-Content -Path $startupScript -Value $startupContent

# Create shortcut in startup folder
$startupFolder = [System.Environment]::GetFolderPath("Startup")
$shortcutPath = "$startupFolder\ivLyrics-YTCaption.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startupScript`""
$shortcut.WorkingDirectory = $ServerDir
$shortcut.Description = "ivLyrics YouTube Caption Server"
$shortcut.Save()
Write-Host "  [OK] Auto-start registered" -ForegroundColor Green

# ── complete ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Installation complete!" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Server URL: http://localhost:$Port" -ForegroundColor White
Write-Host "  Install path: $ServerDir" -ForegroundColor White
Write-Host "  Starts automatically with Windows." -ForegroundColor White
Write-Host ""
Write-Host "  In ivLyrics Settings > YouTube Caption > Server URL," -ForegroundColor White
Write-Host "  http://localhost:$Port enter the address above." -ForegroundColor White
Write-Host ""

# Start server now
Write-Host "Starting server now..." -ForegroundColor Yellow
Start-Process powershell -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startupScript`"" -WorkingDirectory $ServerDir
Start-Sleep -Seconds 2

# Health check
try {
    $response = Invoke-WebRequest -Uri "http://localhost:$Port/health" -TimeoutSec 5
    Write-Host "  [OK] Server is running!" -ForegroundColor Green
} catch {
    Write-Host "  Server is starting. Please test connection in ivLyrics shortly." -ForegroundColor Yellow
}

Write-Host ""