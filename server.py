"""
ivLyrics YouTube Caption Server
VPS용 외부 서버 - yt-dlp를 이용해 YouTube 공식 자막을 추출하여 LRC 포맷으로 반환합니다.

요구사항 설치:
    pip install fastapi uvicorn yt-dlp python-dotenv

실행:
    uvicorn server:app --host 0.0.0.0 --port 8080

환경변수 (.env):
    CACHE_TTL=86400        # 캐시 유지 시간 (초), 기본 24시간
    API_SECRET=your_key    # 선택: Bearer 토큰 인증 활성화 시 설정
"""

import os
import re
import json
import tempfile
import asyncio
import hashlib
import time
import sys
import subprocess
import shutil
from pathlib import Path
from typing import Optional

import urllib.request
import urllib.parse
import yt_dlp
from fastapi import FastAPI, HTTPException, Query, Header, WebSocket
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv

load_dotenv()

# ─── 버전 정보 ────────────────────────────────────────────────────────────────
SERVER_VERSION = "1.0.1"
GITHUB_VERSION_URL = "https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/version.json"
GITHUB_SERVER_URL  = "https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/server.py"

def _fetch_latest_version() -> dict:
    """GitHub에서 최신 버전 정보 가져오기"""
    try:
        req = urllib.request.Request(
            GITHUB_VERSION_URL,
            headers={"Cache-Control": "no-cache", "Pragma": "no-cache"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read())
    except Exception:
        return {}

def _do_self_update(latest_version: str):
    """server.py 자동 업데이트 후 재시작"""
    log.info(f"[업데이트] {SERVER_VERSION} → {latest_version} 업데이트 시작")
    try:
        server_path = Path(__file__).resolve()
        backup_path = server_path.with_suffix('.py.bak')

        # 백업
        shutil.copy2(server_path, backup_path)

        # 새 버전 다운로드
        req = urllib.request.Request(
            GITHUB_SERVER_URL,
            headers={"Cache-Control": "no-cache", "Pragma": "no-cache"}
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            new_code = resp.read()

        server_path.write_bytes(new_code)
        log.info("[업데이트] 다운로드 완료, 서버 재시작 중...")

        # 현재 프로세스 재시작
        os.execv(sys.executable, [sys.executable] + sys.argv)

    except Exception as e:
        log.error(f"[업데이트] 실패: {e}")
        # 백업 복구
        if backup_path.exists():
            shutil.copy2(backup_path, server_path)

async def _check_and_update():
    """서버 시작 시 업데이트 확인 (백그라운드)"""
    await asyncio.sleep(3)  # 서버 완전히 시작된 후 확인
    try:
        info = await asyncio.to_thread(_fetch_latest_version)
        latest = info.get("server", "")
        if latest and latest != SERVER_VERSION:
            log.info(f"[업데이트] 새 버전 발견: {latest} (현재: {SERVER_VERSION})")
            auto_update = os.getenv("AUTO_UPDATE", "true").lower() == "true"
            if auto_update:
                await asyncio.to_thread(_do_self_update, latest)
            else:
                log.info("[업데이트] AUTO_UPDATE=false, 자동 업데이트 건너뜀")
        else:
            log.debug(f"[업데이트] 최신 버전 사용 중 ({SERVER_VERSION})")
    except Exception as e:
        log.warning(f"[업데이트] 확인 실패: {e}")

# ─── 로깅 설정 ────────────────────────────────────────────────────────────────
import logging

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("ivLyrics")


app = FastAPI(
    title="ivLyrics YouTube Caption Server",
    description="yt-dlp 기반 YouTube 공식 자막 → LRC 변환 API",
    version=SERVER_VERSION,
)

@app.on_event("startup")
async def on_startup():
    log.info(f"[서버] ivLyrics YouTube Caption Server v{SERVER_VERSION} 시작")
    asyncio.create_task(_check_and_update())

# ─── CORS ─────────────────────────────────────────────────────────────────────
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET"],
    allow_headers=["*"],
)

# ─── 인메모리 캐시 ────────────────────────────────────────────────────────────
_cache: dict = {}
CACHE_TTL = int(os.getenv("CACHE_TTL", 86400))
API_SECRET = os.getenv("API_SECRET", "")  # 비어있으면 인증 비활성화


def cache_get(key: str):
    if key in _cache:
        ts, val = _cache[key]
        if time.time() - ts < CACHE_TTL:
            return val
        del _cache[key]
    return None


def cache_set(key: str, val):
    _cache[key] = (time.time(), val)


def make_key(*args) -> str:
    return hashlib.md5("|".join(str(a) for a in args).encode()).hexdigest()


def verify_secret(authorization: Optional[str]):
    """API_SECRET 설정 시 Bearer 토큰 검증"""
    if not API_SECRET:
        return
    if not authorization or authorization != f"Bearer {API_SECRET}":
        raise HTTPException(status_code=401, detail="Unauthorized")


# ─── yt-dlp 핵심 함수 ─────────────────────────────────────────────────────────

def _search_ytmusic(title: str, artist: str, max_results: int = 5) -> list[str]:
    """
    YouTube Music에서 검색 → video_id 목록 반환
    YouTube Music은 곡이 바로 시작돼 Spotify와 타이밍이 일치함
    """
    query = f"{artist} {title}"
    log.info(f"[YTMusic검색] 쿼리: '{query}' (최대 {max_results}개)")
    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
    }
    # ytmsearch 시도 → 실패 시 music.youtube.com 검색으로 fallback
    for search_prefix in [f"ytmsearch{max_results}", "ytsearch5"]:
        try:
            query_str = query if search_prefix.startswith("ytsearch") else query
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                result = ydl.extract_info(f"{search_prefix}:{query_str}", download=False)
            if not result or "entries" not in result:
                continue
            ids = [e["id"] for e in result["entries"] if e and e.get("id")]
            if not ids:
                continue
            for e in result["entries"]:
                if e and e.get("id"):
                    log.debug(f"[YTMusic검색]   → {e['id']} | {e.get('title','?')}")
            log.info(f"[YTMusic검색] {len(ids)}개 찾음 (방식={search_prefix})")
            return ids
        except Exception as e:
            log.warning(f"[YTMusic검색] {search_prefix} 실패: {e}")
            continue
    return []


