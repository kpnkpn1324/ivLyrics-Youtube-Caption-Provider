/**
 * ivLyrics YouTube Caption Server (Node.js)
 * yt-dlp 바이너리를 child_process로 실행하여 YouTube 자막 추출
 *
 * 요구사항:
 *   - Node.js v18+
 *   - yt-dlp 바이너리 (자동 다운로드 또는 PATH에 있어야 함)
 *
 * 실행:
 *   node server.js
 *
 * 환경변수 (.env):
 *   PORT=8080
 *   CACHE_TTL=86400
 *   API_SECRET=your_key
 *   AUTO_UPDATE=true
 *   YTDLP_PATH=   # yt-dlp 바이너리 경로 (비어있으면 자동 탐색)
 */

'use strict';

require('dotenv').config();

const express    = require('express');
const cors       = require('cors');
const { execFile, exec } = require('child_process');
const { promisify } = require('util');
const execFileAsync = promisify(execFile);
const fs         = require('fs');
const fsp        = fs.promises;
const path       = require('path');
const os         = require('os');
const crypto     = require('crypto');
const https      = require('https');
const http       = require('http');

// ─── 버전 정보 ────────────────────────────────────────────────────────────────
const SERVER_VERSION     = '1.0.0';
const GITHUB_VERSION_URL = 'https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/version.json';
const GITHUB_SERVER_URL  = 'https://raw.githubusercontent.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider/main/server.js';

// ─── 설정 ─────────────────────────────────────────────────────────────────────
const PORT        = parseInt(process.env.PORT || '8080', 10);
const CACHE_TTL   = parseInt(process.env.CACHE_TTL || '86400', 10) * 1000;
const API_SECRET  = process.env.API_SECRET || '';
const AUTO_UPDATE = (process.env.AUTO_UPDATE || 'true').toLowerCase() === 'true';

// ─── 로깅 ─────────────────────────────────────────────────────────────────────
const log = {
  time: () => new Date().toTimeString().slice(0, 8),
  info:  (...a) => console.log(`${log.time()} [INFO]`, ...a),
  debug: (...a) => console.log(`${log.time()} [DEBUG]`, ...a),
  warn:  (...a) => console.warn(`${log.time()} [WARN]`, ...a),
  error: (...a) => console.error(`${log.time()} [ERROR]`, ...a),
};

// ─── yt-dlp 경로 탐색 ────────────────────────────────────────────────────────
function findYtdlp() {
  // 환경변수 우선
  if (process.env.YTDLP_PATH) return process.env.YTDLP_PATH;

  const isWin = process.platform === 'win32';
  const bin   = isWin ? 'yt-dlp.exe' : 'yt-dlp';

  // 서버 파일 옆에 있는지 확인
  const local = path.join(__dirname, bin);
  if (fs.existsSync(local)) return local;

  // PATH에서 탐색
  const pathDirs = (process.env.PATH || '').split(path.delimiter);
  for (const dir of pathDirs) {
    const full = path.join(dir, bin);
    if (fs.existsSync(full)) return full;
  }

  return bin; // fallback: PATH에서 찾길 기대
}

let YTDLP_PATH = findYtdlp();

// ─── yt-dlp 자동 다운로드 ────────────────────────────────────────────────────
async function downloadYtdlp() {
  const isWin = process.platform === 'win32';
  const bin   = isWin ? 'yt-dlp.exe' : 'yt-dlp';
  const dest  = path.join(__dirname, bin);

  const url = isWin
    ? 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
    : 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp';

  log.info(`[yt-dlp] 다운로드 중: ${url}`);
  await downloadFile(url, dest);

  if (!isWin) {
    await fsp.chmod(dest, 0o755);
  }

  YTDLP_PATH = dest;
  log.info(`[yt-dlp] 다운로드 완료: ${dest}`);
}

