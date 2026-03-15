# ivLyrics YouTube Caption Server - Windows Uninstall Script

$ServerDir = "$env:LOCALAPPDATA\ivLyrics\ytcaption-server"
$taskName  = "ivLyrics-YTCaption"

Write-Host ""
Write-Host "Removing ivLyrics YouTube Caption Server..." -ForegroundColor Yellow

# Task Scheduler 작업 중지 및 제거
Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "  [OK] Task Scheduler task removed" -ForegroundColor Green

# 기존 시작 프로그램 단축키 제거 (구버전 호환)
$shortcut = "$([System.Environment]::GetFolderPath('Startup'))\ivLyrics-YTCaption.lnk"
if (Test-Path $shortcut) { Remove-Item $shortcut -Force }

# 서버 폴더 제거
if (Test-Path $ServerDir) {
    Remove-Item $ServerDir -Recurse -Force
    Write-Host "  [OK] Server files removed" -ForegroundColor Green
}

Write-Host ""
Write-Host "Uninstall complete!" -ForegroundColor Green
Write-Host ""