def _search_videos(title: str, artist: str, max_results: int = 10) -> list[str]:
    """
    YouTube에서 검색 → video_id 목록 반환 (MV fallback용)

    정렬 우선순위:
      1. 공식/VEVO 채널 또는 제목에 official/mv 키워드 포함
      2. 나머지 결과
    """
    query = f"{artist} {title} official mv"
    log.info(f"[YT검색] 쿼리: '{query}' (최대 {max_results}개)")
    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
    }
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            result = ydl.extract_info(f"ytsearch{max_results}:{query}", download=False)
    except Exception as e:
        log.warning(f"[YT검색] 실패: {e}")
        return []

    if not result or "entries" not in result:
        log.warning("[YT검색] 결과 없음")
        return []

    entries = [e for e in result["entries"] if e and e.get("id")]
    if not entries:
        return []

    official_keywords = ["vevo", "official", "공식", "뮤직비디오", "music video", "mv"]
    official, others = [], []
    for entry in entries:
        channel  = (entry.get("channel") or entry.get("uploader") or "").lower()
        yt_title = (entry.get("title") or "").lower()
        is_official = any(kw in channel or kw in yt_title for kw in official_keywords)
        log.debug(f"[YT검색]   {'★' if is_official else ' '} {entry['id']} | {entry.get('title','?')} | ch={entry.get('channel','?')}")
        if is_official:
            official.append(entry["id"])
        else:
            others.append(entry["id"])

    log.info(f"[YT검색] 공식 {len(official)}개 + 기타 {len(others)}개")
    return official + others