function downloadFile(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);
    const get  = url.startsWith('https') ? https : http;

    const request = (reqUrl) => {
      get.get(reqUrl, (res) => {
        if (res.statusCode === 301 || res.statusCode === 302) {
          file.close();
          request(res.headers.location);
          return;
        }
        res.pipe(file);
        file.on('finish', () => { file.close(); resolve(); });
      }).on('error', (e) => { fs.unlink(dest, () => {}); reject(e); });
    };
    request(url);
  });
}

// ─── 캐시 ─────────────────────────────────────────────────────────────────────
const cache = new Map();

function cacheGet(key) {
  const item = cache.get(key);
  if (!item) return null;
  if (Date.now() - item.ts > CACHE_TTL) { cache.delete(key); return null; }
  return item.val;
}

function cacheSet(key, val) {
  cache.set(key, { ts: Date.now(), val });
}

function makeKey(...args) {
  return crypto.createHash('md5').update(args.join('|')).digest('hex');
}

// ─── 인증 ─────────────────────────────────────────────────────────────────────
function verifySecret(req, res) {
  if (!API_SECRET) return true;
  const auth = req.headers['authorization'] || '';
  if (auth !== `Bearer ${API_SECRET}`) {
    res.status(401).json({ detail: 'Unauthorized' });
    return false;
  }
  return true;
}

// ─── yt-dlp 실행 헬퍼 ────────────────────────────────────────────────────────
async function ytdlp(args, timeout = 60000) {
  const { stdout, stderr } = await execFileAsync(YTDLP_PATH, args, {
    timeout,
    maxBuffer: 50 * 1024 * 1024,
  });
  return { stdout, stderr };
}

// ─── 언어 감지 (MusicBrainz) ─────────────────────────────────────────────────
const ISO3_TO_BCP47 = {
  jpn:'ja', kor:'ko', eng:'en', zho:'zh', cmn:'zh', yue:'zh',
  spa:'es', fra:'fr', deu:'de', ita:'it', por:'pt', rus:'ru',
  ara:'ar', hin:'hi', tha:'th', vie:'vi', ind:'id', nld:'nl',
  pol:'pl', tur:'tr', swe:'sv', nor:'no', dan:'da', fin:'fi',
};

async function detectLang(title, artist) {
  log.info(`[언어감지] MusicBrainz: '${title}' by '${artist}'`);
  try {
    const params = new URLSearchParams({
      query: `recording:"${title}" AND artist:"${artist}"`,
      fmt: 'json',
      limit: '5',
    });
    const url  = `https://musicbrainz.org/ws/2/recording/?${params}`;
    const data = await fetchJson(url, {
      'User-Agent': 'ivLyrics/1.0 (https://github.com/kpnkpn1324/ivLyrics-Youtube-Caption-Provider)',
      'Cache-Control': 'no-cache',
    });

    for (const rec of (data.recordings || [])) {
      const lang = (rec.language || '').toLowerCase().trim();
      if (lang && lang !== 'zxx' && lang !== 'mul') {
        const bcp47 = ISO3_TO_BCP47[lang] || lang.slice(0, 2);
        log.info(`[언어감지] 감지 성공: ${lang} → ${bcp47}`);
        return bcp47;
      }
    }
    log.warn('[언어감지] MusicBrainz에서 언어 정보 없음');
  } catch (e) {
    log.warn(`[언어감지] MusicBrainz 실패: ${e.message}`);
  }

  // fallback: 문자 분포 분석
  const text = `${title} ${artist}`;
  const ko = [...text].filter(c => c >= '\uAC00' && c <= '\uD7A3').length;
  const ja = [...text].filter(c => c >= '\u3040' && c <= '\u30FF').length;
  const zh = [...text].filter(c => c >= '\u4E00' && c <= '\u9FFF').length;
  const scores = { ko, ja: ja + (ja > 0 ? zh : 0), zh, ru: 0, ar: 0, th: 0 };
  const best = Object.entries(scores).sort((a, b) => b[1] - a[1])[0];
  if (best[1] > 0) {
    log.info(`[언어감지] 문자 분포 fallback: ${best[0]}`);
    return best[0];
  }

  return null;
}

