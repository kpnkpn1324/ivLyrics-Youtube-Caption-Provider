#!/bin/bash
# ivLyrics YouTube Caption Server - macOS/Linux Install Script (Node.js)
# Usage: curl -fsSL https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/install.sh | bash

SERVER_DIR="$HOME/.config/ivLyrics/ytcaption-server"
VERSION_URL="https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/version.json"
SERVER_JS_URL="https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/server.js"
PKG_JSON_URL="https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/package.json"
PORT=8080

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo ""
echo -e "${CYAN}=================================================="
echo -e "  ivLyrics YouTube Caption Server Install"
echo -e "==================================================${NC}"
echo ""

# ── 1. Node.js check ──────────────────────────────────────────────────────────
echo -e "${YELLOW}[1/4] Checking Node.js...${NC}"
NODE=""

if command -v node &>/dev/null; then
    VER=$(node --version 2>&1)
    MAJOR=$(echo "$VER" | sed 's/v\([0-9]*\).*/\1/')
    if [ "$MAJOR" -ge 18 ] 2>/dev/null; then
        NODE="node"
        echo -e "  ${GREEN}[OK] Node.js $VER found${NC}"
    else
        echo -e "  Node.js $VER too old (v18+ required). Installing newer..."
    fi
fi

if [ -z "$NODE" ]; then
    echo -e "  Node.js not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &>/dev/null; then
            brew install node
            NODE="node"
            echo -e "  ${GREEN}[OK] Node.js $(node --version) installed${NC}"
        else
            echo -e "  ${RED}[FAIL] Homebrew not found. Install from https://brew.sh then re-run.${NC}"
            exit 1
        fi
    else
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - 2>/dev/null
        sudo apt-get install -y nodejs 2>/dev/null
        NODE="node"
        echo -e "  ${GREEN}[OK] Node.js $(node --version) installed${NC}"
    fi
fi

# ── 2. npm check ──────────────────────────────────────────────────────────────
echo -e "${YELLOW}[2/4] Checking npm...${NC}"
if command -v npm &>/dev/null; then
    echo -e "  ${GREEN}[OK] npm $(npm --version) found${NC}"
else
    echo -e "  ${RED}[FAIL] npm not found. Reinstall Node.js.${NC}"
    exit 1
fi

# ── 3. Download server files ──────────────────────────────────────────────────
echo -e "${YELLOW}[3/4] Downloading server files...${NC}"
mkdir -p "$SERVER_DIR"

# version.json 확인
LATEST=""
if command -v python3 &>/dev/null; then
    VERSION_INFO=$(curl -fsSL "${VERSION_URL}?ts=$(date +%s)" 2>/dev/null || echo "{}")
    LATEST=$(echo "$VERSION_INFO" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('server',''))" 2>/dev/null || echo "")
    CUSTOM_URL=$(echo "$VERSION_INFO" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('serverJsUrl',''))" 2>/dev/null || echo "")
    if [ -n "$CUSTOM_URL" ]; then SERVER_JS_URL="$CUSTOM_URL"; fi
fi
if [ -n "$LATEST" ]; then echo -e "  Latest version: v$LATEST"; fi

# server.js 다운로드
if curl -fsSL "$SERVER_JS_URL" -o "$SERVER_DIR/server.js"; then
    echo -e "  ${GREEN}[OK] server.js downloaded${NC}"
else
    echo -e "  ${RED}[FAIL] server.js download failed${NC}"; exit 1
fi

# package.json 다운로드
if curl -fsSL "$PKG_JSON_URL" -o "$SERVER_DIR/package.json"; then
    echo -e "  ${GREEN}[OK] package.json downloaded${NC}"
else
    echo -e "  ${RED}[FAIL] package.json download failed${NC}"; exit 1
fi

# npm install
echo -e "  Installing npm packages..."
cd "$SERVER_DIR" && npm install --silent 2>/dev/null
echo -e "  ${GREEN}[OK] npm packages installed${NC}"

