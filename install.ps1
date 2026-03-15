# ivLyrics YouTube Caption Server - Windows 설치 스크립트
# 사용법: iwr -useb https://your-url/install.ps1 | iex

$ErrorActionPreference = "Stop"
$ServerDir = "$env:LOCALAPPDATA\ivLyrics\ytcaption-server"
$VersionUrl = "https://raw.githubusercontent.com/ivLis-Studio/ivLyrics/main/ytcaption-server/version.json?ts=$(Get-Date -Format yyyyMMddHHmmss)"
$ServerUrl  = "https://raw.githubusercontent.com/ivLis-Studio/ivLyrics/main/ytcaption-server/server.py"
$Port = 8080

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  ivLyrics YouTube Caption Server 설치" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Python 확인 ────────────────────────────────────────────────────────────
Write-Host "[1/5] Python 확인 중..." -ForegroundColor Yellow
$python = $null
foreach ($cmd in @("python", "python3")) {
    try {
        $ver = & $cmd --version 2>&1
        if ($ver -match "Python 3\.") {
            $python = $cmd
            Write-Host "  ✓ $ver 발견" -ForegroundColor Green
            break
        }
    } catch {}
}

if (-not $python) {
    Write-Host "  Python 3가 없습니다. 설치 중..." -ForegroundColor Yellow
    try {
        winget install Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
        $python = "python"
        Write-Host "  ✓ Python 설치 완료" -ForegroundColor Green
    } catch {
        Write-Host "  ✗ Python 자동 설치 실패. https://python.org 에서 수동 설치 후 다시 실행하세요." -ForegroundColor Red
        exit 1
    }
}

# ── 2. FFmpeg 확인 ────────────────────────────────────────────────────────────
Write-Host "[2/5] FFmpeg 확인 중..." -ForegroundColor Yellow
$ffmpegPath = $null
$ffmpegExe = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($ffmpegExe) {
    $ffmpegPath = Split-Path $ffmpegExe.Path
    Write-Host "  ✓ FFmpeg 발견: $ffmpegPath" -ForegroundColor Green
} else {
    Write-Host "  FFmpeg 없음. 설치 중..." -ForegroundColor Yellow
    try {
        winget install Gyan.FFmpeg --silent --accept-package-agreements --accept-source-agreements
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
        $ffmpegExe = Get-Command ffmpeg -ErrorAction SilentlyContinue
        if ($ffmpegExe) {
            $ffmpegPath = Split-Path $ffmpegExe.Path
            Write-Host "  ✓ FFmpeg 설치 완료: $ffmpegPath" -ForegroundColor Green
        }
    } catch {}

    # winget 실패 시 직접 다운로드
    if (-not $ffmpegPath) {
        Write-Host "  winget 실패, 직접 다운로드 중..." -ForegroundColor Yellow
        $ffmpegDir = "$ServerDir\ffmpeg"
        $ffmpegZip = "$env:TEMP\ffmpeg.zip"
        New-Item -ItemType Directory -Force -Path $ffmpegDir | Out-Null
        Invoke-WebRequest -Uri "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip" -OutFile $ffmpegZip
        Expand-Archive -Path $ffmpegZip -DestinationPath $ffmpegDir -Force
        $ffmpegBin = Get-ChildItem -Path $ffmpegDir -Filter "ffmpeg.exe" -Recurse | Select-Object -First 1
        if ($ffmpegBin) {
            $ffmpegPath = $ffmpegBin.DirectoryName
            Write-Host "  ✓ FFmpeg 다운로드 완료: $ffmpegPath" -ForegroundColor Green
        } else {
            Write-Host "  ✗ FFmpeg 설치 실패. 수동 설치가 필요합니다." -ForegroundColor Red
            exit 1
        }
    }
}