// ─── YouTube 검색 ─────────────────────────────────────────────────────────────
async function searchYtMusic(title, artist, maxResults = 5) {
  const query = `${artist} ${title}`;
  log.info(`[YTMusic검색] '${query}'`);

  for (const prefix of [`ytmsearch${maxResults}`, `ytsearch${maxResults}`]) {
    try {
      const { stdout } = await ytdlp([
        '--flat-playlist', '--dump-json', '--quiet', '--no-warnings',
        `${prefix}:${query}`,
      ], 30000);

      const ids = stdout.trim().split('\n')
        .filter(Boolean)
        .map(line => { try { return JSON.parse(line).id; } catch { return null; } })
        .filter(Boolean);

      if (ids.length > 0) {
        log.info(`[YTMusic검색] ${ids.length}개 (방식=${prefix})`);
        ids.forEach(id => log.debug(`[YTMusic검색]   → ${id}`));
        return ids;
      }
    } catch (e) {
      log.warn(`[YTMusic검색] ${prefix} 실패: ${e.message}`);
    }
  }
  return [];
}

async function searchVideos(title, artist, maxResults = 10) {
  const query = `${artist} ${title} official mv`;
  log.info(`[YT검색] '${query}'`);

  try {
    const { stdout } = await ytdlp([
      '--flat-playlist', '--dump-json', '--quiet', '--no-warnings',
      `ytsearch${maxResults}:${query}`,
    ], 30000);

    const entries = stdout.trim().split('\n')
      .filter(Boolean)
      .map(line => { try { return JSON.parse(line); } catch { return null; } })
      .filter(Boolean);

    const keywords = ['vevo', 'official', '공식', '뮤직비디오', 'music video', 'mv'];
    const official = [], others = [];

    for (const e of entries) {
      const ch    = (e.channel || e.uploader || '').toLowerCase();
      const titl  = (e.title || '').toLowerCase();
      const isOff = keywords.some(kw => ch.includes(kw) || titl.includes(kw));
      log.debug(`[YT검색]   ${isOff ? '★' : ' '} ${e.id} | ${e.title}`);
      isOff ? official.push(e.id) : others.push(e.id);
    }

    log.info(`[YT검색] 공식 ${official.length}개 + 기타 ${others.length}개`);
    return [...official, ...others];
  } catch (e) {
    log.warn(`[YT검색] 실패: ${e.message}`);
    return [];
  }
}

// ─── 자막 조회 + 다운로드 ────────────────────────────────────────────────────
function pickBestLang(available, preferred) {
  if (!available.length) return null;
  if (preferred) {
    if (available.includes(preferred)) return preferred;
    const prefix = preferred.split('-')[0];
    const match  = available.find(l => l.startsWith(prefix));
    if (match) return match;
    return null; // 해당 언어 없음
  }
  return available.find(l => l.endsWith('-orig')) || available[0];
}

