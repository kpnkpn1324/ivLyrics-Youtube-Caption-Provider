# YouTube Caption Provider

YouTube 공식 MV 자막에서 가사를 가져오는 애드온입니다.

## 미리보기

> ivLyrics 마켓플레이스에서 설치 후 로컬 서버를 실행하면 자동으로 YouTube 자막 가사가 표시됩니다.

---

## 설치 방법

### 1단계 - 애드온 설치

**ivLyrics 마켓플레이스**에서 `YouTube Caption` 검색 후 설치

또는 수동으로 `Addon_Lyrics_YoutubeCaption.js`를 ivLyrics 폴더에 복사

---

### 2단계 - 로컬 서버 설치

서버는 **각자의 컴퓨터에서 실행**됩니다. 한 번만 설치하면 부팅 시 자동으로 실행됩니다.

#### Windows

```powershell
iwr -useb "https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/install.ps1" -OutFile "$env:TEMP\ytc.ps1"; powershell -ExecutionPolicy Bypass -NoExit -File "$env:TEMP\ytc.ps1"
```

#### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/install.sh | bash
```

---

### 3단계 - 서버 URL 설정

ivLyrics 설정 → **YouTube Caption** → 서버 URL에 입력:

```
http://localhost:8080
```

---

## 제거 방법

#### Windows

```powershell
iwr -useb "https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/uninstall.ps1" -OutFile "$env:TEMP\ytc_uninstall.ps1"; powershell -ExecutionPolicy Bypass -NoExit -File "$env:TEMP\ytc_uninstall.ps1"
```

#### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/uninstall.sh | bash
```

---

## 동작 방식

```
Spotify 재생
  → ivLyrics가 곡 제목 + 아티스트 전송
  → 로컬 서버가 MusicBrainz로 곡 언어 감지
  → YouTube Music / MV에서 해당 언어 자막 검색
  → 수동 자막 우선, 없으면 자동 자막
  → LRC 포맷으로 반환 → ivLyrics에 표시
```

## 라이선스

MIT

---
---

# YouTube Caption Provider

An ivLyrics addon that fetches lyrics from YouTube official MV captions.

## Preview

> Install from the ivLyrics Marketplace, run the local server, and YouTube caption lyrics will be displayed automatically.

---

## Installation

### Step 1 - Install the Addon

Search for `YouTube Caption` in the **ivLyrics Marketplace** and install it.

Or manually copy `Addon_Lyrics_YoutubeCaption.js` to your ivLyrics folder.

---

### Step 2 - Install the Local Server

The server runs **on your own computer**. Install it once and it will start automatically on boot.

#### Windows

```powershell
iwr -useb "https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/install.ps1" -OutFile "$env:TEMP\ytc.ps1"; powershell -ExecutionPolicy Bypass -NoExit -File "$env:TEMP\ytc.ps1"
```

#### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/install.sh | bash
```

---

### Step 3 - Configure Server URL

In ivLyrics Settings → **YouTube Caption** → Server URL, enter:

```
http://localhost:8080
```

---

## Uninstall

#### Windows

```powershell
iwr -useb "https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/uninstall.ps1" -OutFile "$env:TEMP\ytc_uninstall.ps1"; powershell -ExecutionPolicy Bypass -NoExit -File "$env:TEMP\ytc_uninstall.ps1"
```

#### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/uninstall.sh | bash
```

---

## How It Works

```
Spotify playback
  → ivLyrics sends track title + artist
  → Local server detects song language via MusicBrainz
  → Searches YouTube Music / MV for captions in that language
  → Manual captions preferred, auto-captions as fallback
  → Returns LRC format → displayed in ivLyrics
```

## License

MIT