def _detect_lang(title: str, artist: str) -> Optional[str]:
    """
    MusicBrainz API로 곡의 원본 언어 감지.
    반환: BCP-47 언어 코드 (예: 'ja', 'ko', 'en') 또는 None (감지 실패)

    MusicBrainz는 ISO 639-3 코드(jpn, kor, eng 등)를 반환하므로 BCP-47로 변환.
    """
    # ISO 639-3 → BCP-47 변환 테이블
    ISO3_TO_BCP47 = {
        "jpn": "ja", "kor": "ko", "eng": "en", "zho": "zh",
        "cmn": "zh", "yue": "zh", "spa": "es", "fra": "fr",
        "deu": "de", "ita": "it", "por": "pt", "rus": "ru",
        "ara": "ar", "hin": "hi", "tha": "th", "vie": "vi",
        "ind": "id", "nld": "nl", "pol": "pl", "tur": "tr",
        "swe": "sv", "nor": "no", "dan": "da", "fin": "fi",
    }

    log.info(f"[언어감지] MusicBrainz 검색: '{title}' by '{artist}'")
    try:
        query = urllib.parse.urlencode({
            "query": f'recording:"{title}" AND artist:"{artist}"',
            "fmt": "json",
            "limit": "5",
        })
        url = f"https://musicbrainz.org/ws/2/recording/?{query}"
        req = urllib.request.Request(url, headers={
            "User-Agent": "ivLyrics/1.0 (https://github.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider)"
        })
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = __import__("json").loads(resp.read())

        recordings = data.get("recordings", [])
        log.debug(f"[언어감지] MusicBrainz 결과 {len(recordings)}개")
        for rec in recordings:
            lang = rec.get("language") or ""
            lang = lang.strip().lower()
            log.debug(f"[언어감지]   → recording='{rec.get('title')}', language='{lang}'")
            if lang and lang != "zxx" and lang != "mul":
                bcp47 = ISO3_TO_BCP47.get(lang, lang[:2])
                log.info(f"[언어감지] 감지 성공: {lang} → {bcp47}")
                return bcp47

        log.warning("[언어감지] MusicBrainz에서 언어 정보를 찾지 못함")
    except Exception as e:
        log.warning(f"[언어감지] MusicBrainz 요청 실패: {e}")

    # MusicBrainz 실패 시 제목+아티스트 문자 분포로 fallback
    text = f"{title} {artist}"
    ko  = sum(1 for c in text if "가" <= c <= "힣" or "ᄀ" <= c <= "ᇿ")
    ja_kana = sum(1 for c in text if "぀" <= c <= "ヿ")
    zh_han  = sum(1 for c in text if "一" <= c <= "鿿")
    ja  = ja_kana + (zh_han if ja_kana > 0 else 0)
    ar  = sum(1 for c in text if "؀" <= c <= "ۿ")
    ru  = sum(1 for c in text if "Ѐ" <= c <= "ӿ")
    th  = sum(1 for c in text if "฀" <= c <= "๿")

    scores = {"ko": ko, "ja": ja, "zh": zh_han, "ar": ar, "ru": ru, "th": th}
    best = max(scores, key=lambda k: scores[k])
    if scores[best] > 0:
        log.info(f"[언어감지] 문자 분포 fallback: {best} (점수={scores[best]})")
        return best

    log.warning("[언어감지] 언어 감지 완전 실패 → None 반환")
    return None


def _pick_best_lang(available: list[str], preferred: Optional[str] = None) -> Optional[str]:
    """
    자막 언어 목록에서 preferred에 가장 가까운 언어 선택.

    preferred가 있을 때:
      1. 정확히 일치 (예: preferred='ko', available에 'ko' 있음)
      2. 접두어 일치 (예: preferred='ja' → 'ja-JP' 등)
      3. 일치하는 언어 없으면 → None (해당 언어 자막 없음으로 처리)

    preferred가 없을 때 (언어 감지 실패):
      '-orig' 태그 또는 첫 번째 언어 반환
    """
    if not available:
        return None

    if preferred:
        # 1. 정확히 일치
        if preferred in available:
            return preferred
        # 2. 접두어 일치 (ja → ja-JP, zh → zh-Hans 등)
        prefix = preferred.split("-")[0]
        for lang in available:
            if lang.startswith(prefix):
                return lang
        # 3. 일치하는 언어 없음 → None
        return None

    # preferred 없을 때: '-orig' 태그 또는 첫 번째
    for lang in available:
        if lang.endswith("-orig"):
            return lang
    return available[0]