async function fetchCaptions(videoId, preferredLang) {
  const url = `https://www.youtube.com/watch?v=${videoId}`;
  log.info(`[자막조회] ${videoId}, preferred=${preferredLang}`);

  // 1단계: 자막 목록 조회
  let info;
  try {
    const { stdout } = await ytdlp([
      '--dump-json', '--quiet', '--no-warnings',
      '--skip-download', url,
    ], 30000);
    info = JSON.parse(stdout);
  } catch (e) {
    log.warn(`[자막조회] 정보 조회 실패: ${e.message}`);
    return null;
  }

  const manualLangs = Object.keys(info.subtitles || {});
  const autoLangs   = Object.keys(info.automatic_captions || {});
  log.debug(`[자막조회]   수동: ${manualLangs}`);
  log.debug(`[자막조회]   자동: ${autoLangs.slice(0, 10)}`);

  let chosenLang = null;
  let source     = null;

  chosenLang = pickBestLang(manualLangs, preferredLang);
  if (chosenLang) {
    source = 'manual';
    log.info(`[자막조회]   ✓ 수동자막: ${chosenLang}`);
  } else {
    chosenLang = pickBestLang(autoLangs, preferredLang);
    if (chosenLang) {
      source = 'auto';
      log.info(`[자막조회]   ✓ 자동자막: ${chosenLang}`);
    }
  }

  if (!chosenLang) {
    log.warn(`[자막조회]   ✗ '${preferredLang}' 자막 없음`);
    return null;
  }

  // 2단계: 선택된 언어 하나만 다운로드
  const tmpDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'ytcaption-'));
  try {
    const outTmpl = path.join(tmpDir, '%(id)s.%(ext)s');
    const dlArgs  = [
      '--quiet', '--no-warnings',
      '--skip-download',
      source === 'manual' ? '--write-subs' : '--write-auto-subs',
      '--sub-format', 'json3',
      '--sub-langs', chosenLang,
      '--retries', '3',
      '--sleep-interval', '2',
      '-o', outTmpl,
      url,
    ];

    try {
      await ytdlp(dlArgs, 60000);
    } catch (e) {
      log.warn(`[자막조회] 다운로드 실패: ${e.message}`);
      return null;
    }

    const files = fs.readdirSync(tmpDir).filter(f => f.endsWith('.json3'));
    if (!files.length) {
      log.warn('[자막조회] json3 파일 없음');
      return null;
    }

    const raw      = await fsp.readFile(path.join(tmpDir, files[0]), 'utf-8');
    const captions = parseJson3(raw);
    log.info(`[자막조회]   ✓ ${captions.length}줄 (source=${source}, lang=${chosenLang})`);

    return { captions, source, lang: chosenLang };
  } finally {
    fsp.rm(tmpDir, { recursive: true, force: true }).catch(() => {});
  }
}

// ─── json3 파싱 ───────────────────────────────────────────────────────────────
function parseJson3(raw) {
  let data;
  try { data = JSON.parse(raw); } catch { return []; }

  const result = [];
  for (const event of (data.events || [])) {
    const startMs = event.tStartMs || 0;
    const durMs   = event.dDurationMs || 0;
    const text    = (event.segs || [])
      .map(s => s.utf8 || '')
      .join('')
      .replace(/[\n\r]+/g, ' ')
      .trim();

    if (!text || ['♪','♫','♪♪','[Music]','[음악]'].includes(text)) continue;

    result.push({ startMs, endMs: startMs + durMs, text });
  }
  return result;
}

function toLrc(captions) {
  return captions.map(cap => {
    const m  = Math.floor(cap.startMs / 60000);
    const s  = (cap.startMs % 60000) / 1000;
    return `[${String(m).padStart(2,'0')}:${s.toFixed(2).padStart(5,'0')}]${cap.text}`;
  }).join('\n');
}

// ─── HTTP 유틸 ────────────────────────────────────────────────────────────────
function fetchJson(url, headers = {}) {
  return new Promise((resolve, reject) => {
    const get = url.startsWith('https') ? https : http;
    get.get(url, { headers }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch (e) { reject(e); }
      });
    }).on('error', reject).setTimeout(8000, function() { this.destroy(); });
  });
}

// ─── 자동 업데이트 ────────────────────────────────────────────────────────────
async function checkAndUpdate() {
  try {
    const info   = await fetchJson(GITHUB_VERSION_URL + '?ts=' + Date.now());
    const latest = info.server || '';
    if (latest && latest !== SERVER_VERSION) {
      log.info(`[업데이트] 새 버전: ${latest} (현재: ${SERVER_VERSION})`);
      if (AUTO_UPDATE) await doSelfUpdate(latest);
    } else {
      log.debug(`[업데이트] 최신 버전 (${SERVER_VERSION})`);
    }
  } catch (e) {
    log.warn(`[업데이트] 확인 실패: ${e.message}`);
  }
}

