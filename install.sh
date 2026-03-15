#!/bin/bash
# ivLyrics YouTube Caption Server - macOS/Linux 설치 스크립트
# 사용법: curl -fsSL https://your-url/install.sh | bash

set -e

SERVER_DIR="$HOME/.config/ivLyrics/ytcaption-server"
VERSION_URL="https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/version.json"
SERVER_URL="https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/server.py"
PORT=8080

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}=================================================="
echo -e "  ivLyrics YouTube Caption Server 설치"
echo -e "==================================================${NC}"
echo ""

# ── 1. Python 확인 ────────────────────────────────────────────────────────────
echo -e "${YELLOW}[1/5] Python 확인 중...${NC}"
PYTHON=""
for cmd in python3 python; do
    if command -v $cmd &>/dev/null; then
        VER=$($cmd --version 2>&1)
        if echo "$VER" | grep -q "Python 3"; then
            PYTHON=$cmd
            echo -e "  ${GREEN}✓ $VER 발견${NC}"
            break
        fi
    fi
done

if [ -z "$PYTHON" ]; then
    echo -e "  Python 3가 없습니다. 설치 중..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &>/dev/null; then
            brew install python3
        else
            echo -e "  ${RED}✗ Homebrew가 없습니다. https://brew.sh 설치 후 다시 시도하세요.${NC}"
            exit 1
        fi
    else
        sudo apt-get update -qq && sudo apt-get install -y python3 python3-pip
    fi
    PYTHON="python3"
    echo -e "  ${GREEN}✓ Python 설치 완료${NC}"
fi

# ── 2. FFmpeg 확인 ────────────────────────────────────────────────────────────
echo -e "${YELLOW}[2/5] FFmpeg 확인 중...${NC}"
if command -v ffmpeg &>/dev/null; then
    echo -e "  ${GREEN}✓ FFmpeg 발견${NC}"
else
    echo -e "  FFmpeg 없음. 설치 중..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install ffmpeg
    else
        sudo apt-get install -y ffmpeg
    fi
    echo -e "  ${GREEN}✓ FFmpeg 설치 완료${NC}"
fi

# ── 3. 패키지 설치 ───────────────────────────────────────────────────────────
echo -e "${YELLOW}[3/5] Python 패키지 설치 중...${NC}"
$PYTHON -m pip install --quiet --upgrade fastapi uvicorn yt-dlp python-dotenv "uvicorn[standard]" 2>/dev/null || \
$PYTHON -m pip install --quiet --upgrade fastapi uvicorn yt-dlp python-dotenv "uvicorn[standard]" --break-system-packages
echo -e "  ${GREEN}✓ 패키지 설치 완료${NC}"

# ── 4. server.py 다운로드 ────────────────────────────────────────────────────
echo -e "${YELLOW}[4/5] 서버 파일 다운로드 중...${NC}"
mkdir -p "$SERVER_DIR"

# version.json에서 최신 버전 확인
VERSION_INFO=$(curl -fsSL "${VERSION_URL}?ts=$(date +%s)" 2>/dev/null || echo "{}")
LATEST_VERSION=$(echo "$VERSION_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('server',''))" 2>/dev/null || echo "")
CUSTOM_URL=$(echo "$VERSION_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('serverUrl',''))" 2>/dev/null || echo "")
if [ -n "$CUSTOM_URL" ]; then SERVER_URL="$CUSTOM_URL"; fi
if [ -n "$LATEST_VERSION" ]; then
    echo -e "  최신 버전: v$LATEST_VERSION"
fi

if curl -fsSL "${SERVER_URL}?ts=$(date +%s)" -o "$SERVER_DIR/server.py"; then
    echo -e "  ${GREEN}✓ server.py 다운로드 완료${NC}"
else
    echo -e "  ${RED}✗ 다운로드 실패. server.py를 $SERVER_DIR 에 수동으로 복사하세요.${NC}"
    exit 1
fi

# ── 5. 자동 시작 등록 ────────────────────────────────────────────────────────
echo -e "${YELLOW}[5/5] 자동 시작 등록 중...${NC}"

START_SCRIPT="$SERVER_DIR/start.sh"
cat > "$START_SCRIPT" << EOF
#!/bin/bash
cd "$SERVER_DIR"
$PYTHON -m uvicorn server:app --host 127.0.0.1 --port $PORT --log-level warning
EOF
chmod +x "$START_SCRIPT"

if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS: LaunchAgent 등록
    PLIST_DIR="$HOME/Library/LaunchAgents"
    PLIST_PATH="$PLIST_DIR/kr.ivlis.ytcaption.plist"
    mkdir -p "$PLIST_DIR"
    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>kr.ivlis.ytcaption</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>-m</string>
        <string>uvicorn</string>
        <string>server:app</string>
        <string>--host</string>
        <string>127.0.0.1</string>
        <string>--port</string>
        <string>$PORT</string>
        <string>--log-level</string>
        <string>warning</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SERVER_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$SERVER_DIR/server.log</string>
    <key>StandardErrorPath</key>
    <string>$SERVER_DIR/server.log</string>
</dict>
</plist>
EOF
    launchctl load "$PLIST_PATH" 2>/dev/null || true
    echo -e "  ${GREEN}✓ LaunchAgent 등록 완료 (로그인 시 자동 시작)${NC}"

else
    # Linux: systemd user service 등록
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_DIR"
    cat > "$SYSTEMD_DIR/ivlyrics-ytcaption.service" << EOF
[Unit]
Description=ivLyrics YouTube Caption Server
After=network.target

[Service]
Type=simple
WorkingDirectory=$SERVER_DIR
ExecStart=$PYTHON -m uvicorn server:app --host 127.0.0.1 --port $PORT --log-level warning
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable ivlyrics-ytcaption.service
    systemctl --user start ivlyrics-ytcaption.service
    echo -e "  ${GREEN}✓ systemd 서비스 등록 완료 (로그인 시 자동 시작)${NC}"
fi

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}=================================================="
echo -e "  설치 완료!"
echo -e "==================================================${NC}"
echo ""
echo -e "  서버 주소: http://localhost:$PORT"
echo -e "  설치 위치: $SERVER_DIR"
echo -e "  로그인 시 자동으로 실행됩니다."
echo ""
echo -e "  ivLyrics 설정 > YouTube Caption > 서버 URL에"
echo -e "  http://localhost:$PORT 을 입력하세요."
echo ""

# 헬스체크
sleep 2
if curl -sf "http://localhost:$PORT/health" &>/dev/null; then
    echo -e "  ${GREEN}✓ 서버 정상 실행 중!${NC}"
else
    echo -e "  ${YELLOW}서버가 시작되는 중입니다. 잠시 후 ivLyrics에서 연결 테스트를 해보세요.${NC}"
fi
echo ""