def _fetch_captions(video_id: str, preferred_lang: Optional[str] = None) -> Optional[dict]:
    """
    video_id → 자막 데이터 반환 (2단계)

    1단계: 자막 목록만 조회 (다운로드 없음) → 어떤 언어가 있는지 파악
    2단계: preferred_lang에 가장 가까운 언어 하나만 다운로드 → 429 방지

    반환: {"captions": [...], "source": "manual"|"auto", "lang": str}
    """
    url = f"https://www.youtube.com/watch?v={video_id}"
    log.info(f"[자막조회] video_id={video_id}, preferred_lang={preferred_lang}")

    # ── 1단계: 자막 목록 조회 ────────────────────────────────────────────────
    list_opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "writesubtitles": False,
        "writeautomaticsub": False,
        "ignoreerrors": True,
        "retries": 3,
        "sleep_interval": 1,
    }
    try:
        with yt_dlp.YoutubeDL(list_opts) as ydl:
            info = ydl.extract_info(url, download=False)
    except Exception:
        return None

    if not info:
        return None

    manual_langs = list(info.get("subtitles", {}).keys())
    auto_langs   = list(info.get("automatic_captions", {}).keys())
    log.debug(f"[자막조회]   수동자막: {manual_langs}")
    log.debug(f"[자막조회]   자동자막: {auto_langs[:10]}{'...' if len(auto_langs)>10 else ''}")

    # 수동 자막 우선, 없으면 자동 자막
    # preferred_lang과 일치하는 언어가 없으면 None 반환 (해당 영상 건너뜀)
    chosen_lang = None
    source = None

    if manual_langs:
        chosen_lang = _pick_best_lang(manual_langs, preferred_lang)
        if chosen_lang:
            source = "manual"
            log.info(f"[자막조회]   ✓ 수동자막 선택: {chosen_lang}")
        else:
            log.debug(f"[자막조회]   수동자막에 '{preferred_lang}' 없음")

    if not chosen_lang and auto_langs:
        chosen_lang = _pick_best_lang(auto_langs, preferred_lang)
        if chosen_lang:
            source = "auto"
            log.info(f"[자막조회]   ✓ 자동자막 선택: {chosen_lang}")
        else:
            log.debug(f"[자막조회]   자동자막에 '{preferred_lang}' 없음")

    if not chosen_lang:
        log.warning(f"[자막조회]   ✗ '{preferred_lang}' 자막 없음 → 이 영상 건너뜀")
        return None

    # ── 2단계: 선택된 언어 하나만 다운로드 ─────────────────────────────────
    with tempfile.TemporaryDirectory() as tmpdir:
        dl_opts = {
            "quiet": True,
            "no_warnings": True,
            "skip_download": True,
            "writesubtitles":    source == "manual",
            "writeautomaticsub": source == "auto",
            "subtitlesformat": "json3",
            "subtitleslangs": [chosen_lang],   # 딱 하나만 요청
            "ignoreerrors": True,              # 429 등 에러 시 예외 대신 None 반환
            "outtmpl": str(Path(tmpdir) / "%(id)s.%(ext)s"),
            # 429 대비 재시도
            "retries": 3,
            "sleep_interval": 2,
            "sleep_interval_subtitles": 2,
        }
        try:
            with yt_dlp.YoutubeDL(dl_opts) as ydl:
                ydl.extract_info(url, download=True)
        except Exception:
            return None  # 다운로드 실패 시 None → 다음 후보로 넘어감

        all_files = list(Path(tmpdir).glob(f"{video_id}.*.json3"))
        if not all_files:
            log.warning(f"[자막조회]   ✗ 다운로드 후 파일 없음 (video_id={video_id})")
            return None

        chosen_file = all_files[0]
        raw = chosen_file.read_text(encoding="utf-8")
        captions = _parse_json3(raw)
        log.info(f"[자막조회]   ✓ 자막 파싱 완료: {len(captions)}줄 (source={source}, lang={chosen_lang})")

        return {
            "captions": captions,
            "source": source,
            "lang": chosen_lang,
        }



