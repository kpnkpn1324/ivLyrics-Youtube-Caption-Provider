# ivLyrics YouTube Caption Server - Windows Install Script (Node.js)
# Usage: iwr -useb "URL" -OutFile "$env:TEMP\ytc.ps1"; powershell -ExecutionPolicy Bypass -NoExit -File "$env:TEMP\ytc.ps1"

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

# 1. Node.js
Write-Host "[1/4] Checking Node.js..." -ForegroundColor Yellow
$node = $null
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

try { $ver = node --version 2>&1; if ($ver -match "v(\d+)" -and [int]$Matches[1] -ge 18) { $node = "node"; Write-Host "  [OK] Node.js $ver found" -ForegroundColor Green } } catch {}

if (-not $node) {
    foreach ($sp in @("$env:LOCALAPPDATA\spicetify","$env:APPDATA\spicetify","$env:USERPROFILE\.spicetify")) {
        if (-not (Test-Path $sp)) { continue }
        $n = Get-ChildItem -Path $sp -Filter "node.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($n) { $v = & $n.FullName --version 2>&1; if ($v -match "v(\d+)" -and [int]$Matches[1] -ge 18) { $node = $n.FullName; Write-Host "  [OK] Node.js $v (Spicetify)" -ForegroundColor Green; break } }
    }
}

if (-not $node) {
    foreach ($p in @("$env:ProgramFiles\nodejs\node.exe","$env:LOCALAPPDATA\Programs\nodejs\node.exe")) {
        if (Test-Path $p) { $v = & $p --version 2>&1; if ($v -match "v(\d+)" -and [int]$Matches[1] -ge 18) { $node = $p; Write-Host "  [OK] Node.js $v" -ForegroundColor Green; break } }
    }
}

if (-not $node) {
    Write-Host "  Installing Node.js via winget..." -ForegroundColor Yellow
    try {
        winget install --id OpenJS.NodeJS.LTS -e --source winget --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
        $v = node --version 2>&1; if ($v -match "v(\d+)" -and [int]$Matches[1] -ge 18) { $node = "node"; Write-Host "  [OK] Node.js $v installed" -ForegroundColor Green }
    } catch {}
}

if (-not $node) { Write-Host "  [FAIL] Install Node.js from https://nodejs.org" -ForegroundColor Red; return }

# 2. npm
Write-Host "[2/4] Checking npm..." -ForegroundColor Yellow
$npmCmd = "npm"
if ($node -ne "node") { $np = Join-Path (Split-Path $node) "npm.cmd"; if (Test-Path $np) { $npmCmd = $np } }
try { $v = & $npmCmd --version 2>&1; Write-Host "  [OK] npm $v" -ForegroundColor Green } catch { Write-Host "  [FAIL] npm not found" -ForegroundColor Red; return }

# 3. Download
Write-Host "[3/4] Downloading server files..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $ServerDir | Out-Null

try { $vi = Invoke-RestMethod -Uri $VersionUrl -TimeoutSec 5; Write-Host "  Latest: v$($vi.server)" -ForegroundColor Cyan; if ($vi.serverJsUrl) { $ServerJsUrl = $vi.serverJsUrl } } catch {}

try { Invoke-WebRequest -Uri $ServerJsUrl -OutFile "$ServerDir\server.js" -UseBasicParsing; Write-Host "  [OK] server.js" -ForegroundColor Green } catch { Write-Host "  [FAIL] $_" -ForegroundColor Red; return }
try { Invoke-WebRequest -Uri $PkgJsonUrl -OutFile "$ServerDir\package.json" -UseBasicParsing; Write-Host "  [OK] package.json" -ForegroundColor Green } catch { Write-Host "  [FAIL] $_" -ForegroundColor Red; return }

Write-Host "  Installing npm packages..." -ForegroundColor Yellow
Push-Location $ServerDir
& $npmCmd install --silent 2>&1 | Out-Null
Pop-Location
Write-Host "  [OK] npm packages installed" -ForegroundColor Green

# yt-dlp
$ytdlpDest = "$ServerDir\yt-dlp.exe"
$ytdlpSrc = $null
foreach ($pp in @("$env:LOCALAPPDATA\Python","$env:APPDATA\Python","$env:LOCALAPPDATA\Programs\Python")) {
    if (-not (Test-Path $pp)) { continue }
    $f = Get-ChildItem -Path $pp -Filter "yt-dlp.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f -and $f.Length -gt 0) { $ytdlpSrc = $f.FullName; break }
}
if ($ytdlpSrc) {
    Copy-Item $ytdlpSrc $ytdlpDest -Force
    Write-Host "  [OK] yt-dlp copied" -ForegroundColor Green
} else {
    $yc = Get-Command yt-dlp -ErrorAction SilentlyContinue
    $yp = if ($yc) { $yc.Source } else { $null }
    if ($yp -and (Get-Item $yp -ErrorAction SilentlyContinue).Length -gt 0) {
        Copy-Item $yp $ytdlpDest -Force; Write-Host "  [OK] yt-dlp copied from PATH" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] yt-dlp not found. Will download on first run." -ForegroundColor Yellow
    }
}

if (-not (Test-Path "$ServerDir\.env")) { Set-Content -Path "$ServerDir\.env" -Value "PORT=$Port"; Write-Host "  [OK] .env created" -ForegroundColor Green }

# 4. Auto-start
Write-Host "[4/4] Registering auto-start..." -ForegroundColor Yellow

$nc = Get-Command $node -ErrorAction SilentlyContinue
$nodePath = if ($nc) { $nc.Source } else { $node }

$vbsPath = "$ServerDir\start.vbs"
Set-Content  -Path $vbsPath -Value 'Set WshShell = CreateObject("WScript.Shell")' -Encoding ASCII
Add-Content  -Path $vbsPath -Value ('WshShell.Run Chr(34) & "' + $nodePath + '" & Chr(34) & " server.js", 0, False') -Encoding ASCII

$startupFolder = [System.Environment]::GetFolderPath("Startup")
$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut("$startupFolder\ivLyrics-YTCaption.lnk")
$sc.TargetPath = "wscript.exe"
$sc.Arguments = "`"$vbsPath`""
$sc.WorkingDirectory = $ServerDir
$sc.Description = "ivLyrics YouTube Caption Server"
$sc.Save()
Write-Host "  [OK] Auto-start registered (background, no window)" -ForegroundColor Green

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

Write-Host "Starting server..." -ForegroundColor Yellow
Start-Process "wscript.exe" -ArgumentList "`"$vbsPath`"" -WorkingDirectory $ServerDir
Start-Sleep -Seconds 3

try { Invoke-WebRequest -Uri "http://localhost:$Port/health" -TimeoutSec 5 -UseBasicParsing | Out-Null; Write-Host "  [OK] Server is running!" -ForegroundColor Green } catch { Write-Host "  Server is starting. Test connection in ivLyrics shortly." -ForegroundColor Yellow }

Write-Host ""