async function doSelfUpdate(latestVersion) {
  const serverPath = __filename;
  const backupPath = serverPath + '.bak';
  log.info(`[업데이트] ${SERVER_VERSION} → ${latestVersion}`);
  try {
    await fsp.copyFile(serverPath, backupPath);
    await downloadFile(GITHUB_SERVER_URL + '?ts=' + Date.now(), serverPath);
    log.info('[업데이트] 완료, 재시작 중...');
    process.on('exit', () => {
      require('child_process').spawn(process.argv[0], process.argv.slice(1), {
        detached: true, stdio: 'inherit',
      });
    });
    process.exit(0);
  } catch (e) {
    log.error(`[업데이트] 실패: ${e.message}`);
    await fsp.copyFile(backupPath, serverPath).catch(() => {});
  }
}

// ─── Express 앱 ───────────────────────────────────────────────────────────────
const app = express();
app.use(cors());
app.use(express.json());

// WebSocket 업그레이드 요청 무시 (ivLyrics가 /ws 시도)
app.use('/ws', (req, res) => res.status(404).end());

// GET /health
app.get('/health', async (req, res) => {
  let latest = SERVER_VERSION, addonVer = '', hasUpdate = false;
  try {
    const info = await fetchJson(GITHUB_VERSION_URL + '?ts=' + Date.now());
    latest     = info.server || SERVER_VERSION;
    addonVer   = info.addon  || '';
    hasUpdate  = latest !== SERVER_VERSION;
  } catch {}
  res.json({
    status: 'ok', version: SERVER_VERSION,
    latestVersion: latest, addonVersion: addonVer,
    hasUpdate, autoUpdate: AUTO_UPDATE,
  });
});

// POST /update
app.post('/update', async (req, res) => {
  if (!verifySecret(req, res)) return;
  try {
    const info   = await fetchJson(GITHUB_VERSION_URL + '?ts=' + Date.now());
    const latest = info.server || '';
    if (!latest || latest === SERVER_VERSION) {
      return res.json({ status: 'up-to-date', version: SERVER_VERSION });
    }
    res.json({ status: 'updating', from: SERVER_VERSION, to: latest });
    setTimeout(() => doSelfUpdate(latest), 100);
  } catch (e) {
    res.status(500).json({ detail: e.message });
  }
});