def _parse_json3(raw: str) -> list:
    """
    YouTube json3 자막 파싱
    형식: {"events": [{"tStartMs": N, "dDurationMs": N, "segs": [{"utf8": "..."}]}]}
    반환: [{"startMs": int, "endMs": int, "text": str}]
    """
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []

    result = []
    for event in data.get("events", []):
        start_ms = event.get("tStartMs", 0)
        dur_ms = event.get("dDurationMs", 0)
        segs = event.get("segs", [])

        text = "".join(s.get("utf8", "") for s in segs)
        text = re.sub(r"[\n\r]+", " ", text).strip()

        # 뮤직 기호, 빈 줄 필터링
        if not text or text in ("♪", "♫", "♪♪", "[Music]", "[음악]"):
            continue

        result.append({
            "startMs": start_ms,
            "endMs": start_ms + dur_ms,
            "text": text,
        })

    return result


def _to_lrc(captions: list) -> str:
    """타임스탬프 리스트 → LRC 포맷"""
    lines = []
    for cap in captions:
        ms = cap["startMs"]
        m = ms // 60000
        s = (ms % 60000) / 1000
        lines.append(f"[{m:02d}:{s:05.2f}]{cap['text']}")
    return "\n".join(lines)



# ─── RMS 볼륨 기반 노래 시작점 감지 (싱크 오프셋 계산) ──────────────────────






# ─── API 엔드포인트 ────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    """서버 상태 확인 + 업데이트 정보"""
    info = await asyncio.to_thread(_fetch_latest_version)
    latest_server = info.get("server", SERVER_VERSION)
    latest_addon  = info.get("addon", "")
    has_update    = latest_server != SERVER_VERSION

    return {
        "status": "ok",
        "version": SERVER_VERSION,
        "latestVersion": latest_server,
        "addonVersion": latest_addon,
        "hasUpdate": has_update,
        "autoUpdate": os.getenv("AUTO_UPDATE", "true").lower() == "true",
    }

@app.post("/update")
async def trigger_update(authorization: Optional[str] = Header(None)):
    """수동 업데이트 트리거"""
    verify_secret(authorization)
    info = await asyncio.to_thread(_fetch_latest_version)
    latest = info.get("server", "")
    if not latest or latest == SERVER_VERSION:
        return {"status": "up-to-date", "version": SERVER_VERSION}
    asyncio.create_task(asyncio.to_thread(_do_self_update, latest))
    return {"status": "updating", "from": SERVER_VERSION, "to": latest}


