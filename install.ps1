# ivLyrics YouTube Caption Server - Windows Install Script (Node.js)
# Usage: iwr -useb https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/install.ps1 | iex

$ErrorActionPreference = "Continue"
$ServerDir   = "$env:LOCALAPPDATA\ivLyrics\ytcaption-server"
$VersionUrl  = "https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/version.json"
$ServerJsUrl = "https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/server.js"
$PkgJsonUrl  = "https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/package.json"
$Port        = 8080

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  ivLyrics YouTube Caption Server Install" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Node.js check ──────────────────────────────────────────────────────────
Write-Host "[1/4] Checking Node.js..." -ForegroundColor Yellow
$node = $null

# PATH 갱신
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

# 일반 PATH에서 확인
try {
    $ver = node --version 2>&1
    if ($ver -match "v(\d+)" -and [int]$Matches[1] -ge 18) {
        $node = "node"
        Write-Host "  [OK] Node.js $ver found" -ForegroundColor Green
    }
} catch {}

# Spicetify 내장 Node.js 탐색
if (-not $node) {
    $spicePaths = @(
        "$env:LOCALAPPDATA\spicetify",
        "$env:APPDATA\spicetify",
        "$env:USERPROFILE\.spicetify",
        "$env:USERPROFILE\.config\spicetify"
    )
    foreach ($sp in $spicePaths) {
        $nodeExe = Get-ChildItem -Path $sp -Filter "node.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nodeExe) {
            $ver = & $nodeExe.FullName --version 2>&1
            if ($ver -match "v(\d+)" -and [int]$Matches[1] -ge 18) {
                $node = $nodeExe.FullName
                Write-Host "  [OK] Node.js $ver found (Spicetify): $($nodeExe.FullName)" -ForegroundColor Green
                break
            }
        }
    }
}

# 일반적인 Node.js 설치 경로 탐색
if (-not $node) {
    $commonPaths = @(
        "$env:ProgramFiles
odejs
ode.exe",
        "$env:ProgramFiles(x86)
odejs
ode.exe",
        "$env:LOCALAPPDATA\Programs
odejs
ode.exe"
    )
    foreach ($p in $commonPaths) {
        if (Test-Path $p) {
            $ver = & $p --version 2>&1
            if ($ver -match "v(\d+)" -and [int]$Matches[1] -ge 18) {
                $node = $p
                Write-Host "  [OK] Node.js $ver found: $p" -ForegroundColor Green
                break
            }
        }
    }
}

# 없으면 winget으로 설치
if (-not $node) {
    Write-Host "  Node.js not found. Installing via winget..." -ForegroundColor Yellow
    try {
        winget install --id OpenJS.NodeJS.LTS -e --source winget --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
        $ver = node --version 2>&1
        if ($ver -match "v(\d+)" -and [int]$Matches[1] -ge 18) {
            $node = "node"
            Write-Host "  [OK] Node.js $ver installed" -ForegroundColor Green
        }
    } catch {}
}

if (-not $node) {
    Write-Host "  [FAIL] Node.js not found." -ForegroundColor Red
    Write-Host "  Please install Node.js v18+ from https://nodejs.org and run this script again." -ForegroundColor Yellow
    return
}

# ── 2. npm check ──────────────────────────────────────────────────────────────
Write-Host "[2/4] Checking npm..." -ForegroundColor Yellow
# node 경로 기준으로 npm 찾기
$npmCmd = "npm"
if ($node -ne "node") {
    $nodeDir = Split-Path $node
    $npmPath = Join-Path $nodeDir "npm.cmd"
    if (Test-Path $npmPath) { $npmCmd = $npmPath }
}
try {
    $npmVer = & $npmCmd --version 2>&1
    Write-Host "  [OK] npm $npmVer found" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] npm not found. Please reinstall Node.js." -ForegroundColor Red
    return
}

# ── 3. Download server files ──────────────────────────────────────────────────
Write-Host "[3/4] Downloading server files..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $ServerDir | Out-Null

# version.json 확인
try {
    $versionInfo = Invoke-RestMethod -Uri $VersionUrl -TimeoutSec 5
    Write-Host "  Latest version: v$($versionInfo.server)" -ForegroundColor Cyan
    if ($versionInfo.serverJsUrl) { $ServerJsUrl = $versionInfo.serverJsUrl }
} catch {
    Write-Host "  Version check failed, using default URL" -ForegroundColor Yellow
}

# server.js 다운로드
try {
    Invoke-WebRequest -Uri $ServerJsUrl -OutFile "$ServerDir\server.js" -UseBasicParsing
    Write-Host "  [OK] server.js downloaded" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] server.js download failed: $_" -ForegroundColor Red
    return
}

# package.json 다운로드
try {
    Invoke-WebRequest -Uri $PkgJsonUrl -OutFile "$ServerDir\package.json" -UseBasicParsing
    Write-Host "  [OK] package.json downloaded" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] package.json download failed: $_" -ForegroundColor Red
    return
}

# npm install
Write-Host "  Installing npm packages..." -ForegroundColor Yellow
Push-Location $ServerDir
try {
    & $npmCmd install --silent 2>&1 | Out-Null
    Write-Host "  [OK] npm packages installed" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] npm install failed: $_" -ForegroundColor Red
    Pop-Location
    return
}
Pop-Location

# .env 파일 생성
if (-not (Test-Path "$ServerDir\.env")) {
    Set-Content -Path "$ServerDir\.env" -Value "PORT=$Port"
    Write-Host "  [OK] .env created" -ForegroundColor Green
}

# ── 4. Register auto-start ────────────────────────────────────────────────────
Write-Host "[4/4] Registering auto-start..." -ForegroundColor Yellow

$startScript = "$ServerDir\start.ps1"
Set-Content -Path $startScript -Value @"
Set-Location `"$ServerDir`"
& `"$node`" server.js
"@

$startupFolder = [System.Environment]::GetFolderPath("Startup")
$shortcutPath  = "$startupFolder\ivLyrics-YTCaption.lnk"
$shell         = New-Object -ComObject WScript.Shell
$shortcut      = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath    = "powershell.exe"
$shortcut.Arguments     = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`""
$shortcut.WorkingDirectory = $ServerDir
$shortcut.Description   = "ivLyrics YouTube Caption Server"
$shortcut.Save()
Write-Host "  [OK] Auto-start registered (starts on login)" -ForegroundColor Green

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Installation complete!" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Server URL:   http://localhost:$Port" -ForegroundColor White
Write-Host "  Install path: $ServerDir" -ForegroundColor White
Write-Host "  Starts automatically on login." -ForegroundColor White
Write-Host ""
Write-Host "  In ivLyrics Settings > YouTube Caption > Server URL," -ForegroundColor White
Write-Host "  enter: http://localhost:$Port" -ForegroundColor White
Write-Host ""

# Start server now
Write-Host "Starting server..." -ForegroundColor Yellow
Start-Process powershell -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`"" -WorkingDirectory $ServerDir
Start-Sleep -Seconds 3

# Health check
try {
    $resp = Invoke-WebRequest -Uri "http://localhost:$Port/health" -TimeoutSec 5 -UseBasicParsing
    Write-Host "  [OK] Server is running!" -ForegroundColor Green
} catch {
    Write-Host "  Server is starting. Test connection in ivLyrics shortly." -ForegroundColor Yellow
}

Write-Host ""
Write-Host ""