# .env 파일 생성
if [ ! -f "$SERVER_DIR/.env" ]; then
    echo "PORT=$PORT" > "$SERVER_DIR/.env"
    echo -e "  ${GREEN}[OK] .env created${NC}"
fi

# yt-dlp 설치
YTDLP_DEST="$SERVER_DIR/yt-dlp"
if ! [ -f "$YTDLP_DEST" ] || [ "$(wc -c < "$YTDLP_DEST")" -eq 0 ]; then
    echo -e "  Installing yt-dlp..."
    if command -v pip3 &>/dev/null; then
        pip3 install yt-dlp --quiet --break-system-packages 2>/dev/null || pip3 install yt-dlp --quiet 2>/dev/null || true
    fi
    # pip로 설치된 yt-dlp 찾아서 복사
    YTDLP_SRC=$(command -v yt-dlp 2>/dev/null || echo "")
    if [ -n "$YTDLP_SRC" ] && [ -s "$YTDLP_SRC" ]; then
        cp "$YTDLP_SRC" "$YTDLP_DEST"
        chmod +x "$YTDLP_DEST"
        echo -e "  ${GREEN}[OK] yt-dlp installed${NC}"
    else
        # 직접 다운로드
        if [[ "$OSTYPE" == "darwin"* ]]; then
            curl -fsSL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" -o "$YTDLP_DEST" 2>/dev/null || true
        else
            curl -fsSL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" -o "$YTDLP_DEST" 2>/dev/null || true
        fi
        if [ -s "$YTDLP_DEST" ]; then
            chmod +x "$YTDLP_DEST"
            echo -e "  ${GREEN}[OK] yt-dlp downloaded${NC}"
        else
            echo -e "  ${YELLOW}[WARN] yt-dlp install failed. Server will retry on first run.${NC}"
        fi
    fi
fi

# ── 4. Register auto-start ────────────────────────────────────────────────────
echo -e "${YELLOW}[4/4] Registering auto-start...${NC}"

NODE_PATH=$(which node)

if [[ "$OSTYPE" == "darwin"* ]]; then
    PLIST="$HOME/Library/LaunchAgents/kr.ivlis.ytcaption.plist"
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>kr.ivlis.ytcaption</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE_PATH</string>
        <string>$SERVER_DIR/server.js</string>
    </array>
    <key>WorkingDirectory</key><string>$SERVER_DIR</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$SERVER_DIR/server.log</string>
    <key>StandardErrorPath</key><string>$SERVER_DIR/server.log</string>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST" 2>/dev/null || true
    launchctl start kr.ivlis.ytcaption 2>/dev/null || true
    echo -e "  ${GREEN}[OK] LaunchAgent registered (starts on login)${NC}"
else
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/ivlyrics-ytcaption.service" << EOF
[Unit]
Description=ivLyrics YouTube Caption Server
After=network.target

[Service]
Type=simple
WorkingDirectory=$SERVER_DIR
ExecStart=$NODE_PATH $SERVER_DIR/server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable ivlyrics-ytcaption.service 2>/dev/null || true
    systemctl --user start ivlyrics-ytcaption.service 2>/dev/null || true
    echo -e "  ${GREEN}[OK] systemd service registered${NC}"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}=================================================="
echo -e "  Installation complete!"
echo -e "==================================================${NC}"
echo ""
echo -e "  Server URL:   http://localhost:$PORT"
echo -e "  Install path: $SERVER_DIR"
echo -e "  Starts automatically on login."
echo ""
echo -e "  In ivLyrics Settings > YouTube Caption > Server URL,"
echo -e "  enter: http://localhost:$PORT"
echo ""

sleep 2
if curl -sf "http://localhost:$PORT/health" &>/dev/null; then
    echo -e "  ${GREEN}[OK] Server is running!${NC}"
else
    echo -e "  ${YELLOW}Server is starting. Test connection in ivLyrics shortly.${NC}"
fi
echo ""