@app.get("/captions")
async def get_captions(
    title: str = Query(..., description="곡 제목"),
    artist: str = Query(..., description="아티스트명"),
    format: str = Query("lrc", description="반환 포맷: lrc | json"),
    videoId: Optional[str] = Query(None, description="YouTube video_id 직접 지정 (선택)"),
    authorization: Optional[str] = Header(None),
):
    """
    메인 엔드포인트
    곡 제목 + 아티스트 → YouTube 검색 → 공식 자막 추출 → LRC 또는 JSON 반환
    previewUrl 제공 시 오디오 핑거프린팅으로 MV 인트로 오프셋 자동 보정.

    LRC 응답 예시:
    {
      "videoId": "dQw4w9WgXcQ",
      "source": "manual",
      "lang": "ko",
      "offsetMs": 15000,
      "lrc": "[00:13.37]Never gonna give you up\\n[00:17.00]..."
    }
    """
    verify_secret(authorization)

    cache_key = make_key("captions", title, artist, videoId, format)
    if cached := cache_get(cache_key):
        return {**cached, "cached": True}

    log.info(f"[요청] title='{title}', artist='{artist}', videoId={videoId}")

    # 1. MusicBrainz로 곡 언어 감지
    preferred_lang = _detect_lang(title, artist)
    log.info(f"[요청] 감지된 언어: {preferred_lang}")

    # 2. YouTube Music 우선 검색 → 없으면 YouTube MV fallback
    vid = None
    result = None

    if videoId:
        # 직접 지정된 경우
        result = await asyncio.to_thread(_fetch_captions, videoId, preferred_lang)
        if result and result["captions"]:
            vid = videoId

    if not vid:
        log.info('[검색] YouTube Music 우선 검색 시작')
        # ── 1단계: YouTube Music 검색 (타이밍이 Spotify와 일치) ──────────────
        ytm_candidates = await asyncio.to_thread(_search_ytmusic, title, artist)
        fetched: dict = {}

        for candidate in ytm_candidates:
            r = await asyncio.to_thread(_fetch_captions, candidate, preferred_lang)
            fetched[candidate] = r
            if r and r["captions"] and r["source"] == "manual":
                vid, result = candidate, r
                break

        if not vid:
            for candidate in ytm_candidates:
                r = fetched.get(candidate)
                if r and r["captions"]:
                    vid, result = candidate, r
                    break

    if not vid:
        log.info('[검색] YouTube Music에서 자막 없음 → YouTube MV fallback')
        # ── 2단계: YouTube MV fallback (수동 자막 우선, 자동 자막 후순위) ────
        mv_candidates = await asyncio.to_thread(_search_videos, title, artist)
        if not mv_candidates:
            raise HTTPException(
                status_code=404,
                detail=f"'{artist} - {title}' YouTube 영상을 찾을 수 없습니다."
            )

        fetched_mv: dict = {}
        for candidate in mv_candidates:
            r = await asyncio.to_thread(_fetch_captions, candidate, preferred_lang)
            fetched_mv[candidate] = r
            if r and r["captions"] and r["source"] == "manual":
                vid, result = candidate, r
                break

        if not vid:
            for candidate in mv_candidates:
                r = fetched_mv.get(candidate)
                if r and r["captions"]:
                    vid, result = candidate, r
                    break

    if not vid or not result or not result["captions"]:
        raise HTTPException(
            status_code=404,
            detail=f"'{artist} - {title}' 자막이 있는 영상을 찾을 수 없습니다."
        )


    log.info(f"[완료] videoId={vid}, source={result['source']}, lang={result['lang']}, lines={len(result['captions'])}")

    response = {
        "videoId": vid,
        "youtubeUrl": f"https://www.youtube.com/watch?v={vid}",
        "title": title,
        "artist": artist,
        "source": result["source"],   # "manual" | "auto"
        "lang": result["lang"],
        "captionCount": len(result["captions"]),
        "cached": False,
    }

    if format == "json":
        response["captions"] = result["captions"]
    else:
        response["lrc"] = _to_lrc(result["captions"])

    cache_set(cache_key, response)
    return response


@app.get("/captions/by-id")
async def get_captions_by_id(
    videoId: str = Query(..., description="YouTube video ID"),
    format: str = Query("lrc", description="반환 포맷: lrc | json"),
    authorization: Optional[str] = Header(None),
):
    """video_id 직접 지정으로 자막 추출 (VideoBackground 연동용)"""
    verify_secret(authorization)

    cache_key = make_key("by_id", videoId, format)
    if cached := cache_get(cache_key):
        return {**cached, "cached": True}

    result = await asyncio.to_thread(_fetch_captions, videoId)
    if not result or not result["captions"]:
        raise HTTPException(
            status_code=404,
            detail=f"'{videoId}' 영상에서 자막을 찾을 수 없습니다."
        )

    response = {
        "videoId": videoId,
        "youtubeUrl": f"https://www.youtube.com/watch?v={videoId}",
        "source": result["source"],
        "lang": result["lang"],
        "captionCount": len(result["captions"]),
        "cached": False,
    }

    if format == "json":
        response["captions"] = result["captions"]
    else:
        response["lrc"] = _to_lrc(result["captions"])

    cache_set(cache_key, response)
    return response


@app.delete("/cache")
async def clear_cache(authorization: Optional[str] = Header(None)):
    """캐시 전체 삭제 (관리용)"""
    verify_secret(authorization)
    count = len(_cache)
    _cache.clear()
    return {"deleted": count}

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    """ivLyrics WebSocket 연결 수락 (핑/퐁만 처리)"""
    await websocket.accept()
    try:
        while True:
            await websocket.receive_text()
    except Exception:
        pass