// GET /captions
app.get('/captions', async (req, res) => {
  if (!verifySecret(req, res)) return;

  const { title, artist, format = 'lrc', videoId } = req.query;
  if (!title || !artist) return res.status(400).json({ detail: 'title and artist are required' });

  const cacheKey = makeKey('captions', title, artist, videoId || '', format);
  const cached   = cacheGet(cacheKey);
  if (cached) return res.json({ ...cached, cached: true });

  log.info(`[요청] title='${title}', artist='${artist}'`);

  const preferredLang = await detectLang(title, artist);
  log.info(`[요청] 감지된 언어: ${preferredLang}`);

  let vid = null, result = null;

  // videoId 직접 지정
  if (videoId) {
    result = await fetchCaptions(videoId, preferredLang);
    if (result?.captions?.length) vid = videoId;
  }

  // YouTube Music 검색
  if (!vid) {
    log.info('[검색] YouTube Music 우선');
    const ytmCandidates = await searchYtMusic(title, artist);
    const fetched = {};

    for (const c of ytmCandidates) {
      const r = await fetchCaptions(c, preferredLang);
      fetched[c] = r;
      if (r?.captions?.length && r.source === 'manual') { vid = c; result = r; break; }
    }
    if (!vid) {
      for (const c of ytmCandidates) {
        const r = fetched[c];
        if (r?.captions?.length) { vid = c; result = r; break; }
      }
    }
  }

  // YouTube MV fallback
  if (!vid) {
    log.info('[검색] YouTube MV fallback');
    const mvCandidates = await searchVideos(title, artist);
    if (!mvCandidates.length) {
      return res.status(404).json({ detail: `'${artist} - ${title}' 영상을 찾을 수 없습니다.` });
    }

    const fetchedMv = {};
    for (const c of mvCandidates) {
      const r = await fetchCaptions(c, preferredLang);
      fetchedMv[c] = r;
      if (r?.captions?.length && r.source === 'manual') { vid = c; result = r; break; }
    }
    if (!vid) {
      for (const c of mvCandidates) {
        const r = fetchedMv[c];
        if (r?.captions?.length) { vid = c; result = r; break; }
      }
    }
  }

  if (!vid || !result?.captions?.length) {
    return res.status(404).json({ detail: `'${artist} - ${title}' 자막을 찾을 수 없습니다.` });
  }

  log.info(`[완료] ${vid}, source=${result.source}, lang=${result.lang}, lines=${result.captions.length}`);

  const response = {
    videoId: vid,
    youtubeUrl: `https://www.youtube.com/watch?v=${vid}`,
    title, artist,
    source: result.source,
    lang:   result.lang,
    captionCount: result.captions.length,
    cached: false,
  };

  if (format === 'json') response.captions = result.captions;
  else                   response.lrc      = toLrc(result.captions);

  cacheSet(cacheKey, response);
  res.json(response);
});

// GET /captions/by-id
app.get('/captions/by-id', async (req, res) => {
  if (!verifySecret(req, res)) return;

  const { videoId, format = 'lrc' } = req.query;
  if (!videoId) return res.status(400).json({ detail: 'videoId is required' });

  const cacheKey = makeKey('by_id', videoId, format);
  const cached   = cacheGet(cacheKey);
  if (cached) return res.json({ ...cached, cached: true });

  const result = await fetchCaptions(videoId, null);
  if (!result?.captions?.length) {
    return res.status(404).json({ detail: `'${videoId}' 자막을 찾을 수 없습니다.` });
  }

  const response = {
    videoId,
    youtubeUrl: `https://www.youtube.com/watch?v=${videoId}`,
    source: result.source, lang: result.lang,
    captionCount: result.captions.length, cached: false,
  };

  if (format === 'json') response.captions = result.captions;
  else                   response.lrc      = toLrc(result.captions);

  cacheSet(cacheKey, response);
  res.json(response);
});

// DELETE /cache
app.delete('/cache', (req, res) => {
  if (!verifySecret(req, res)) return;
  const count = cache.size;
  cache.clear();
  res.json({ deleted: count });
});

// WebSocket 핸들러 (upgrade 이벤트)
const server = http.createServer(app);
server.on('upgrade', (req, socket) => { socket.destroy(); });

// ─── 시작 ─────────────────────────────────────────────────────────────────────
async function start() {
  // yt-dlp 확인 및 자동 다운로드
  try {
    await execFileAsync(YTDLP_PATH, ['--version'], { timeout: 5000 });
    log.info(`[시작] yt-dlp 확인됨: ${YTDLP_PATH}`);
  } catch {
    log.warn('[시작] yt-dlp 없음, 자동 다운로드 시작...');
    try {
      await downloadYtdlp();
    } catch (e) {
      log.error(`[시작] yt-dlp 다운로드 실패: ${e.message}`);
      log.error('[시작] yt-dlp를 수동으로 설치하세요: https://github.com/yt-dlp/yt-dlp');
      process.exit(1);
    }
  }

  server.listen(PORT, '0.0.0.0', () => {
    log.info(`[시작] ivLyrics YouTube Caption Server v${SERVER_VERSION}`);
    log.info(`[시작] http://0.0.0.0:${PORT}`);
  });

  // 3초 후 업데이트 확인
  setTimeout(checkAndUpdate, 3000);
}

start();