# ── 3. 패키지 설치 ───────────────────────────────────────────────────────────
Write-Host "[3/5] Python 패키지 설치 중..." -ForegroundColor Yellow
& $python -m pip install --quiet --upgrade fastapi uvicorn yt-dlp python-dotenv "uvicorn[standard]"
Write-Host "  ✓ 패키지 설치 완료" -ForegroundColor Green

# ── 4. server.py 다운로드 ────────────────────────────────────────────────────
Write-Host "[4/5] 서버 파일 다운로드 중..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $ServerDir | Out-Null

# version.json에서 최신 server.py URL 확인
try {
    $versionInfo = Invoke-RestMethod -Uri $VersionUrl -TimeoutSec 5
    $latestVersion = $versionInfo.server
    if ($versionInfo.serverUrl) { $ServerUrl = $versionInfo.serverUrl }
    Write-Host "  최신 버전: v$latestVersion" -ForegroundColor Cyan
} catch {
    Write-Host "  버전 확인 실패, 기본 URL 사용" -ForegroundColor Yellow
}

try {
    Invoke-WebRequest -Uri "$ServerUrl?ts=$(Get-Date -Format yyyyMMddHHmmss)" -OutFile "$ServerDir\server.py"
    Write-Host "  ✓ server.py 다운로드 완료" -ForegroundColor Green
} catch {
    Write-Host "  ✗ 다운로드 실패. server.py를 $ServerDir 에 수동으로 복사하세요." -ForegroundColor Red
    exit 1
}

# .env 파일 생성 (FFmpeg 경로 저장)
$envContent = "FFMPEG_LOCATION=$ffmpegPath"
Set-Content -Path "$ServerDir\.env" -Value $envContent
Write-Host "  ✓ .env 설정 완료 (FFMPEG_LOCATION=$ffmpegPath)" -ForegroundColor Green

# ── 5. 시작 프로그램 등록 (Windows 시작 시 자동 실행) ────────────────────────
Write-Host "[5/5] 자동 시작 등록 중..." -ForegroundColor Yellow

$startupScript = "$ServerDir\start.ps1"
$startupContent = @"
# ivLyrics YouTube Caption Server 자동 시작
Set-Location "$ServerDir"
& $python -m uvicorn server:app --host 127.0.0.1 --port $Port --log-level warning
"@
Set-Content -Path $startupScript -Value $startupContent

# 시작 프로그램 폴더에 단축키 생성
$startupFolder = [System.Environment]::GetFolderPath("Startup")
$shortcutPath = "$startupFolder\ivLyrics-YTCaption.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startupScript`""
$shortcut.WorkingDirectory = $ServerDir
$shortcut.Description = "ivLyrics YouTube Caption Server"
$shortcut.Save()
Write-Host "  ✓ 시작 프로그램 등록 완료" -ForegroundColor Green

# ── 완료 ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  설치 완료!" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  서버 주소: http://localhost:$Port" -ForegroundColor White
Write-Host "  설치 위치: $ServerDir" -ForegroundColor White
Write-Host "  Windows 시작 시 자동으로 실행됩니다." -ForegroundColor White
Write-Host ""
Write-Host "  ivLyrics 설정 > YouTube Caption > 서버 URL에" -ForegroundColor White
Write-Host "  http://localhost:$Port 을 입력하세요." -ForegroundColor White
Write-Host ""

# 지금 바로 서버 시작
Write-Host "서버를 지금 시작합니다..." -ForegroundColor Yellow
Start-Process powershell -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startupScript`"" -WorkingDirectory $ServerDir
Start-Sleep -Seconds 2

# 헬스체크
try {
    $response = Invoke-WebRequest -Uri "http://localhost:$Port/health" -TimeoutSec 5
    Write-Host "  ✓ 서버 정상 실행 중!" -ForegroundColor Green
} catch {
    Write-Host "  서버가 시작되는 중입니다. 잠시 후 ivLyrics에서 연결 테스트를 해보세요." -ForegroundColor Yellow
}

Write-Host ""
